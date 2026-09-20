import Foundation
import Darwin
import os

struct RPCError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// A cancellable, bounded subprocess used for discovery, never for the live refresh path.
enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 12) async throws -> Data {
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                try control.run(executable, arguments, timeout: timeout)
            }.value
        }, onCancel: { control.cancel() })
    }
}
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) } }
        }
    }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.environment = ConnectionCommands.environment()
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try p.run(); process = p; lock.unlock() } catch { lock.unlock(); throw error }
        let diagnostics = DataBox()
        let group = DispatchGroup(); group.enter()
        let deadline = Date().addingTimeInterval(timeout + 2)
        DispatchQueue.global().async {
            diagnostics.value = Self.read(err.fileHandleForReading, limit: 64_000, deadline: deadline)
            group.leave()
        }
        let timeoutWork = DispatchWorkItem { if p.isRunning { p.terminate() } }
        let killWork = DispatchWorkItem { if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 1, execute: killWork)
        let data = Self.read(out.fileHandleForReading, limit: 16_000_000, deadline: deadline)
        p.waitUntilExit(); group.wait(); timeoutWork.cancel(); killWork.cancel()
        lock.lock(); let wasCancelled = cancelled; process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard !data.exceeded else { throw RPCError(code: "size", message: "Herdr command output exceeded the size limit") }
        guard p.terminationStatus == 0 else {
            let message = String(decoding: diagnostics.value.data, as: UTF8.self)
            let code = message.contains("HB_MISSING:") ? "missing" :
                (message.contains("Host key verification failed") || message.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")) ? "host_key" :
                message.contains("Permission denied") ? "authentication" : "process"
            throw RPCError(code: code, message: message.isEmpty ? "Herdr command failed or timed out" : String(message.prefix(1200)))
        }
        return data.data
    }
    // Nonblocking reads have a deadline even if a descendant inherits a pipe.
    // Keep draining oversized diagnostics so the child cannot deadlock on stderr.
    private static func read(_ handle: FileHandle, limit: Int, deadline: Date) -> Capture {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var capture = Capture(), buffer = [UInt8](repeating: 0, count: 16_384)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { usleep(10_000); continue }
                break
            }
            let remaining = limit - capture.data.count
            capture.data.append(contentsOf: buffer.prefix(min(count, remaining)))
            if count > remaining { capture.exceeded = true }
        }
        try? handle.close()
        return capture
    }
}
private struct Capture { var data = Data(); var exceeded = false }
private final class DataBox: @unchecked Sendable { var value = Capture() }

/// One request per socket, as required by Herdr. Cancellation shuts down blocking I/O.
final class RPCSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }
    func exchange(path: String, request: Data, timeout: TimeInterval, onLine: ((Data) -> Void)? = nil) throws -> Data {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw failure("Create socket") }
        lock.lock()
        if cancelled { lock.unlock(); Darwin.close(socket); throw CancellationError() }
        fd = socket; lock.unlock()
        defer { lock.lock(); fd = -1; Darwin.close(socket); lock.unlock() }
        var noSignal: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw RPCError(code: "path", message: "Socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw failure("Connect to Herdr") }
        let body = request + Data([10])
        try body.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = Darwin.write(socket, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                guard n > 0 else { throw failure("Send request") }; sent += n
            }
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(timeout)
        while onLine != nil || Date() < deadline {
            let n = Darwin.read(socket, &buffer, buffer.count)
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && onLine != nil {
                lock.lock(); let stopped = cancelled; lock.unlock()
                if stopped { throw CancellationError() }; continue
            }
            guard n > 0 else { throw failure("Read from Herdr") }
            result.append(contentsOf: buffer.prefix(n))
            while let end = result.firstIndex(of: 10) {
                let line = Data(result.prefix(upTo: end))
                if let onLine { onLine(line); result.removeSubrange(...end) }
                else { return line }
            }
            guard result.count < 16_000_000 else { throw RPCError(code: "size", message: "Herdr response exceeded the size limit") }
        }
        throw RPCError(code: "timeout", message: "Herdr request timed out")
    }
    private func failure(_ context: String) -> Error {
        lock.lock(); let stopped = cancelled; lock.unlock()
        return stopped ? CancellationError() : RPCError(code: "transport", message: "\(context): \(String(cString: strerror(errno)))")
    }
}

