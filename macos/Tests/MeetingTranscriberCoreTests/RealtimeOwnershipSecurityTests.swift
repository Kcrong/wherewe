import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Realtime recording ownership security", .serialized)
struct RealtimeOwnershipSecurityTests {
    @Test("stale transcription cannot persist after a newer generation starts")
    func staleTranscriptInsertIsRejected() async throws {
        let fixture = try RealtimeSecurityFixture()
        defer { fixture.remove() }
        let insertGate = RealtimeSuspensionGate()
        let service = makeTestService(configuration: fixture.configuration)
        await service.setRecordingLifecycleObserver(NativeRecordingLifecycleObserver(
            beforeTranscriptInsert: { _ in await insertGate.pause() }
        ))
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Generation takeover"))
        let first = try await startClaim(service, meetingID: meeting.id, clientID: "client-one")
        let request = transcriptionRequest(meetingID: meeting.id, generation: first.generation)

        let staleCommit = Task {
            try await service.commitRealtimeChunk(
                request,
                audio: Data([1, 0]),
                resultIDs: ["stale-result"],
                clientID: "client-one"
            )
        }
        await insertGate.waitUntilPaused()
        _ = try await service.finalizeRecording(FinalizeRecordingRequest(
            meetingID: meeting.id,
            generation: first.generation,
            socketID: "client-one"
        ))
        let second = try await startClaim(service, meetingID: meeting.id, clientID: "client-two")
        await insertGate.release()

        await #expect(throws: NativeServiceError.self) {
            _ = try await staleCommit.value
        }
        let status = try await service.recordingStatus(socketID: "client-two")
        #expect(status.recordingGeneration == second.generation)
        #expect(try await service.meeting(id: meeting.id).transcripts.isEmpty)
    }

    @Test("stale finish cannot clear a newer recording claim")
    func staleFinishDoesNotClearNewClaim() async throws {
        let fixture = try RealtimeSecurityFixture()
        defer { fixture.remove() }
        let finishGate = RealtimeSuspensionGate()
        let service = makeTestService(configuration: fixture.configuration)
        await service.setRecordingLifecycleObserver(NativeRecordingLifecycleObserver(
            beforeFinishClaimClear: { _ in await finishGate.pause() }
        ))
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(title: "Claim clear takeover"))
        let first = try await startClaim(service, meetingID: meeting.id, clientID: "client-one")
        let request = transcriptionRequest(meetingID: meeting.id, generation: first.generation)

        let staleFinish = Task {
            try await service.finishRealtimeTranscription(
                request,
                audio: Data(),
                resultIDs: ["unused"],
                clientID: "client-one"
            )
        }
        await finishGate.waitUntilPaused()
        _ = try await service.finalizeRecording(FinalizeRecordingRequest(
            meetingID: meeting.id,
            generation: first.generation,
            socketID: "client-one"
        ))
        let second = try await startClaim(service, meetingID: meeting.id, clientID: "client-two")
        await finishGate.release()

        await #expect(throws: NativeServiceError.self) {
            _ = try await staleFinish.value
        }
        let status = try await service.recordingStatus(socketID: "client-two")
        #expect(status.recordingGeneration == second.generation)
        #expect(status.recordingOwnedByRequester)
    }

    private func startClaim(
        _ service: NativeService,
        meetingID: Int,
        clientID: String
    ) async throws -> StartRecordingResponse {
        try await service.startRecording(
            meetingID: meetingID,
            request: StartRecordingRequest(
                socketID: clientID,
                language: "en-US",
                translationTarget: "ko"
            )
        )
    }

    private func transcriptionRequest(
        meetingID: Int,
        generation: Int64
    ) -> StartTranscriptionRequest {
        StartTranscriptionRequest(
            meetingID: meetingID,
            generation: generation,
            language: "en-US",
            translationTarget: "ko",
            sampleRate: 16_000,
            channelCount: 1
        )
    }
}

private actor RealtimeSuspensionGate {
    private var paused = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        waitingForEntry.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }
}

private struct RealtimeSecurityFixture {
    let root: URL
    let configuration: NativeServiceConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("realtime-security-\(UUID().uuidString)", isDirectory: true)
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
        request.user.name = "Realtime Security Tester"
        request.user.profile = "Validates generation ownership across suspension."
        _ = try await service.updateSettings(request, etag: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
