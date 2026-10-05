import Foundation

public struct RecordingClaim: Equatable, Sendable {
    public let meetingID: Int
    public let generation: Int64
    public let socketID: String
    public let sampleRate: Double
    public let channelCount: Int

    public init(
        meetingID: Int,
        generation: Int64,
        socketID: String,
        sampleRate: Double,
        channelCount: Int
    ) {
        self.meetingID = meetingID
        self.generation = generation
        self.socketID = socketID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public struct RecordingStopOutcome: Equatable, Sendable {
    public let audioDeliveryConfirmed: Bool
    public let usedServiceFallback: Bool

    public init(audioDeliveryConfirmed: Bool, usedServiceFallback: Bool) {
        self.audioDeliveryConfirmed = audioDeliveryConfirmed
        self.usedServiceFallback = usedServiceFallback
    }
}

public enum RecordingCoordinatorState: Equatable, Sendable {
    case idle
    case preparing(meetingID: Int)
    case awaitingAudio(RecordingClaim)
    case recording(RecordingClaim)
    case stopping(RecordingClaim)
    case recoveryRequired(RecordingClaim)
    case retryingFinalization(RecordingClaim)
}

public enum RecordingCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case invalidState
    case realtimeClientIDUnavailable
    case readyTimedOut
    case transcription(String?)
    case audioDeliveryFailed
    case audioDeliveryIncomplete
    case finalizationUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .invalidState:
            return "The recording action is not valid in the current state."
        case .realtimeClientIDUnavailable:
            return "The realtime connection did not provide an ownership ID."
        case .readyTimedOut:
            return "Apple Speech did not become ready in time."
        case let .transcription(code):
            if let code { return "Apple Speech transcription failed (\(code))." }
            return "Apple Speech transcription failed."
        case .audioDeliveryFailed:
            return "Audio delivery failed. Recording stopped before finalisation."
        case .audioDeliveryIncomplete:
            return "Not all captured audio reached the recording spool. Retry finalisation."
        case .finalizationUnconfirmed:
            return "Recording finalisation could not be confirmed. Retry finalisation before starting again."
        }
    }
}

private struct TranscriptionErrorPayload: Decodable {
    let code: String?
    let generation: Int64?
}

