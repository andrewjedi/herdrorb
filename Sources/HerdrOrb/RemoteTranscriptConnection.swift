import Foundation
import Darwin

/// One retained SSH/helper process per active remote profile, rather than starting
/// SSH or Python on each output poll. Exchanges are bounded and cancellable.
actor RemoteTranscriptConnections {
    static let shared = RemoteTranscriptConnections()
    private var connections: [String: RemoteTranscriptConnection] = [:]
    private var recency: [String] = []
    func request(_ arguments: [String], machine: Machine, source: String) async throws -> Data {
        let key = machine.identity
        let connection: RemoteTranscriptConnection
        if let existing = connections[key] { connection = existing }
        else {
            connection = RemoteTranscriptConnection(machine: machine, source: source)
            connections[key] = connection
        }
        recency.removeAll { $0 == key }; recency.append(key)
        while recency.count > 3 {
            let expired = recency.removeFirst(); connections.removeValue(forKey: expired)?.stop()
        }
        do {
            return try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) { try connection.request(arguments) }.value
            } onCancel: { connection.stop() }
        } catch {
            if connections[key] === connection { connections.removeValue(forKey: key); recency.removeAll { $0 == key } }
            connection.stop(); throw error
        }
    }
    func stop() { connections.values.forEach { $0.stop() }; connections.removeAll(); recency = [] }
}

final class RemoteTranscriptConnection: @unchecked Sendable {
    private let machine: Machine
    private let source: String
    private let exchangeLock = NSLock()
    private let stateLock = NSLock()
    private var process: Process?
    private var stopped = false
    private var input: Pipe?
    private var output: Pipe?
    init(machine: Machine, source: String) { self.machine = machine; self.source = source }
    deinit { stop() }
    func stop() {
        stateLock.lock(); stopped = true; let process = process; stateLock.unlock()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
        }
    }
    private func check() throws {
        stateLock.lock(); let stopped = stopped; stateLock.unlock()
        if stopped { throw CancellationError() }
    }
    func request(_ arguments: [String]) throws -> Data {
        exchangeLock.lock(); defer { exchangeLock.unlock() }
        try check()
        if process == nil {
            let p = Process(), stdin = Pipe(), stdout = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let command = ConnectionCommands.shell(#"PATH="\#(ConnectionCommands.searchPath)"; export PATH; exec python3 -u -c "$1" serve"#, arguments: [source])
            p.arguments = ConnectionCommands.sshOptions + [try ConnectionCommands.target(machine), command]
            p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
            stateLock.lock()
            if stopped { stateLock.unlock(); throw CancellationError() }
            do { try p.run(); process = p; input = stdin; output = stdout; stateLock.unlock() }
            catch { stateLock.unlock(); throw error }
            let fd = stdout.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        guard let input, let output else { throw BridgeError.message("Remote transcript connection unavailable.") }
        var request = try JSONEncoder().encode(arguments); request.append(10)
        try input.fileHandleForWriting.write(contentsOf: request)
        let fd = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(15)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            try check()
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 100)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { throw BridgeError.message("Remote transcript connection closed.") }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                throw BridgeError.message("Remote transcript read failed.")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 16_000_000 else { throw BridgeError.message("Remote transcript response exceeds the read limit.") }
            if data.last == 10 {
                guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.message("Invalid remote transcript response.") }
                if let error = envelope["error"] as? String { throw BridgeError.message(error) }
                guard let result = envelope["result"] else { throw BridgeError.message("Missing remote transcript response.") }
                return try JSONSerialization.data(withJSONObject: result)
            }
        }
        throw BridgeError.message("Remote transcript read timed out.")
    }
}
