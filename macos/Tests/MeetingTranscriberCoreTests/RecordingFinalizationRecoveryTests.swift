import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Recording finalization recovery", .serialized)
struct RecordingFinalizationRecoveryTests {
    @Test("finalization retry fail fail succeed preserves one recovery claim and one commit")
    func repeatedFailureThenSuccess() async throws {
        let fixture = try FinalizationRecoveryFixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Finalization recovery"))

        let owner = NativeRealtimeClient(service: service)
        try await owner.connect()
        let ownerID = try #require(owner.clientID)
        let started = try await service.startRecording(
            meetingID: meeting.id,
            request: StartRecordingRequest(
                socketID: ownerID,
                language: "en-US",
                translationTarget: "ko"
            )
        )
        owner.disconnect()
        for _ in 0..<100 {
            let ownerStatus = try await service.recordingStatus(socketID: nil)
            if !ownerStatus.recordingOwnerConnected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await !service.recordingStatus(socketID: nil).recordingOwnerConnected)

        let sequence = FinalizationAttemptSequence(remainingFailures: 4)
        await service.setRecordingLifecycleObserver(NativeRecordingLifecycleObserver(
            beforeFinalizeRecording: { request in try await sequence.attempt(request) }
        ))
        let recoveryRealtime = NativeRealtimeClient(service: service)
        try await recoveryRealtime.connect()
        let recoveryID = try #require(recoveryRealtime.clientID)
        let claim = RecordingClaim(
            meetingID: meeting.id,
            generation: started.generation,
            socketID: recoveryID,
            sampleRate: 48_000,
            channelCount: 1
        )
        let coordinator = RecordingCoordinator(api: service, realtime: recoveryRealtime)
        try await coordinator.adoptRecoveryClaim(claim)

        for expectedAttempts in 1...4 {
            await #expect(throws: RecordingCoordinatorError.finalizationUnconfirmed) {
                try await coordinator.retryFinalization()
            }
            #expect(await coordinator.state == .recoveryRequired(claim))
            #expect(await sequence.attemptCount() == expectedAttempts)
            #expect(await sequence.successfulAttemptCount() == 0)
        }