actor MachineTransport {
    let machine: Machine
    private var socketPath: String?
    private var serverVersion: String?
    private var tunnelDirectory: String?
    private var tunnel: Process?
    private var preparing: Task<String, Error>?
    private var generation = 0
    private var trackedPanes: [String] = []
    init(_ machine: Machine) { self.machine = machine }
    deinit { if let tunnel, tunnel.isRunning { tunnel.terminate() } }

    func shutdown() {
        generation += 1; preparing?.cancel(); preparing = nil
        if let tunnel, tunnel.isRunning { tunnel.terminate() }
        tunnel = nil
        if let socketPath, machine.id != "local" { try? FileManager.default.removeItem(atPath: socketPath) }
        socketPath = nil
        if let tunnelDirectory { try? FileManager.default.removeItem(atPath: tunnelDirectory) }
        tunnelDirectory = nil
    }
    private func path() async throws -> String {
        if let socketPath, machine.id == "local" || tunnel?.isRunning == true { return socketPath }
        if let preparing { return try await preparing.value }
        let task = Task { try await self.prepare() }; preparing = task
        defer { preparing = nil }
        return try await task.value
    }
    private func prepare() async throws -> String {
        let stamp = generation
        let data: Data
        if machine.id == "local" {
            data = try await ProcessRunner.run(HerdrInstallation.resolve(), ["status", "--json"])
        } else {
            let target = try ConnectionCommands.target(machine)
            data = try await ProcessRunner.run("/usr/bin/ssh", Self.sshOptions + [target, Self.remoteCommand(machine, arguments: ["status", "--json"])])
        }
        try Task.checkCancellation()
        let status = try HerdrInstallation.Status.decode(data)
        serverVersion = status.server.version ?? status.client?.version
        let remote = try status.socketPath(machine: machine.label)
        guard stamp == generation else { throw CancellationError() }
        if machine.id == "local" { socketPath = remote; return remote }
        let directory = "/tmp/herdrorb-" + UUID().uuidString.prefix(12)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        tunnelDirectory = directory
        let local = directory + "/" + UUID().uuidString.prefix(12) + ".sock"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = Self.sshOptions + ["-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes", "-N", "-L", "\(local):\(remote)", try ConnectionCommands.target(machine)]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); tunnel = p
        do {
            for _ in 0..<100 {
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: local) { socketPath = local; return local }
                if !p.isRunning { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        } catch {
            if p.isRunning { p.terminate() }
            try? FileManager.default.removeItem(atPath: directory)
            throw error
        }
        if p.isRunning { p.terminate() }
        try? FileManager.default.removeItem(atPath: directory)
        throw RPCError(code: "tunnel", message: "Could not establish a live connection to \(machine.label). Check SSH access.")
    }
    static let sshOptions = ConnectionCommands.sshOptions
    static func quote(_ value: String) -> String { ConnectionCommands.quote(value) }
    static func remoteCommand(_ machine: Machine, arguments: [String]) -> String { ConnectionCommands.herdr(machine, arguments: arguments) }
    func events() async throws -> AsyncThrowingStream<Data, Error> {
        let path = try await path()
        let socket = RPCSocket()
        let types = ["tab.created", "tab.closed", "tab.renamed", "pane.created", "pane.closed", "pane.updated", "pane.exited", "pane.agent_detected", "workspace.created", "workspace.closed"]
        let subscriptions = types.map { ["type": $0] } + trackedPanes.map { ["type": "pane.agent_status_changed", "pane_id": $0] }
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": "events.subscribe", "params": ["subscriptions": subscriptions]])
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    _ = try socket.exchange(path: path, request: data, timeout: 2) { continuation.yield($0) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in socket.cancel(); task.cancel() }
        }
    }
    func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 10) async throws -> [String: Any] {
        let path = try await path()
        let socket = RPCSocket()
        let request = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params])
        let started = Date()
        do {
            let data = try await withTaskCancellationHandler(operation: {
                try await Task.detached(priority: .userInitiated) { try socket.exchange(path: path, request: request, timeout: timeout) }.value
            }, onCancel: { socket.cancel() })
            var result = try HerdrClient.result(data)
            if let serverVersion { result["_herdrorb_version"] = serverVersion }
            if method == "session.snapshot", let snapshot = result["snapshot"] as? [String: Any] {
                trackedPanes = (snapshot["panes"] as? [[String: Any]] ?? []).compactMap { $0["pane_id"] as? String }
            }
            Metrics.record(method, milliseconds: Date().timeIntervalSince(started) * 1000)
            return result
        } catch {
            if let error = error as? RPCError, ["transport", "tunnel"].contains(error.code) { shutdown() }
            throw error
        }
    }
}

enum Metrics {
    static let logger = Logger(subsystem: AppPreferences.bundleID, category: "latency")
    static func record(_ operation: String, milliseconds: Double) {
        logger.debug("\(operation, privacy: .public): \(milliseconds, privacy: .public) ms")
    }
}
