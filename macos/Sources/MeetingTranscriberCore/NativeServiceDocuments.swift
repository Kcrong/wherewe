import Foundation

extension NativeService {
    public func documents(meetingID: Int) async throws -> [UploadedDocument] {
        let database = try requireDatabase()
        return try database.query(
            "SELECT * FROM documents WHERE meeting_id = ? ORDER BY created_at ASC, id ASC",
            [.integer(Int64(meetingID))]
        ).map { try $0.uploadedDocument(fileManager: fileManager) }
    }

    public func uploadDocument(
        meetingID: Int,
        name: String,
        data: Data
    ) async throws -> UploadResponse {
        guard data.count <= 5 * 1_024 * 1_024 else {
            throw NativeServiceError.server(status: 413, code: "FILE_TOO_LARGE", message: "Files must be 5 MB or smaller.")
        }
        let database = try requireDatabase()
        guard try database.first("SELECT id FROM meetings WHERE id = ?", [.integer(Int64(meetingID))]) != nil else {
            throw NativeServiceError.server(status: 404, code: "MEETING_NOT_FOUND", message: nil)
        }
        let safeName = URL(fileURLWithPath: name).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = URL(fileURLWithPath: safeName).pathExtension.lowercased()
        guard !safeName.isEmpty, ["pdf", "md", "txt", "html", "csv"].contains(ext) else {
            throw NativeServiceError.server(
                status: 400,
                code: "FILE_FORMAT_UNSUPPORTED",
                message: "Supported files are PDF, Markdown, TXT, HTML, and CSV."
            )
        }
        let settings = try settingsStore.envelope().document
        let root = try NativeStoragePathPolicy.secureDirectory(
            URL(fileURLWithPath: settings.paths.files, isDirectory: true),
            fileManager: fileManager
        )
        let storedName = "\(meetingID)_\(Int(Date().timeIntervalSince1970 * 1_000))_\(UUID().uuidString)_\(safeName)"
        let target = root.appendingPathComponent(storedName).standardizedFileURL
        guard target.deletingLastPathComponent() == root else {
            throw NativeServiceError.server(status: 400, code: "FILE_NAME_INVALID", message: nil)
        }
        do {
            try data.write(to: target, options: .withoutOverwriting)
            try NativeStoragePathPolicy.securePrivateFile(
                target,
                maximumBytes: 5 * 1_024 * 1_024,
                fileManager: fileManager
            )
            let result = try database.run(
                "INSERT INTO documents (meeting_id, name, format, file_path) VALUES (?, ?, ?, ?)",
                [.integer(Int64(meetingID)), .text(safeName), .text(ext), .text(target.path)]
            )
            return UploadResponse(
                success: true,
                id: result.lastInsertID,
                name: safeName,
                format: ext
            )
        } catch {
            try? fileManager.removeItem(at: target)
            throw error
        }
    }

    public func documentContent(id: Int) async throws -> DocumentContent {
        let database = try requireDatabase()
        guard let row = try database.first("SELECT * FROM documents WHERE id = ?", [.integer(Int64(id))]),
              let path = row.string("file_path"),
              let name = row.string("name"),
              let format = row.string("format") else {
            throw NativeServiceError.server(status: 404, code: "DOCUMENT_NOT_FOUND", message: nil)
        }
        let settings = try settingsStore.envelope().document
        let root = URL(fileURLWithPath: settings.paths.files, isDirectory: true)
        let url = try NativeDocumentPathPolicy.resolveStoredFile(
            path: path,
            within: root,
            operation: .read,
            fileManager: fileManager
        )
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "document"
        return DocumentContent(
            data: data,
            contentType: format == "pdf" ? "application/pdf" : "text/plain; charset=utf-8",
            contentDisposition: "inline; filename*=UTF-8''\(encodedName)"
        )
    }

    public func deleteDocument(id: Int) async throws -> SuccessResponse {
        let database = try requireDatabase()
        guard let row = try database.first("SELECT file_path FROM documents WHERE id = ?", [.integer(Int64(id))]),
              let path = row.string("file_path") else {
            throw NativeServiceError.server(status: 404, code: "DOCUMENT_NOT_FOUND", message: nil)
        }
        let settings = try settingsStore.envelope().document
        let root = URL(fileURLWithPath: settings.paths.files, isDirectory: true)
        let url = try NativeDocumentPathPolicy.resolveStoredFile(
            path: path,
            within: root,
            operation: .delete,
            fileManager: fileManager
        )
        try removeStoredDocumentFile(at: url)
        _ = try database.run("DELETE FROM documents WHERE id = ?", [.integer(Int64(id))])
        return SuccessResponse(success: true)
    }

    func removeStoredDocumentFile(at url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw NativeServiceError.server(
                status: 500,
                code: "FILE_DELETE_FAILED",
                message: "The attachment file could not be deleted. The record was kept; check file permissions and try again."
            )
        }
    }

    public func glossary(language: String) async throws -> [GlossaryEntry] {
        try requireDatabase().query(
            "SELECT * FROM glossary WHERE lang = ? AND meeting_id IS NULL ORDER BY phrase ASC",
            [.text(language)]
        ).map { try $0.glossaryEntry() }
    }

    public func meetingGlossary(meetingID: Int) async throws -> [GlossaryEntry] {
        try requireDatabase().query(
            "SELECT * FROM glossary WHERE meeting_id = ? ORDER BY lang ASC, phrase ASC",
            [.integer(Int64(meetingID))]
        ).map { try $0.glossaryEntry() }
    }

    public func createGlossary(_ request: GlossaryMutationRequest) async throws -> CreatedIDResponse {
        let phrase = request.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase.count <= 500 else {
            throw NativeServiceError.server(status: 400, code: "GLOSSARY_INVALID", message: "Phrase is required.")
        }
        let database = try requireDatabase()
        if let existing = try database.first(
            "SELECT id FROM glossary WHERE phrase = ? AND lang = ? AND meeting_id IS NULL",
            [.text(phrase), .text(request.language)]
        )?.int("id") {
            return CreatedIDResponse(id: existing)
        }
        let result = try database.run(
            "INSERT INTO glossary (phrase, display_as, lang, meeting_id) VALUES (?, ?, ?, NULL)",
            [.text(phrase), optionalText(request.displayAs), .text(request.language)]
        )
        return CreatedIDResponse(id: result.lastInsertID)
    }

    public func updateGlossary(
        id: Int,
        request: GlossaryMutationRequest
    ) async throws -> SuccessResponse {
        let phrase = request.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase.count <= 500 else {
            throw NativeServiceError.server(status: 400, code: "GLOSSARY_INVALID", message: nil)
        }
        let result = try requireDatabase().run(
            "UPDATE glossary SET phrase = ?, display_as = ?, lang = ? WHERE id = ?",
            [.text(phrase), optionalText(request.displayAs), .text(request.language), .integer(Int64(id))]
        )
        guard result.changes == 1 else {
            throw NativeServiceError.server(status: 404, code: "GLOSSARY_NOT_FOUND", message: nil)
        }
        return SuccessResponse(success: true)
    }

    public func deleteGlossary(id: Int) async throws -> SuccessResponse {
        let result = try requireDatabase().run("DELETE FROM glossary WHERE id = ?", [.integer(Int64(id))])
        guard result.changes == 1 else {
            throw NativeServiceError.server(status: 404, code: "GLOSSARY_NOT_FOUND", message: nil)
        }
        return SuccessResponse(success: true)
    }

    func optionalText(_ value: String?) -> SQLiteValue {
        guard let value else { return .null }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .null : .text(text)
    }
}
