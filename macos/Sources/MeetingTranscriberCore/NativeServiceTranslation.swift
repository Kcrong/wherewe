import CryptoKit
import Foundation

struct NativeTranslationOutcome {
    let text: String?
    let provider: String?
    let sourceHash: String
    let status: TranslationStatus
    let error: TranslationErrorDetail?
}

extension NativeService {
    func translateText(_ text: String, source: String, target: String) async -> NativeTranslationOutcome {
        let sourceLanguage = canonicalLanguage(source)
        let targetLanguage = canonicalLanguage(target)
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        if sourceLanguage == targetLanguage {
            return NativeTranslationOutcome(
                text: nil,
                provider: nil,
                sourceHash: hash,
                status: .notRequired,
                error: nil
            )
        }
        do {
            let translated = try await translationService.translate(
                text,
                source: sourceLanguage,
                target: targetLanguage
            )
            return NativeTranslationOutcome(
                text: translated,
                provider: "apple",
                sourceHash: hash,
                status: .succeeded,
                error: nil
            )
        } catch {
            return NativeTranslationOutcome(
                text: nil,
                provider: "apple",
                sourceHash: hash,
                status: .failed,
                error: TranslationErrorDetail(
                    code: "APPLE_TRANSLATION_FAILED",
                    message: String(error.localizedDescription.prefix(240)),
                    retryable: true
                )
            )
        }
    }

    func translateEntity(
        meetingID: Int,
        entityType: TranslationEntityType,
        entityID: Int
    ) async throws {
        let database = try requireDatabase()
        let table = entityType == .transcript ? "transcripts" : "transcript_segments"
        guard let row = try database.first(
            "SELECT text, lang_code FROM \(table) WHERE id = ? AND meeting_id = ?",
            [.integer(Int64(entityID)), .integer(Int64(meetingID))]
        ), let text = row.string("text") else {
            throw NativeServiceError.server(status: 404, code: "TRANSLATION_ENTITY_NOT_FOUND", message: nil)
        }
        guard let meeting = try database.first(
            "SELECT lang, translate_to FROM meetings WHERE id = ?",
            [.integer(Int64(meetingID))]
        ) else { throw NativeServiceError.server(status: 404, code: "MEETING_NOT_FOUND", message: nil) }
        let source = row.string("lang_code") ?? meeting.string("lang") ?? "en-US"
        let target = meeting.string("translate_to") ?? "ko"
        _ = try database.run(
            """
            UPDATE \(table) SET translation = NULL, translation_target = ?,
              translation_provider = 'apple', translation_status = 'pending',
              translation_error = NULL, translation_attempts = translation_attempts + 1,
              translation_updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
            WHERE id = ? AND meeting_id = ?
            """,
            [.text(target), .integer(Int64(entityID)), .integer(Int64(meetingID))]
        )
        let outcome = await translateText(text, source: source, target: target)
        _ = try database.run(
            """
            UPDATE \(table) SET translation = ?, translation_target = ?,
              translation_provider = ?, translation_source_hash = ?,
              translation_status = ?, translation_error = ?,
              translation_updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
            WHERE id = ? AND meeting_id = ?
            """,
            [
                optionalText(outcome.text), .text(target), optionalText(outcome.provider),
                .text(outcome.sourceHash), .text(outcome.status.rawValue),
                outcome.error.map { .text((try? encodeJSON($0)) ?? "") } ?? .null,
                .integer(Int64(entityID)), .integer(Int64(meetingID)),
            ]
        )
        publish(.translationUpdated, [
            "meetingId": meetingID,
            "entityType": entityType.rawValue,
            "entityId": entityID,
        ])
    }

    func translatePending(meetingID: Int) async {
        guard let database = try? requireDatabase() else { return }
        let transcriptIDs = (try? database.query(
            "SELECT id FROM transcripts WHERE meeting_id = ? AND translation_status IN ('idle','failed') ORDER BY id ASC",
            [.integer(Int64(meetingID))]
        ).compactMap { $0.int("id") }) ?? []
        let segmentIDs = (try? database.query(
            "SELECT id FROM transcript_segments WHERE meeting_id = ? AND translation_status IN ('idle','failed') ORDER BY id ASC",
            [.integer(Int64(meetingID))]
        ).compactMap { $0.int("id") }) ?? []
        for id in transcriptIDs { try? await translateEntity(meetingID: meetingID, entityType: .transcript, entityID: id) }
        for id in segmentIDs { try? await translateEntity(meetingID: meetingID, entityType: .segment, entityID: id) }
    }
}
