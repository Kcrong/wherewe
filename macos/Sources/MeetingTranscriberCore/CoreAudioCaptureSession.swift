import AVFoundation
import CoreAudio
import Foundation

public enum CoreAudioCaptureSessionState: Equatable, Sendable {
    case stopped
    case running(channelCount: Int)
}

public enum CapturedAudioEvent: Equatable, Sendable {
    case frame([Int16])
    case drained(UUID)
}

public actor CoreAudioCaptureSession {
    public enum SessionError: Error, Equatable, LocalizedError, Sendable {
        case noInputSelected
        case alreadyRunning

        public var errorDescription: String? {
            switch self {
            case .noInputSelected:
                return "Select a microphone or system-audio input before recording."
            case .alreadyRunning:
                return "Audio capture is already running."
            }
        }
    }

    public private(set) var state: CoreAudioCaptureSessionState = .stopped
    public nonisolated let frames: AsyncStream<CapturedAudioEvent>

    private let frameContinuation: AsyncStream<CapturedAudioEvent>.Continuation
    private var synchronizer: DualInputSynchronizer?
    private var microphoneStream: CoreAudioInputStream?
    private var systemStream: CoreAudioInputStream?
    private var isStarting = false

    public init() {
        let pair = AsyncStream.makeStream(
            of: CapturedAudioEvent.self,
            bufferingPolicy: .unbounded
        )
        self.frames = pair.stream
        self.frameContinuation = pair.continuation
    }

    @discardableResult
    public func start(
        microphone: AudioInputDevice?,
        systemInput: AudioInputDevice?,
        microphoneMuted: Bool = false
    ) async throws -> Int {
        guard state == .stopped, !isStarting else { throw SessionError.alreadyRunning }
        isStarting = true
        defer { isStarting = false }
        guard microphone != nil || systemInput != nil else { throw SessionError.noInputSelected }

        let sameDevice = microphone?.uid == systemInput?.uid && microphone != nil
        var selectedSources = Set<AudioInputSource>()
        if microphone != nil { selectedSources.insert(.microphone) }
        if systemInput != nil && !sameDevice { selectedSources.insert(.system) }

        let origin = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        let synchronizer = try DualInputSynchronizer(
            sources: selectedSources,
            originHostTimeNanoseconds: origin
        )
        synchronizer.setMicrophoneMuted(microphoneMuted)
        self.synchronizer = synchronizer

        let onChunk: @Sendable (TimedAudioChunk) -> Void = { [frameContinuation] chunk in
            do {
                for frame in try synchronizer.append(chunk) {
                    frameContinuation.yield(.frame(frame))
                }
            } catch {}
        }
        let voiceProcessingAllowed = Self.voiceProcessingAllowed(
            systemInput: sameDevice ? nil : systemInput,
            microphone: microphone,
            defaultOutputID: CoreAudioDeviceCatalog().defaultOutputDeviceID()
        )
        let systemStream = sameDevice ? nil : systemInput.map { device in
            CoreAudioInputStream(
                device: device,
                source: .system,
                processingMode: .unprocessedSystemInput,
                onChunk: onChunk
            )
        }

        // Streams whose start exceeded the deadline still hold their own
        // lock; they stop themselves when CoreAudio returns, so they must not
        // be stopped (and waited on) from this actor.
        var started: [CoreAudioInputStream] = []
        func abortStart(_ error: Error) -> Error {
            for stream in started { stream.stop() }
            self.microphoneStream = nil
            self.systemStream = nil
            self.synchronizer = nil
            return error
        }

        if Self.requiresRecordingPermission(microphone: microphone),
           await Self.recordingAuthorised() == false {
            throw abortStart(CoreAudioCaptureError.microphonePermissionDenied)
        }

        // The loopback input starts first so the HAL has finished binding it
        // before a voice-processing unit builds its aggregate device.
        do {
            if let systemStream {
                try await systemStream.start(timeout: Self.startTimeout)
                started.append(systemStream)
            }
            if let microphone {
                let stream = try await Self.startMicrophone(
                    microphone,
                    voiceProcessingAllowed: voiceProcessingAllowed,
                    onChunk: onChunk
                )
                started.append(stream)
                self.microphoneStream = stream
            }
        } catch {
            throw abortStart(error)
        }
        self.systemStream = systemStream

        state = .running(channelCount: synchronizer.channelCount)
        return synchronizer.channelCount
    }

    static let startTimeout: TimeInterval = 10

    /// A selected physical microphone needs the macOS recording consent flow.
    /// A system-only virtual input such as BlackHole is an explicit CoreAudio
    /// route and can be captured without asking for an unused microphone.
    static func requiresRecordingPermission(microphone: AudioInputDevice?) -> Bool {
        microphone != nil
    }

    /// Voice processing cancels the playback signal from the microphone and
    /// ducks other audio. When the default output is itself a captured
    /// device (a loopback such as BlackHole), nothing reaches the speakers to
    /// cancel, ducking would lower the captured meeting audio, and the
    /// aggregate device VoiceProcessingIO builds around that output has been
    /// seen to wedge the HAL. Plain AUHAL capture is used instead.
    static func voiceProcessingAllowed(
        systemInput: AudioInputDevice?,
        microphone: AudioInputDevice?,
        defaultOutputID: AudioDeviceID?
    ) -> Bool {
        guard let defaultOutputID else { return true }
        return systemInput?.id != defaultOutputID && microphone?.id != defaultOutputID
    }

    /// Starts the microphone, falling back from VoiceProcessingIO to AUHAL
    /// capture when voice processing fails or does not start in time.
    private static func startMicrophone(
        _ device: AudioInputDevice,
        voiceProcessingAllowed: Bool,
        onChunk: @escaping @Sendable (TimedAudioChunk) -> Void
    ) async throws -> CoreAudioInputStream {
        let preferred = CoreAudioInputStream(
            device: device,
            source: .microphone,
            processingMode: .voiceProcessedMicrophone,
            voiceProcessingAllowed: voiceProcessingAllowed,
            onChunk: onChunk
        )
        do {
            try await preferred.start(timeout: startTimeout)
            return preferred
        } catch {
            guard preferred.usesVoiceProcessingIO else { throw error }
        }
        let fallback = CoreAudioInputStream(
            device: device,
            source: .microphone,
            processingMode: .voiceProcessedMicrophone,
            voiceProcessingAllowed: false,
            onChunk: onChunk
        )
        try await fallback.start(timeout: startTimeout)
        return fallback
    }

    /// Asks for recording permission up front, so a first-run privacy prompt
    /// never counts against the start deadline and a denial is reported
    /// instead of recording silence.
    private static func recordingAuthorised() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public func setMicrophoneMuted(_ muted: Bool) async {
        synchronizer?.setMicrophoneMuted(muted)
    }

    @discardableResult
    public func stop() async -> UUID? {
        guard state != .stopped else { return nil }
        microphoneStream?.stop()
        systemStream?.stop()
        microphoneStream = nil
        systemStream = nil

        // CoreAudioInputStream.stop() drains each serial delivery queue. Each
        // callback mutates the locked synchroniser before that queue returns,
        // so no captured frame can arrive after this flush.
        if let residual = synchronizer?.flush() {
            frameContinuation.yield(.frame(residual))
        }
        synchronizer = nil
        state = .stopped
        let token = UUID()
        frameContinuation.yield(.drained(token))
        return token
    }

    public func close() async {
        _ = await stop()
        frameContinuation.finish()
    }
}