        try await coordinator.retryFinalization()
        #expect(await coordinator.state == .idle)
        #expect(await sequence.attemptCount() == 5)
        #expect(await sequence.successfulAttemptCount() == 1)
        #expect(await sequence.requests().allSatisfy {
            $0.meetingID == claim.meetingID
                && $0.generation == claim.generation
                && $0.socketID == claim.socketID
        })
        #expect(try await !service.recordingStatus(socketID: recoveryID).selectionLocked)
        #expect(try await service.meeting(id: meeting.id).endedAt != nil)

        await #expect(throws: RecordingCoordinatorError.invalidState) {
            try await coordinator.retryFinalization()
        }
        #expect(await sequence.attemptCount() == 5)
        #expect(await sequence.successfulAttemptCount() == 1)

        await coordinator.close()
        await service.shutdown()

        try await verifyOwnedAudioRetry()
        try await verifyPartialPersistenceRetry()
        try await verifyConnectedOwnerIsNotFinalized()
    }

    private func verifyOwnedAudioRetry() async throws {
        let fixture = try FinalizationRecoveryFixture()
        defer { fixture.remove() }
        let retryGate = FinalSpeechRetryGate()
        let speechState = FailOnceFinalSpeechState(
            failingAttempts: [1],
            pausedAttempts: [2],
            gate: retryGate
        )
        let service = NativeService(
            configuration: fixture.configuration,
            eventHub: NativeRealtimeHub(),
            speechService: FailOnceFinalSpeechService(state: speechState),
            translationService: DeterministicTranslationService()
        )
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(
            title: "Recover final PCM",
            language: "en-US",
            translationTarget: "ko"
        ))
        let realtime = NativeRealtimeClient(service: service)
        let coordinator = RecordingCoordinator(api: service, realtime: realtime)
        let claim = try await coordinator.start(
            meetingID: meeting.id,
            language: "en-US",
            translationTarget: "ko",
            sampleRate: 16_000,
            channelCount: 1
        )
        try await coordinator.sendPCM([Int16](repeating: 1, count: 1_600))

        await #expect(throws: FinalizationTestFailure.self) {
            _ = try await coordinator.stop()
        }
        #expect(await coordinator.state == .recoveryRequired(claim))
        #expect(await speechState.attemptCount() == 1)
        #expect(try await service.recordingStatus(socketID: realtime.clientID).selectionLocked)
        let failedMeeting = try await service.meeting(id: meeting.id)
        #expect(failedMeeting.endedAt == nil)
        #expect(failedMeeting.transcripts.isEmpty)

        let firstRetry = Task { try await coordinator.retryFinalization() }
        do {
            try await retryGate.waitUntilPaused()
        } catch {
            firstRetry.cancel()
            await retryGate.release()
            throw error
        }
        await #expect(throws: RecordingCoordinatorError.invalidState) {
            try await coordinator.retryFinalization()
        }
        await retryGate.release()
        try await firstRetry.value
        #expect(await coordinator.state == .idle)
        #expect(await speechState.attemptCount() == 2)
        let payloads = await speechState.payloads()
        #expect(payloads.count == 2)
        #expect(payloads[0] == payloads[1])
        #expect(try await !service.recordingStatus(socketID: realtime.clientID).selectionLocked)
        let recoveredMeeting = try await service.meeting(id: meeting.id)
        #expect(recoveredMeeting.endedAt != nil)
        #expect(recoveredMeeting.transcripts.map(\.text) == ["Recovered final transcript."])

        await coordinator.close()
        await service.shutdown()
    }

    private func verifyPartialPersistenceRetry() async throws {
        let fixture = try FinalizationRecoveryFixture()
        defer { fixture.remove() }
        let speechState = FailOnceFinalSpeechState(failingAttempts: [2])
        let service = NativeService(
            configuration: fixture.configuration,
            eventHub: NativeRealtimeHub(),
            speechService: FailOnceFinalSpeechService(state: speechState),
            translationService: DeterministicTranslationService()
        )
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(
            title: "Recover partially persisted PCM",
            language: "en-US",
            translationTarget: "ko"
        ))
        let realtime = NativeRealtimeClient(service: service)
        let coordinator = RecordingCoordinator(api: service, realtime: realtime)
        let claim = try await coordinator.start(
            meetingID: meeting.id,
            language: "en-US",
            translationTarget: "ko",
            sampleRate: 16_000,
            channelCount: 2
        )
        let interleaved = (0..<1_600).flatMap { _ in [Int16(1), Int16(2)] }
        try await coordinator.sendPCM(interleaved)

        await #expect(throws: FinalizationTestFailure.self) {
            _ = try await coordinator.stop()
        }
        #expect(await coordinator.state == .recoveryRequired(claim))
        let partialMeeting = try await service.meeting(id: meeting.id)
        #expect(partialMeeting.endedAt == nil)
        #expect(partialMeeting.transcripts.count == 1)

        try await coordinator.retryFinalization()
        #expect(await coordinator.state == .idle)
        let recoveredMeeting = try await service.meeting(id: meeting.id)
        #expect(recoveredMeeting.endedAt != nil)
        #expect(recoveredMeeting.transcripts.count == 2)
        #expect(Set(recoveredMeeting.transcripts.compactMap(\.resultID)).count == 2)
        #expect(Set(recoveredMeeting.transcripts.compactMap(\.channelID)) == ["ch_0", "ch_1"])
        let payloads = await speechState.payloads()
        #expect(payloads.count == 4)
        #expect(payloads[0] == payloads[2])
        #expect(payloads[1] == payloads[3])

        await coordinator.close()
        await service.shutdown()
    }

    private func verifyConnectedOwnerIsNotFinalized() async throws {
        let fixture = try FinalizationRecoveryFixture()
        defer { fixture.remove() }
        let service = makeTestService(configuration: fixture.configuration)
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(
            title: "Connected recording owner",
            language: "en-US",
            translationTarget: "ko"
        ))
        let owner = NativeRealtimeClient(service: service)
        try await owner.connect()
        let ownerID = try #require(owner.clientID)
        let started = try await service.startRecording(
            meetingID: meeting.id,
            request: StartRecordingRequest(
                socketID: ownerID,
                language: "en-US",
                translationTarget: "ko"
            )
        )

        let recoveryRealtime = NativeRealtimeClient(service: service)
        try await recoveryRealtime.connect()
        let recoveryID = try #require(recoveryRealtime.clientID)
        let recoveryClaim = RecordingClaim(
            meetingID: meeting.id,
            generation: started.generation,
            socketID: recoveryID,
            sampleRate: 16_000,
            channelCount: 1
        )
        let coordinator = RecordingCoordinator(api: service, realtime: recoveryRealtime)
        try await coordinator.adoptRecoveryClaim(recoveryClaim)

        await #expect(throws: RecordingCoordinatorError.finalizationUnconfirmed) {
            try await coordinator.retryFinalization()
        }
        #expect(await coordinator.state == .recoveryRequired(recoveryClaim))
        let ownerStatus = try await service.recordingStatus(socketID: ownerID)
        #expect(ownerStatus.selectionLocked)
        #expect(ownerStatus.recordingOwnedByRequester)
        #expect(try await service.meeting(id: meeting.id).endedAt == nil)

        _ = try await service.finalizeRecording(FinalizeRecordingRequest(
            meetingID: meeting.id,
            generation: started.generation,
            socketID: ownerID
        ))
        await coordinator.close()
        owner.disconnect()
        await service.shutdown()
    }
}

