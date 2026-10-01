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

        for expectedAttempts in [2, 4] {
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
