import Foundation

extension NativeService {
    public func editTranscript(
        meetingID: Int,
        transcriptID: Int,
        text: String
    ) async throws -> SegmentEditResponse {
        let database = try requireDatabase()
        guard let transcript = try database.first(
            "SELECT * FROM transcripts WHERE id = ? AND meeting_id = ?",
            [.integer(Int64(transcriptID)), .integer(Int64(meetingID))]
        ), let originalText = transcript.string("text") else {
            throw NativeServiceError.server(status: 404, code: "TRANSCRIPT_NOT_FOUND", message: nil)
        }
        let newText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else {
            throw NativeServiceError.server(status: 400, code: "SEGMENT_TEXT_REQUIRED", message: "Text is required.")
        }
        if let existingID = try database.first(
            """
            SELECT segment_id AS id
              FROM segment_sources
             WHERE transcript_id = ?
             ORDER BY segment_id ASC
             LIMIT 1
            """,
            [.integer(Int64(transcriptID))]
        )?.int("id") {
            return try await editSegment(meetingID: meetingID, segmentID: existingID, text: newText)
        }
        guard let meeting = try database.first(
            "SELECT lang, translate_to FROM meetings WHERE id = ?",
            [.integer(Int64(meetingID))]
        ) else {
            throw NativeServiceError.server(status: 404, code: "MEETING_NOT_FOUND", message: nil)
        }

        let resultID = transcript.string("result_id") ?? "db:\(transcriptID)"
        let corrections = originalText == newText
            ? []
            : [SegmentCorrection(from: originalText, to: newText, reason: "manual")]
        let correctionsJSON = try encodeJSON(corrections)
        let sourceIDsJSON = try encodeJSON([resultID])
        let insert = try database.transaction {
            let inserted = try database.run(
                """
                INSERT INTO transcript_segments (
                  meeting_id, channel_id, speaker, text, translation_target,
                  translation_status, lang_code, corrections, source_ids, order_index
                ) VALUES (?, ?, ?, ?, ?, 'idle', ?, ?, ?, ?)
                """,
                [
                    .integer(Int64(meetingID)), optionalText(transcript.string("channel_id")),
                    optionalText(transcript.string("speaker")), .text(newText),
                    .text(meeting.string("translate_to") ?? "ko"),
                    .text(transcript.string("lang_code") ?? meeting.string("lang") ?? "en-US"),
                    .text(correctionsJSON), .text(sourceIDsJSON), .real(Double(transcriptID)),
                ]
            )
            _ = try database.run(
                "INSERT INTO segment_sources (segment_id, transcript_id) VALUES (?, ?)",
                [.integer(Int64(inserted.lastInsertID)), .integer(Int64(transcriptID))]
            )
            return inserted
        }
        try? await translateEntity(
            meetingID: meetingID,
            entityType: .segment,
            entityID: insert.lastInsertID
        )
        guard let row = try database.first(
            "SELECT * FROM transcript_segments WHERE id = ?",
            [.integer(Int64(insert.lastInsertID))]
        ) else { throw NativeServiceError.decoding }
        let segment = try row.transcriptSegment()
        publish(.segmentsUpdated, ["meetingId": meetingID, "segmentId": segment.id])
        return SegmentEditResponse(segment: segment)
    }