private actor FinalSpeechRetryGate {
    private var paused = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        await withCheckedContinuation { releaseContinuation = $0 }
        paused = false
    }

    func waitUntilPaused() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !paused {
            guard clock.now < deadline else { throw FinalizationTestFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor FailOnceFinalSpeechState {
    private let failingAttempts: Set<Int>
    private let pausedAttempts: Set<Int>
    private let gate: FinalSpeechRetryGate?
    private var recordedPayloads: [Data] = []

    init(
        failingAttempts: Set<Int>,
        pausedAttempts: Set<Int> = [],
        gate: FinalSpeechRetryGate? = nil
    ) {
        self.failingAttempts = failingAttempts
        self.pausedAttempts = pausedAttempts
        self.gate = gate
    }

    func transcribe(pcm: Data) async throws -> NativeTranscriptionResult {
        recordedPayloads.append(pcm)
        let attempt = recordedPayloads.count
        if failingAttempts.contains(attempt) { throw FinalizationTestFailure.injected }
        if pausedAttempts.contains(attempt), let gate { await gate.pause() }
        return NativeTranscriptionResult(
            text: "Recovered final transcript.",
            alternatives: [],
            confidence: 1
        )
    }

    func attemptCount() -> Int { recordedPayloads.count }
    func payloads() -> [Data] { recordedPayloads }
}

private struct FailOnceFinalSpeechService: NativeSpeechServing {
    let state: FailOnceFinalSpeechState

    func isAvailable() -> Bool { true }
    func readiness(language: String) async -> NativeSpeechReadiness { .ready }
    func prepare(language: String, mode: String, showDetails: Bool) async throws {}

    func transcribe(
        language: String,
        sampleRate: Double,
        pcm: Data,
        mode: String,
        showDetails: Bool
    ) async throws -> NativeTranscriptionResult {
        try await state.transcribe(pcm: pcm)
    }
}

private actor FinalizationAttemptSequence {
    private var remainingFailures: Int
    private var recordedRequests: [FinalizeRecordingRequest] = []
    private var successfulAttempts = 0

    init(remainingFailures: Int) {
        self.remainingFailures = remainingFailures
    }

    func attempt(_ request: FinalizeRecordingRequest) throws {
        recordedRequests.append(request)
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw FinalizationTestFailure.injected
        }
        successfulAttempts += 1
    }

    func attemptCount() -> Int { recordedRequests.count }
    func successfulAttemptCount() -> Int { successfulAttempts }
    func requests() -> [FinalizeRecordingRequest] { recordedRequests }
}

private enum FinalizationTestFailure: Error {
    case injected
    case timeout
}

private struct FinalizationRecoveryFixture {
    let root: URL
    let configuration: NativeServiceConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("finalization-recovery-\(UUID().uuidString)", isDirectory: true)
        configuration = NativeServiceConfiguration(
            configURL: root.appendingPathComponent("config.json"),
            defaultDataRoot: root,
            environment: [
                "WHEREWE_SUPPRESS_OPEN": "1",
            ]
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func configure(_ service: NativeService) async throws {
        var request = try await service.settings().document.updateRequest
        request.user.name = "Finalization Recovery Tester"
        request.user.profile = "Validates exactly-once recording finalization."
        _ = try await service.updateSettings(request, etag: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
