import Foundation

extension SQLiteRow {
    func meetingSummary() throws -> MeetingSummary {
        guard let id = int("id"), let title = string("title") else { throw NativeServiceError.decoding }
        return MeetingSummary(
            id: id,
            title: title,
            lang: string("lang") ?? "en-US",
            translateTo: string("translate_to") ?? "ko",
            createdAt: string("created_at"),
            recordingStartedAt: nil,
            recordingEndedAt: string("ended_at")
        )
    }

    func transcriptRow() throws -> TranscriptRow {
        guard let id = int("id"), let meetingID = int("meeting_id"), let text = string("text") else {
            throw NativeServiceError.decoding
        }
        return TranscriptRow(
            id: id,
            meetingID: meetingID,
            resultID: string("result_id"),
            speaker: string("speaker"),
            channelID: string("channel_id"),
            text: text,
            translation: string("translation"),
            translationTarget: string("translation_target"),
            translationProvider: string("translation_provider"),
            translationSourceHash: string("translation_source_hash"),
            translationSourceVersion: int("translation_source_version") ?? 1,
            translationStatus: TranslationStatus(rawValue: string("translation_status") ?? "idle") ?? .idle,
            translationError: decodeJSON(string("translation_error"), as: TranslationErrorDetail.self),
            translationAttempts: int("translation_attempts") ?? 0,
            translationUpdatedAt: string("translation_updated_at"),
            languageCode: string("lang_code"),
            alternatives: decodeJSON(string("alternatives"), as: [String].self) ?? [],
            confidence: double("confidence"),
            transcriptionEngine: string("transcription_engine"),
            transcriptionProvider: string("transcription_provider"),
            transcriptionModel: string("transcription_model"),
            transcriptionMode: string("transcription_mode"),
            resultStage: string("result_stage"),
            createdAt: string("created_at")
        )
    }

    func transcriptSegment() throws -> TranscriptSegment {
        guard let id = int("id"), let meetingID = int("meeting_id"), let text = string("text") else {
            throw NativeServiceError.decoding
        }
        return TranscriptSegment(
            id: id,
            meetingID: meetingID,
            channelID: string("channel_id"),
            speaker: string("speaker"),
            text: text,
            translation: string("translation"),
            translationTarget: string("translation_target"),
            translationProvider: string("translation_provider"),
            translationSourceHash: string("translation_source_hash"),
            translationSourceVersion: int("translation_source_version") ?? 1,
            translationStatus: TranslationStatus(rawValue: string("translation_status") ?? "idle") ?? .idle,
            translationError: decodeJSON(string("translation_error"), as: TranslationErrorDetail.self),
            translationAttempts: int("translation_attempts") ?? 0,
            translationUpdatedAt: string("translation_updated_at"),
            languageCode: string("lang_code"),
            corrections: decodeJSON(string("corrections"), as: [SegmentCorrection].self) ?? [],
            sourceIDs: decodeJSON(string("source_ids"), as: [String].self) ?? [],
            orderIndex: double("order_index") ?? 0,
            createdAt: string("created_at"),
            updatedAt: string("updated_at")
        )
    }

    func meetingDocument() throws -> MeetingDocument {
        guard let id = int("id"), let meetingID = int("meeting_id"),
              let name = string("name"), let format = string("format") else {
            throw NativeServiceError.decoding
        }
        return MeetingDocument(
            id: id,
            meetingID: meetingID,
            name: name,
            format: format,
            createdAt: string("created_at")
        )
    }

    func glossaryEntry() throws -> GlossaryEntry {
        guard let id = int("id"), let phrase = string("phrase"), let language = string("lang") else {
            throw NativeServiceError.decoding
        }
        return GlossaryEntry(
            id: id,
            phrase: phrase,
            displayAs: string("display_as"),
            language: language,
            meetingID: int("meeting_id"),
            createdAt: string("created_at")
        )
    }

    func uploadedDocument(fileManager: FileManager = .default) throws -> UploadedDocument {
        guard let id = int("id"), let name = string("name"),
              let format = string("format"), let path = string("file_path") else {
            throw NativeServiceError.decoding
        }
        let size = ((try? fileManager.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0
        return UploadedDocument(id: id, name: name, format: format, size: size)
    }

    private func decodeJSON<T: Decodable>(_ text: String?, as type: T.Type) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