public actor RecordingCoordinator {
    public private(set) var state: RecordingCoordinatorState = .idle
    public nonisolated let events: AsyncStream<RealtimeMessage>

    private let api: any NativeServiceServing
    private let realtime: any RealtimeServing
    private let readyTimeout: Duration
    private let eventContinuation: AsyncStream<RealtimeMessage>.Continuation
    private var eventPump: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<ReadyForAudio, Error>?
    private var readyGeneration: Int64?
    private var framer: PCMFramer?
    private var pendingAudioFrames: [Data] = []
    private var expectedAudioByteCount = 0
    private var deliveredAudioByteCount = 0
    private var tracksAudioDelivery = false
    private var audioDeliveryConfirmed = false

    public init(
        api: any NativeServiceServing,
        realtime: any RealtimeServing,
        readyTimeout: Duration = .seconds(30)
    ) {
        self.api = api
        self.realtime = realtime
        self.readyTimeout = readyTimeout
        let pair = AsyncStream.makeStream(
            of: RealtimeMessage.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )
        self.events = pair.stream
        self.eventContinuation = pair.continuation
    }

    public func connect() async throws {
        try await realtime.connect()
        startEventPumpIfNeeded()
    }

    public func adoptRecoveryClaim(_ claim: RecordingClaim) throws {
        guard state == .idle else { throw RecordingCoordinatorError.invalidState }
        clearAudioDeliveryTracking()
        state = .recoveryRequired(claim)
    }

    public func markConnectionLost() {
        if case let .recording(claim) = state {
            state = .recoveryRequired(claim)
        } else if case let .awaitingAudio(claim) = state {
            state = .recoveryRequired(claim)
        } else if case let .stopping(claim) = state {
            state = .recoveryRequired(claim)
        } else if case let .retryingFinalization(claim) = state {
            state = .recoveryRequired(claim)
        }
    }

    @discardableResult
    public func start(
        meetingID: Int,
        language: String,
        translationTarget: String,
        sampleRate: Double = 48_000,
        channelCount: Int
    ) async throws -> RecordingClaim {
        guard state == .idle else { throw RecordingCoordinatorError.invalidState }
        state = .preparing(meetingID: meetingID)

        do {
            try await connect()
            guard let socketID = realtime.clientID, !socketID.isEmpty else {
                state = .idle
                throw RecordingCoordinatorError.realtimeClientIDUnavailable
            }

            let response = try await api.startRecording(
                meetingID: meetingID,
                request: StartRecordingRequest(
                    socketID: socketID,
                    language: language,
                    translationTarget: translationTarget
                )
            )
            let claim = RecordingClaim(
                meetingID: meetingID,
                generation: response.generation,
                socketID: socketID,
                sampleRate: sampleRate,
                channelCount: channelCount
            )
            framer = try PCMFramer(
                sampleRate: Int(sampleRate.rounded()),
                channelCount: channelCount
            )
            beginAudioDeliveryTracking()
            state = .awaitingAudio(claim)

            let request = StartTranscriptionRequest(
                meetingID: meetingID,
                generation: response.generation,
                language: language,
                translationTarget: translationTarget,
                sampleRate: sampleRate,
                channelCount: channelCount
            )
            let ready = try await awaitReady(for: request)
            guard ready.generation == claim.generation else {
                throw RecordingCoordinatorError.readyTimedOut
            }
            state = .recording(claim)
            return claim
        } catch {
            if case let .awaitingAudio(claim) = state {
                let finalized = await finalizeClaim(claim)
                if finalized {
                    clearAudioDeliveryTracking()
                    state = .idle
                } else {
                    state = .recoveryRequired(claim)
                }
            } else if case .preparing = state {
                state = .idle
            }
            throw error
        }
    }

    public func sendPCM(_ samples: [Int16]) throws {
        guard case .recording = state, var framer else {
            throw RecordingCoordinatorError.invalidState
        }
        let frames = try framer.append(samples)
        self.framer = framer
        expectedAudioByteCount += samples.count * MemoryLayout<Int16>.size
        pendingAudioFrames.append(contentsOf: frames)
        try deliverPendingAudio()
    }

    @discardableResult
    public func stop() async throws -> RecordingStopOutcome {
        guard case let .recording(claim) = state else {
            throw RecordingCoordinatorError.invalidState
        }
        state = .stopping(claim)

        do {
            try await confirmAudioDelivery(for: claim)
        } catch {
            state = .recoveryRequired(claim)
            throw error
        }

        var usedServiceFallback = false
        let socketStop: RealtimeAcknowledgement
        do {
            socketStop = try await realtime.stopTranscription(
                meetingID: claim.meetingID,
                generation: claim.generation
            )
        } catch {
            state = .recoveryRequired(claim)
            throw error
        }
        var finalized = socketStop.success || socketStop.code == "RECORDING_CLAIM_STALE"
        if !finalized,
           socketStop.code == "AUDIO_SESSION_UNAVAILABLE",
           expectedAudioByteCount == 0 {
            usedServiceFallback = true
            finalized = await finalizeClaimViaService(claim)
        }

        guard finalized else {
            state = .recoveryRequired(claim)
            throw RecordingCoordinatorError.finalizationUnconfirmed
        }
        clearAudioDeliveryTracking()
        state = .idle
        return RecordingStopOutcome(
            audioDeliveryConfirmed: true,
            usedServiceFallback: usedServiceFallback
        )
    }

    public func retryFinalization() async throws {
        guard case let .recoveryRequired(claim) = state else {
            throw RecordingCoordinatorError.invalidState
        }
        state = .retryingFinalization(claim)
        if tracksAudioDelivery, !audioDeliveryConfirmed {
            do {
                try await confirmAudioDelivery(for: claim)
            } catch {
                state = .recoveryRequired(claim)
                throw error
            }
        }
        let allowsServiceFallback = !tracksAudioDelivery || expectedAudioByteCount == 0
        guard await finalizeClaim(claim, allowsServiceFallback: allowsServiceFallback) else {
            state = .recoveryRequired(claim)
            throw RecordingCoordinatorError.finalizationUnconfirmed
        }
        clearAudioDeliveryTracking()
        state = .idle
    }

    public func close() async {
        if case .recording = state {
            _ = try? await stop()
        }
        eventPump?.cancel()
        eventPump = nil
        realtime.disconnect()
        eventContinuation.finish()
    }

    private func startEventPumpIfNeeded() {
        guard eventPump == nil else { return }
        let stream = realtime.messages
        eventPump = Task { [weak self] in
            for await message in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(message)
            }
        }
    }

    private func receive(_ message: RealtimeMessage) {
        eventContinuation.yield(message)
        guard let continuation = readyContinuation else { return }

        switch message.name {
        case .readyForAudio:
            guard let ready = try? message.decode(ReadyForAudio.self),
                  ready.generation == readyGeneration else { return }
            clearReadyWait()
            continuation.resume(returning: ready)
        case .transcribeError:
            let payload = try? message.decode(TranscriptionErrorPayload.self)
            guard payload?.generation == nil || payload?.generation == readyGeneration else { return }
            clearReadyWait()
            continuation.resume(throwing: RecordingCoordinatorError.transcription(payload?.code))
        default:
            return
        }
    }

    private func awaitReady(for request: StartTranscriptionRequest) async throws -> ReadyForAudio {
        let generation = request.generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyGeneration = generation
                readyContinuation = continuation
                realtime.startTranscription(request)
                Task { [weak self] in
                    try? await Task.sleep(for: self?.readyTimeout ?? .seconds(30))
                    await self?.timeoutReady(generation: generation)
                }
            }
        } onCancel: {
            Task { await self.cancelReady(generation: generation) }
        }
    }

    private func timeoutReady(generation: Int64) {
        guard readyGeneration == generation, let continuation = readyContinuation else { return }
        clearReadyWait()
        continuation.resume(throwing: RecordingCoordinatorError.readyTimedOut)
    }

    private func cancelReady(generation: Int64) {
        guard readyGeneration == generation, let continuation = readyContinuation else { return }
        clearReadyWait()
        continuation.resume(throwing: CancellationError())
    }

    private func clearReadyWait() {
        readyGeneration = nil
        readyContinuation = nil
    }

    private func beginAudioDeliveryTracking() {
        pendingAudioFrames.removeAll(keepingCapacity: true)
        expectedAudioByteCount = 0
        deliveredAudioByteCount = 0
        tracksAudioDelivery = true
        audioDeliveryConfirmed = false
    }

    private func clearAudioDeliveryTracking() {
        framer = nil
        pendingAudioFrames.removeAll(keepingCapacity: false)
        expectedAudioByteCount = 0
        deliveredAudioByteCount = 0
        tracksAudioDelivery = false
        audioDeliveryConfirmed = false
    }

    private func deliverPendingAudio() throws {
        while let frame = pendingAudioFrames.first {
            do {
                try realtime.sendAudio(frame)
            } catch {
                throw RecordingCoordinatorError.audioDeliveryFailed
            }
            pendingAudioFrames.removeFirst()
            deliveredAudioByteCount += frame.count
        }
    }

    private func confirmAudioDelivery(for claim: RecordingClaim) async throws {
        if var framer, let residual = framer.flush() {
            self.framer = framer
            pendingAudioFrames.append(residual)
        }
        try deliverPendingAudio()
        guard deliveredAudioByteCount == expectedAudioByteCount else {
            throw RecordingCoordinatorError.audioDeliveryIncomplete
        }
        let barrier = try await realtime.audioBarrier(
            meetingID: claim.meetingID,
            generation: claim.generation
        )
        guard barrier.success, barrier.audioByteCount == expectedAudioByteCount else {
            throw RecordingCoordinatorError.audioDeliveryIncomplete
        }
        audioDeliveryConfirmed = true
    }

    private func finalizeClaim(
        _ claim: RecordingClaim,
        allowsServiceFallback: Bool = true
    ) async -> Bool {
        do {
            let acknowledgement = try await realtime.stopTranscription(
                meetingID: claim.meetingID,
                generation: claim.generation
            )
            if acknowledgement.success || acknowledgement.code == "RECORDING_CLAIM_STALE" {
                return true
            }
            guard allowsServiceFallback,
                  acknowledgement.code == "AUDIO_SESSION_UNAVAILABLE" else { return false }
            return await finalizeClaimViaService(claim)
        } catch {
            return false
        }
    }

    private func finalizeClaimViaService(_ claim: RecordingClaim) async -> Bool {
        do {
            let result = try await api.finalizeRecording(FinalizeRecordingRequest(
                meetingID: claim.meetingID,
                generation: claim.generation,
                socketID: claim.socketID
            ))
            return result.success
        } catch {
            return false
        }
    }
}
