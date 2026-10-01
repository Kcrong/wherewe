import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Translation retry recovery", .serialized)
struct TranslationRetryRecoveryTests {
    @Test("repeated translation failures and pending restart recover without duplicate rows")
    func repeatedFailuresRecoverAfterRestart() async throws {
        let fixture = try TranslationRetryFixture()
        defer { fixture.remove() }
        var service: NativeService? = makeTestService(
            configuration: fixture.configuration,
            translationBehavior: .fail
        )
        try await fixture.configure(service!)
        let meeting = try await service!.createMeeting(CreateMeetingRequest(
            title: "Translation retry",
            language: "en-US",
            translationTarget: "ko"
        ))
        let transcriptID = try await service!.insertTranscriptForRetryTest(
            meetingID: meeting.id,
            text: "retry this once translation recovers"
        )

        for _ in 0..<3 {
            let accepted = try await service!.retryTranslation(
                meetingID: meeting.id,
                entityType: .transcript,
                entityID: transcriptID
            )
            #expect(accepted.accepted)
        }
        let failedDetail = try await service!.meeting(id: meeting.id)
        let failed = try #require(failedDetail.transcripts.first)
        #expect(failed.translationStatus == .failed)
        #expect(failed.translationAttempts == 3)
        #expect(failed.translation == nil)
        #expect(failed.translationError?.retryable == true)

        try await service!.markTranslationPendingForRestart(
            meetingID: meeting.id,
            transcriptID: transcriptID
        )
        if let current = service { await current.shutdown() }
        service = nil

        let restarted = makeTestService(configuration: fixture.configuration)
        let recoveredDetail = try await restarted.meeting(id: meeting.id)
        let recovered = try #require(recoveredDetail.transcripts.first)
        #expect(recovered.translationStatus == .idle)
        #expect(recovered.translationAttempts == 3)
        #expect(recovered.translationError == nil)

        _ = try await restarted.retryTranslation(
            meetingID: meeting.id,
            entityType: .transcript,
            entityID: transcriptID
        )
        let detail = try await restarted.meeting(id: meeting.id)
        #expect(detail.transcripts.count == 1)
        let succeeded = try #require(detail.transcripts.first)
        #expect(succeeded.id == transcriptID)
        #expect(succeeded.translationStatus == .succeeded)
        #expect(succeeded.translationAttempts == 4)
        #expect(succeeded.translation == "Translated: retry this once translation recovers")
        #expect(succeeded.translationError == nil)
        await restarted.shutdown()
    }
}

private extension NativeService {
    func insertTranscriptForRetryTest(meetingID: Int, text: String) throws -> Int {
        let result = try requireDatabase().run(
            """
            INSERT INTO transcripts (meeting_id, result_id, text, lang_code, translation_status)
            VALUES (?, ?, ?, 'en-US', 'idle')
            """,
            [.integer(Int64(meetingID)), .text("retry-result"), .text(text)]
        )
        return result.lastInsertID
    }

    func markTranslationPendingForRestart(meetingID: Int, transcriptID: Int) throws {
        _ = try requireDatabase().run(
            """
            UPDATE transcripts
               SET translation_status = 'pending', translation_error = 'interrupted'
             WHERE meeting_id = ? AND id = ?
            """,
            [.integer(Int64(meetingID)), .integer(Int64(transcriptID))]
        )
    }
}

private struct TranslationRetryFixture {
    let root: URL
    let configuration: NativeServiceConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-retry-\(UUID().uuidString)", isDirectory: true)
        configuration = NativeServiceConfiguration(
            configURL: root.appendingPathComponent("config.json"),
            defaultDataRoot: root,
            environment: ["WHEREWE_SUPPRESS_OPEN": "1"]
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func configure(_ service: NativeService) async throws {
        var request = try await service.settings().document.updateRequest
        request.user.name = "Translation Retry Tester"
        request.user.profile = "Validates durable explicit retry state."
        _ = try await service.updateSettings(request, etag: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