    public func editSegment(
        meetingID: Int,
        segmentID: Int,
        text: String
    ) async throws -> SegmentEditResponse {
        let database = try requireDatabase()
        guard let row = try database.first(
            "SELECT * FROM transcript_segments WHERE id = ? AND meeting_id = ?",
            [.integer(Int64(segmentID)), .integer(Int64(meetingID))]
        ) else {
            throw NativeServiceError.server(status: 404, code: "SEGMENT_NOT_FOUND", message: nil)
        }
        let newText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else {
            throw NativeServiceError.server(status: 400, code: "SEGMENT_TEXT_REQUIRED", message: "Text is required.")
        }
        let oldText = row.string("text") ?? ""
        var corrections: [SegmentCorrection] = decodeJSON(row.string("corrections")) ?? []
        if oldText != newText {
            corrections.append(SegmentCorrection(from: oldText, to: newText, reason: "manual"))
        }
        let correctionsJSON = try encodeJSON(corrections)
        _ = try database.run(
            """
            UPDATE transcript_segments
               SET text = ?, corrections = ?, translation = NULL,
                   translation_provider = NULL, translation_source_hash = NULL,
                   translation_source_version = translation_source_version + 1,
                   translation_status = 'idle', translation_error = NULL,
                   translation_attempts = 0,
                   translation_updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                   updated_at = datetime('now')
             WHERE id = ? AND meeting_id = ?
            """,
            [.text(newText), .text(correctionsJSON), .integer(Int64(segmentID)), .integer(Int64(meetingID))]
        )
        try? await translateEntity(
            meetingID: meetingID,
            entityType: .segment,
            entityID: segmentID
        )
        guard let updated = try database.first(
            "SELECT * FROM transcript_segments WHERE id = ?",
            [.integer(Int64(segmentID))]
        ) else { throw NativeServiceError.decoding }
        let segment = try updated.transcriptSegment()
        publish(.segmentsUpdated, ["meetingId": meetingID, "segmentId": segmentID])
        return SegmentEditResponse(segment: segment)
    }

    public func updateTranslationTarget(
        meetingID: Int,
        target: String
    ) async throws -> TranslationTargetResponse {
        let canonical = canonicalLanguage(target)
        if recordingClaim?.meetingID == meetingID {
            throw NativeServiceError.server(
                status: 409,
                code: "RECORDING_ACTIVE",
                message: "Stop recording before changing translation target language."
            )
        }
        let database = try requireDatabase()
        guard let meeting = try database.first(
            "SELECT translate_to FROM meetings WHERE id = ?",
            [.integer(Int64(meetingID))]
        ) else {
            throw NativeServiceError.server(status: 404, code: "MEETING_NOT_FOUND", message: nil)
        }
        let changed = meeting.string("translate_to") != canonical
        let transcriptCount = try database.first(
            "SELECT COUNT(*) AS count FROM transcripts WHERE meeting_id = ?",
            [.integer(Int64(meetingID))]
        )?.int("count") ?? 0
        let segmentCount = try database.first(
            "SELECT COUNT(*) AS count FROM transcript_segments WHERE meeting_id = ?",
            [.integer(Int64(meetingID))]
        )?.int("count") ?? 0
        if changed {
            try database.transaction {
                _ = try database.run(
                    "UPDATE meetings SET translate_to = ? WHERE id = ?",
                    [.text(canonical), .integer(Int64(meetingID))]
                )
                _ = try database.run(
                    """
                    UPDATE transcripts SET translation = NULL, translation_target = ?,
                      translation_provider = NULL, translation_status = 'idle',
                      translation_error = NULL, translation_attempts = 0,
                      translation_updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
                    WHERE meeting_id = ?
                    """,
                    [.text(canonical), .integer(Int64(meetingID))]
                )
                _ = try database.run(
                    """
                    UPDATE transcript_segments SET translation = NULL, translation_target = ?,
                      translation_provider = NULL, translation_status = 'idle',
                      translation_error = NULL, translation_attempts = 0,
                      translation_updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                      updated_at = datetime('now')
                    WHERE meeting_id = ?
                    """,
                    [.text(canonical), .integer(Int64(meetingID))]
                )
            }
            publish(.translationTargetChanged, [
                "meetingId": meetingID,
                "translationTarget": canonical,
            ])
            Task { await self.translatePending(meetingID: meetingID) }
        }
        return TranslationTargetResponse(
            meetingID: meetingID,
            translationTarget: canonical,
            queued: TranslationQueuedCounts(
                transcripts: changed ? transcriptCount : 0,
                segments: changed ? segmentCount : 0
            )
        )
    }

    public func retryTranslation(
        meetingID: Int,
        entityType: TranslationEntityType,
        entityID: Int
    ) async throws -> TranslationRetryResponse {
        try await translateEntity(
            meetingID: meetingID,
            entityType: entityType,
            entityID: entityID
        )
        return TranslationRetryResponse(accepted: true, entityType: entityType)
    }

    func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        guard let text = String(data: try JSONEncoder().encode(value), encoding: .utf8) else {
            throw NativeServiceError.encoding
        }
        return text
    }

    func decodeJSON<T: Decodable>(_ text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
