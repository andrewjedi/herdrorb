import AVFoundation
import Combine
import Foundation
import Speech

/// Dictates into a draft. Nothing is recorded until `start()` is called by the microphone button.
@MainActor
final class VoiceDictation: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isFinishing = false
    @Published private(set) var transcript = ""
    @Published private(set) var error: String?

    private var generation = UUID()
    private var capture: DictationCapture?
    private var finishTimeout: Task<Void, Never>?

    deinit {
        finishTimeout?.cancel()
        capture?.cancel()
    }

    func start() async {
        guard !Task.isCancelled, !isPreparing, !isRecording else { return }
        cancel()
        transcript = ""
        error = nil
        isPreparing = true
        let attempt = generation

        // A bare Swift executable has no privacy descriptions; requesting access would terminate it.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            fail("Open the installed herdrorb app to use voice dictation.", attempt: attempt)
            return
        }

        await withTaskCancellationHandler {
            let speechPermission = await Self.speechPermission()
            guard isCurrent(attempt) else { return }
            guard speechPermission == .authorized else {
                let message = speechPermission == .restricted
                    ? "Speech recognition is restricted on this Mac. You can still type your message."
                    : "Allow herdrorb in System Settings → Privacy & Security → Speech Recognition, then try again."
                fail(message, attempt: attempt)
                return
            }

            let microphonePermission = await Self.microphonePermission()
            guard isCurrent(attempt) else { return }
            guard microphonePermission else {
                fail("Allow herdrorb in System Settings → Privacy & Security → Microphone, then try again.", attempt: attempt)
                return
            }
            beginCapture(attempt: attempt)
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.generation == attempt else { return }
                self?.cancel()
            }
        }
    }

    /// Releases the microphone immediately, then waits briefly for the final words.
    func stop() {
        if isPreparing {
            cancel()
            return
        }
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        capture?.endAudio()
        let attempt = generation
        finishTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self, self.generation == attempt else { return }
            self.complete(attempt: attempt)
        }
    }

    /// Use when leaving a conversation or sending a draft. Late callbacks cannot change the new draft.
    func cancel() {
        generation = UUID()
        finishTimeout?.cancel()
        finishTimeout = nil
        capture?.cancel()
        capture = nil
        isRecording = false
        isPreparing = false
        isFinishing = false
        error = nil
    }

    private func isCurrent(_ attempt: UUID) -> Bool {
        guard generation == attempt else { return false }
        if Task.isCancelled {
            cancel()
            return false
        }
        return true
    }

    private func beginCapture(attempt: UUID) {
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            fail("Dictation is unavailable for your language right now. Check your connection and try again.", attempt: attempt)
            return
        }

        let current = DictationCapture(recognizer: recognizer)
        capture = current
        let request = current.request
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // Keep recognition on this Mac whenever Apple's language model supports it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let input = current.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No microphone is available. Connect one or choose an input in System Settings → Sound.", attempt: attempt)
            return
        }

        current.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, recognitionError in
            // Speech can call back on a background queue. Copy values before crossing to the UI.
            let words = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let didFail = recognitionError != nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                if let words { self.transcript = words }
                if isFinal {
                    self.complete(attempt: attempt)
                } else if didFail {
                    if self.isFinishing, !self.transcript.isEmpty {
                        self.complete(attempt: attempt)
                    } else {
                        let message = self.transcript.isEmpty
                            ? "Dictation couldn't hear your words. Check your microphone and connection, then try again."
                            : "Dictation stopped. Your words are still in the message; tap the microphone to continue."
                        self.fail(message, attempt: attempt)
                    }
                }
            }
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        current.hasInputTap = true
        do {
            current.engine.prepare()
            try current.engine.start()
            isPreparing = false
            isRecording = true
            current.configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: current.engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt, self.isRecording else { return }
                    self.fail("Your microphone changed. Tap the microphone to continue dictating.", attempt: attempt)
                }
            }
        } catch {
            fail("Couldn't start your microphone. Check the input in System Settings → Sound and try again.", attempt: attempt)
        }
    }

    private func complete(attempt: UUID) {
        guard generation == attempt else { return }
        let heardNothing = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cancel()
        if heardNothing { error = "No speech was heard. Tap the microphone to try again." }
    }

    private func fail(_ message: String, attempt: UUID) {
        guard generation == attempt else { return }
        cancel()
        error = message
    }

    private static func speechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private static func microphonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// Owns the non-UI audio resources so teardown also runs if the composer is released.
private final class DictationCapture {
    let recognizer: SFSpeechRecognizer
    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    var recognitionTask: SFSpeechRecognitionTask?
    var hasInputTap = false
    var configurationObserver: NSObjectProtocol?
    private var didEndAudio = false

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    func endAudio() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop()
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        if !didEndAudio {
            request.endAudio()
            didEndAudio = true
        }
    }

    func cancel() {
        endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    deinit { cancel() }
}
