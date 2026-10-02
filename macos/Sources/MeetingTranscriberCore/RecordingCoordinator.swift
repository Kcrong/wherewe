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
                state = finalized ? .idle : .recoveryRequired(claim)
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
        for frame in frames {
            try realtime.sendAudio(frame)
        }
    }

    @discardableResult
    public func stop() async throws -> RecordingStopOutcome {
        guard case let .recording(claim) = state else {
            throw RecordingCoordinatorError.invalidState
        }
        state = .stopping(claim)

        if var framer, let residual = framer.flush() {
            self.framer = framer
            try? realtime.sendAudio(residual)
        }
        let barrier = try? await realtime.audioBarrier(
            meetingID: claim.meetingID,
            generation: claim.generation
        )
        let audioDeliveryConfirmed = barrier?.success == true

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
        if !finalized, socketStop.code == "AUDIO_SESSION_UNAVAILABLE" {
            usedServiceFallback = true
            finalized = await finalizeClaimViaService(claim)
        }

        guard finalized else {
            state = .recoveryRequired(claim)
            throw RecordingCoordinatorError.finalizationUnconfirmed
        }
        framer = nil
        state = .idle
        return RecordingStopOutcome(
            audioDeliveryConfirmed: audioDeliveryConfirmed,
            usedServiceFallback: usedServiceFallback
        )
    }

    public func retryFinalization() async throws {
        guard case let .recoveryRequired(claim) = state else {
            throw RecordingCoordinatorError.invalidState
        }
        state = .retryingFinalization(claim)
        guard await finalizeClaim(claim) else {
            state = .recoveryRequired(claim)
            throw RecordingCoordinatorError.finalizationUnconfirmed
        }
        framer = nil
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

    private func finalizeClaim(_ claim: RecordingClaim) async -> Bool {
        do {
            let acknowledgement = try await realtime.stopTranscription(
                meetingID: claim.meetingID,
                generation: claim.generation
            )
            if acknowledgement.success || acknowledgement.code == "RECORDING_CLAIM_STALE" {
                return true
            }
            guard acknowledgement.code == "AUDIO_SESSION_UNAVAILABLE" else { return false }
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
