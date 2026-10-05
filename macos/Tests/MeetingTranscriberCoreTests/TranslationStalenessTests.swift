import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Translation result freshness", .serialized)
struct TranslationStalenessTests {
    @Test("source edits discard an older in-flight translation")
    func sourceEditDiscardsStaleTranslation() async throws {
        let fixture = try TranslationStalenessFixture()
        defer { fixture.remove() }
        let gate = SuspendedTranslationGate()
        let service = NativeService(
            configuration: fixture.configuration,
            speechService: DeterministicSpeechService(),
            translationService: SuspendedTranslationService(gate: gate)
        )
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(
            title: "Source edit freshness",
            language: "en-US",
            translationTarget: "ko"
        ))
        let segmentID = try await service.insertSegmentForStalenessTest(
            meetingID: meeting.id,
            text: "Original source"
        )

        let staleTranslation = Task {
            try await service.retryTranslation(
                meetingID: meeting.id,
                entityType: .segment,
                entityID: segmentID
            )
        }
        try await gate.waitUntilRequests(1)
        let edit = Task {
            try await service.editSegment(
                meetingID: meeting.id,
                segmentID: segmentID,
                text: "Edited source"
            )
        }
        do {
            try await gate.waitUntilRequests(2)
        } catch {
            await gate.releaseAll()
            _ = try? await staleTranslation.value
            _ = try? await edit.value
            throw error
        }

        await gate.release(request: 1)
        let editResponse = try await edit.value
        #expect(editResponse.segment.translation == "Translated to ko: Edited source")
        await gate.release(request: 0)
        _ = try await staleTranslation.value

        let stored = try #require(try await service.meeting(id: meeting.id).segments.first)
        #expect(stored.text == "Edited source")
        #expect(stored.translation == "Translated to ko: Edited source")
        #expect(stored.translationTarget == "ko")
        #expect(stored.translationSourceVersion == 2)
        #expect(stored.translationStatus == .succeeded)
        #expect(stored.translationAttempts == 1)
        await service.shutdown()
    }

    @Test("target changes discard an older in-flight translation")
    func targetChangeDiscardsStaleTranslation() async throws {
        let fixture = try TranslationStalenessFixture()
        defer { fixture.remove() }
        let gate = SuspendedTranslationGate()
        let service = NativeService(
            configuration: fixture.configuration,
            speechService: DeterministicSpeechService(),
            translationService: SuspendedTranslationService(gate: gate)
        )
        try await fixture.configure(service)
        let meeting = try await service.createMeeting(CreateMeetingRequest(
            title: "Target freshness",
            language: "en-US",
            translationTarget: "ko"
        ))
        let transcriptID = try await service.insertTranscriptForStalenessTest(
            meetingID: meeting.id,
            text: "Target language source"
        )

        let staleTranslation = Task {
            try await service.retryTranslation(
                meetingID: meeting.id,
                entityType: .transcript,
                entityID: transcriptID
            )
        }
        try await gate.waitUntilRequests(1)
        let response = try await service.updateTranslationTarget(meetingID: meeting.id, target: "ja")
        #expect(response.translationTarget == "ja")
        #expect(response.queued.transcripts == 1)
        do {
            try await gate.waitUntilRequests(2)
        } catch {
            await gate.releaseAll()
            _ = try? await staleTranslation.value
            throw error
        }

        await gate.release(request: 1)
        _ = try await waitForTranscriptTranslation(
            service: service,
            meetingID: meeting.id,
            expected: "Translated to ja: Target language source"
        )
        await gate.release(request: 0)
        _ = try await staleTranslation.value

        let detail = try await service.meeting(id: meeting.id)
        let stored = try #require(detail.transcripts.first)
        #expect(detail.translationTarget == "ja")
        #expect(stored.translation == "Translated to ja: Target language source")
        #expect(stored.translationTarget == "ja")
        #expect(stored.translationSourceVersion == 1)
        #expect(stored.translationStatus == .succeeded)
        #expect(stored.translationAttempts == 1)
        await service.shutdown()
    }

    private func waitForTranscriptTranslation(
        service: NativeService,
        meetingID: Int,
        expected: String
    ) async throws -> TranscriptRow {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if let transcript = try await service.meeting(id: meetingID).transcripts.first,
               transcript.translation == expected {
                return transcript
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TranslationStalenessError.timeout
    }
}

private struct SuspendedTranslationRequest: Sendable {
    let text: String
    let target: String
}

private actor SuspendedTranslationGate {
    private var requests: [SuspendedTranslationRequest] = []
    private var continuations: [Int: CheckedContinuation<String, Never>] = [:]

    func translate(_ text: String, target: String) async -> String {
        let request = requests.count
        requests.append(SuspendedTranslationRequest(text: text, target: target))
        return await withCheckedContinuation { continuations[request] = $0 }
    }

    func waitUntilRequests(_ expected: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while requests.count < expected {
            guard clock.now < deadline else { throw TranslationStalenessError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release(request: Int) {
        guard requests.indices.contains(request),
              let continuation = continuations.removeValue(forKey: request) else { return }
        let value = requests[request]
        continuation.resume(returning: "Translated to \(value.target): \(value.text)")
    }

    func releaseAll() {
        for request in continuations.keys.sorted() {
            release(request: request)
        }
    }
}

private struct SuspendedTranslationService: NativeTranslationServing {
    let gate: SuspendedTranslationGate

    func status(source: String, target: String) async throws -> String { "installed" }

    func translate(_ text: String, source: String, target: String) async throws -> String {
        await gate.translate(text, target: target)
    }

    func reset() async {
        await gate.releaseAll()
    }
}

private enum TranslationStalenessError: Error {
    case timeout
}

private extension NativeService {
    func insertSegmentForStalenessTest(meetingID: Int, text: String) throws -> Int {
        try requireDatabase().run(
            """
            INSERT INTO transcript_segments (
              meeting_id, text, translation_target, translation_status,
              lang_code, source_ids, order_index
            ) VALUES (?, ?, 'ko', 'idle', 'en-US', '[]', 1)
            """,
            [.integer(Int64(meetingID)), .text(text)]
        ).lastInsertID
    }

    func insertTranscriptForStalenessTest(meetingID: Int, text: String) throws -> Int {
        try requireDatabase().run(
            """
            INSERT INTO transcripts (
              meeting_id, result_id, text, translation_target, translation_status, lang_code
            ) VALUES (?, 'staleness-result', ?, 'ko', 'idle', 'en-US')
            """,
            [.integer(Int64(meetingID)), .text(text)]
        ).lastInsertID
    }
}

private struct TranslationStalenessFixture {
    let root: URL
    let configuration: NativeServiceConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-staleness-\(UUID().uuidString)", isDirectory: true)
        configuration = NativeServiceConfiguration(
            configURL: root.appendingPathComponent("config.json"),
            defaultDataRoot: root,
            environment: ["WHEREWE_SUPPRESS_OPEN": "1"]
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func configure(_ service: NativeService) async throws {
        var request = try await service.settings().document.updateRequest
        request.user.name = "Translation Staleness Tester"
        request.user.profile = "Validates in-flight translation freshness."
        _ = try await service.updateSettings(request, etag: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
