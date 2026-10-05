import CryptoKit
import Foundation

struct NativeTranslationOutcome {
    let text: String?
    let provider: String?
    let sourceHash: String
    let status: TranslationStatus
    let error: TranslationErrorDetail?
}

private struct NativeTranslationRequestSnapshot {
    let text: String
    let source: String
    let target: String
    let meetingTarget: String
    let sourceHash: String
    let sourceVersion: Int
}

private func translationSourceHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

extension NativeService {
    func translateText(_ text: String, source: String, target: String) async -> NativeTranslationOutcome {
        let sourceLanguage = canonicalLanguage(source)
        let targetLanguage = canonicalLanguage(target)
        let hash = translationSourceHash(text)
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
            "SELECT text, lang_code, translation_source_version FROM \(table) WHERE id = ? AND meeting_id = ?",
            [.integer(Int64(entityID)), .integer(Int64(meetingID))]
        ), let text = row.string("text") else {
            throw NativeServiceError.server(status: 404, code: "TRANSLATION_ENTITY_NOT_FOUND", message: nil)
        }
        guard let meeting = try database.first(
            "SELECT lang, translate_to FROM meetings WHERE id = ?",
            [.integer(Int64(meetingID))]
        ) else { throw NativeServiceError.server(status: 404, code: "MEETING_NOT_FOUND", message: nil) }
        let meetingTarget = meeting.string("translate_to") ?? "ko"
        let snapshot = NativeTranslationRequestSnapshot(
            text: text,
            source: row.string("lang_code") ?? meeting.string("lang") ?? "en-US",
            target: canonicalLanguage(meetingTarget),
            meetingTarget: meetingTarget,
            sourceHash: translationSourceHash(text),
            sourceVersion: row.int("translation_source_version") ?? 1
        )
        let started = try database.run(
            """
            UPDATE \(table) SET translation = NULL, translation_target = ?,
              translation_provider = 'apple', translation_source_hash = ?,
              translation_status = 'pending', translation_error = NULL,
              translation_attempts = translation_attempts + 1,
              translation_updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
            WHERE id = ? AND meeting_id = ? AND text = ?
              AND translation_source_version = ?
              AND EXISTS (
                SELECT 1 FROM meetings WHERE id = ? AND COALESCE(translate_to, 'ko') = ?
              )
            """,
            [
                .text(snapshot.target), .text(snapshot.sourceHash),
                .integer(Int64(entityID)), .integer(Int64(meetingID)),
                .text(snapshot.text), .integer(Int64(snapshot.sourceVersion)),
                .integer(Int64(meetingID)), .text(snapshot.meetingTarget),
            ]
        )
        guard started.changes == 1 else { return }

        let outcome = await translateText(snapshot.text, source: snapshot.source, target: snapshot.target)
        let stored = try database.run(
            """
            UPDATE \(table) SET translation = ?, translation_target = ?,
              translation_provider = ?, translation_source_hash = ?,
              translation_status = ?, translation_error = ?,
              translation_updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
            WHERE id = ? AND meeting_id = ? AND text = ?
              AND translation_source_version = ?
              AND translation_source_hash = ? AND translation_target = ?
              AND EXISTS (
                SELECT 1 FROM meetings WHERE id = ? AND COALESCE(translate_to, 'ko') = ?
              )
            """,
            [
                optionalText(outcome.text), .text(snapshot.target), optionalText(outcome.provider),
                .text(outcome.sourceHash), .text(outcome.status.rawValue),
                outcome.error.map { .text((try? encodeJSON($0)) ?? "") } ?? .null,
                .integer(Int64(entityID)), .integer(Int64(meetingID)),
                .text(snapshot.text), .integer(Int64(snapshot.sourceVersion)),
                .text(snapshot.sourceHash), .text(snapshot.target),
                .integer(Int64(meetingID)), .text(snapshot.meetingTarget),
            ]
        )
        guard stored.changes == 1 else { return }
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
