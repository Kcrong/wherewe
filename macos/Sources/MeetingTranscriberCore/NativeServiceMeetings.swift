import Foundation

extension NativeService {
    public func meetings() async throws -> [MeetingSummary] {
        try requireDatabase().query(
            "SELECT id, title, lang, translate_to, created_at, ended_at FROM meetings ORDER BY created_at DESC, id DESC"
        ).map { try $0.meetingSummary() }
    }

    public func meeting(id: Int) async throws -> MeetingDetail {
        let database = try requireDatabase()
        guard let row = try database.first("SELECT * FROM meetings WHERE id = ?", [.integer(Int64(id))]) else {
            throw NativeServiceError.server(status: 404, code: "MEETING_NOT_FOUND", message: "Meeting not found.")
        }
        guard let title = row.string("title") else { throw NativeServiceError.decoding }
        let transcripts = try database.query(
            "SELECT * FROM transcripts WHERE meeting_id = ? ORDER BY created_at ASC, id ASC",
            [.integer(Int64(id))]
        ).map { try $0.transcriptRow() }
        let documents = try database.query(
            "SELECT * FROM documents WHERE meeting_id = ? ORDER BY created_at ASC, id ASC",
            [.integer(Int64(id))]
        ).map { try $0.meetingDocument() }
        let segments = try database.query(
            "SELECT * FROM transcript_segments WHERE meeting_id = ? ORDER BY channel_id ASC, order_index ASC, id ASC",
            [.integer(Int64(id))]
        ).map { try $0.transcriptSegment() }
        return MeetingDetail(
            id: id,
            title: title,
            context: row.string("context") ?? "",
            language: row.string("lang") ?? "en-US",
            translationTarget: row.string("translate_to") ?? "ko",
            createdAt: row.string("created_at"),
            endedAt: row.string("ended_at"),
            transcripts: transcripts,
            documents: documents,
            segments: segments
        )
    }

    public func transcriptState(meetingID: Int) async throws -> TranscriptStateResponse {
        let detail = try await meeting(id: meetingID)
        return TranscriptStateResponse(
            meetingID: meetingID,
            translationTarget: detail.translationTarget,
            selectedTranslationProvider: "apple",
            transcripts: detail.transcripts,
            segments: detail.segments
        )
    }

    public func createMeeting(_ request: CreateMeetingRequest) async throws -> CreateMeetingResponse {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw NativeServiceError.server(status: 400, code: "MEETING_INVALID", message: "Meeting details are invalid.")
        }
        let result = try requireDatabase().run(
            "INSERT INTO meetings (title, context, lang, translate_to, mode) VALUES (?, ?, ?, ?, 'meeting')",
            [.text(title), .text(request.context), .text(request.language), .text(canonicalLanguage(request.translationTarget))]
        )
        return CreateMeetingResponse(id: result.lastInsertID)
    }

    public func activateMeeting(id: Int) async throws -> SuccessResponse {
        _ = try await meeting(id: id)
        activeMeetingID = id
        return SuccessResponse(success: true)
    }

    public func updateMeeting(
        id: Int,
        request: UpdateMeetingRequest
    ) async throws -> SuccessResponse {
        let database = try requireDatabase()
        guard try database.first("SELECT id FROM meetings WHERE id = ?", [.integer(Int64(id))]) != nil else {
            throw NativeServiceError.server(status: 404, code: "MEETING_NOT_FOUND", message: nil)
        }
        if let title = request.title {
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw NativeServiceError.server(status: 400, code: "MEETING_TITLE_INVALID", message: nil)
            }
            _ = try database.run("UPDATE meetings SET title = ? WHERE id = ?", [.text(value), .integer(Int64(id))])
        }
        if let context = request.context {
            _ = try database.run("UPDATE meetings SET context = ? WHERE id = ?", [.text(context), .integer(Int64(id))])
        }
        return SuccessResponse(success: true)
    }

    public func updateMeetingContext(id: Int, context: String) async throws -> SuccessResponse {
        let result = try requireDatabase().run(
            "UPDATE meetings SET context = ? WHERE id = ?",
            [.text(context), .integer(Int64(id))]
        )
        guard result.changes == 1 else {
            throw NativeServiceError.server(status: 404, code: "MEETING_NOT_FOUND", message: nil)
        }
        return SuccessResponse(success: true)
    }

    public func deleteMeeting(id: Int, socketID: String?) async throws -> SuccessResponse {
        if recordingClaim?.meetingID == id {
            throw NativeServiceError.server(status: 409, code: "MEETING_RECORDING", message: "Stop recording before deleting this meeting.")
        }
        let database = try requireDatabase()
        let files = try database.query(
            "SELECT file_path FROM documents WHERE meeting_id = ? ORDER BY id ASC",
            [.integer(Int64(id))]
        ).compactMap { $0.string("file_path") }
        let settings = try settingsStore.envelope().document
        let root = URL(fileURLWithPath: settings.paths.files, isDirectory: true)
        let safeFiles = try files.map { path in
            try NativeDocumentPathPolicy.resolveStoredFile(
                path: path,
                within: root,
                operation: .delete,
                fileManager: fileManager
            )
        }
        for url in safeFiles {
            try removeStoredDocumentFile(at: url)
        }
        let result = try database.run("DELETE FROM meetings WHERE id = ?", [.integer(Int64(id))])
        guard result.changes == 1 else {
            throw NativeServiceError.server(status: 404, code: "MEETING_NOT_FOUND", message: nil)
        }
        if activeMeetingID == id { activeMeetingID = nil }
        return SuccessResponse(success: true)
    }

    func canonicalLanguage(_ value: String) -> String {
        let language = value.replacingOccurrences(of: "_", with: "-")
            .lowercased().split(separator: "-").first.map(String.init) ?? ""
        return ["en", "ko", "ja", "zh"].contains(language) ? language : "ko"
    }
}
