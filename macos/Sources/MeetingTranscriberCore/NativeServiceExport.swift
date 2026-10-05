import AppKit
import Foundation

extension NativeService {
    public func exportMeeting(id: Int) async throws -> MeetingExportResponse {
        try Task.checkCancellation()
        let detail = try await meeting(id: id)
        let database = try requireDatabase()
        let settings = try settingsStore.envelope().document
        let attachmentRoot = URL(fileURLWithPath: settings.paths.files, isDirectory: true)
        let globalTerms = try await glossary(language: canonicalLanguage(detail.language))
        let meetingTerms = try await meetingGlossary(meetingID: id)
        let glossary = globalTerms + meetingTerms
        let documentRows = try database.query(
            "SELECT * FROM documents WHERE meeting_id = ? ORDER BY created_at ASC, id ASC",
            [.integer(Int64(id))]
        )
        try Task.checkCancellation()
        let base = exportBaseURL()
        try secureDirectory(base)
        let titleSlug = slug(detail.title)
        let exportURL = base.appendingPathComponent(
            "meeting-\(id)-\(titleSlug)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            let backgroundURL = exportURL.appendingPathComponent("background", isDirectory: true)
            let attachmentsURL = backgroundURL.appendingPathComponent("files", isDirectory: true)
            try secureDirectory(exportURL)
            try secureDirectory(backgroundURL)
            try secureDirectory(attachmentsURL)
            await exportLifecycleObserver.afterDirectoryCreation(exportURL)
            try Task.checkCancellation()

            let counts = ExportCounts(
                transcripts: detail.transcripts.count,
                segments: detail.segments.count,
                documents: detail.documents.count,
                glossary: glossary.count
            )
            try writeMetadata(detail, counts: counts, to: exportURL.appendingPathComponent("meeting.json"))
            try Task.checkCancellation()
            try writeText(backgroundText(detail, glossary: glossary), to: backgroundURL.appendingPathComponent("context.md"))
            try Task.checkCancellation()
            let copied = try copyAttachments(documentRows, from: attachmentRoot, to: attachmentsURL)
            try Task.checkCancellation()
            try writeText(transcriptText(detail), to: exportURL.appendingPathComponent("transcript.md"))
            try Task.checkCancellation()

            return MeetingExportResponse(
                success: true,
                path: exportURL.path,
                files: ExportFiles(
                    metadata: "meeting.json",
                    transcript: "transcript.md",
                    background: "background/context.md",
                    attachments: copied.map { "background/files/\($0)" }
                ),
                counts: counts
            )
        } catch {
            try? fileManager.removeItem(at: exportURL)
            throw error
        }
    }

    public func reveal(path: String) async throws -> SuccessResponse {
        let target: URL
        do {
            target = try NativeStoragePathPolicy.resolveContainedDirectory(
                path: path,
                within: exportBaseURL(),
                fileManager: fileManager
            )
        } catch {
            throw NativeServiceError.server(
                status: 400,
                code: "REVEAL_PATH_INVALID",
                message: "Path is not an app export."
            )
        }
        if configuration.environment["CI"] == nil,
           configuration.environment["WHEREWE_SUPPRESS_OPEN"] == nil {
            _ = await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        }
        return SuccessResponse(success: true)
    }

    func exportBaseURL() -> URL {
        fileManager.temporaryDirectory.appendingPathComponent("wherewe", isDirectory: true)
    }

    func secureDirectory(_ url: URL) throws {
        _ = try NativeStoragePathPolicy.secureDirectory(url, fileManager: fileManager)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        try NativeStoragePathPolicy.securePrivateFile(url, fileManager: fileManager)
    }

    private func writeMetadata(_ meeting: MeetingDetail, counts: ExportCounts, to url: URL) throws {
        let object: [String: Any] = [
            "id": meeting.id,
            "title": meeting.title,
            "lang": meeting.language,
            "translate_to": meeting.translationTarget,
            "created_at": meeting.createdAt ?? NSNull(),
            "ended_at": meeting.endedAt ?? NSNull(),
            "recording_started_at": meeting.transcripts.first?.createdAt ?? NSNull(),
            "recording_ended_at": meeting.transcripts.last?.createdAt ?? NSNull(),
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "counts": [
                "transcripts": counts.transcripts,
                "segments": counts.segments,
                "documents": counts.documents,
                "glossary": counts.glossary,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .withoutOverwriting)
        try NativeStoragePathPolicy.securePrivateFile(url, fileManager: fileManager)
    }

    private func backgroundText(_ meeting: MeetingDetail, glossary: [GlossaryEntry]) -> String {
        var lines = [
            "# \(meeting.title) — Background", "",
            "- Meeting ID: \(meeting.id)",
            "- Created: \(meeting.createdAt ?? "unknown")",
            "- Language: \(meeting.language)", "", "## Context", "",
            meeting.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty)" : meeting.context,
        ]
        if !meeting.documents.isEmpty {
            lines += ["", "## Attached Files", ""]
            lines += meeting.documents.map { "- `files/\($0.name)` (\($0.format))" }
        }
        if !glossary.isEmpty {
            lines += ["", "## Glossary", ""]
            lines += glossary.map { entry in
                let display = entry.displayAs.map { " → \($0)" } ?? ""
                return "- **\(entry.phrase)**\(display) _[\(entry.language)]_"
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func transcriptText(_ meeting: MeetingDetail) -> String {
        let covered = Set(meeting.segments.flatMap(\.sourceIDs))
        let raw = meeting.transcripts.filter { row in
            guard let resultID = row.resultID else { return true }
            return !covered.contains(resultID)
        }
        var lines = [
            "# \(meeting.title) — Transcript", "",
            "_\(meeting.segments.count + raw.count) entries (\(meeting.segments.count) edited + \(raw.count) raw) • \(meeting.language)_", "",
        ]
        for segment in meeting.segments {
            if let speaker = speakerLabel(segment.channelID, speaker: segment.speaker) { lines.append("**\(speaker)**") }
            lines.append(segment.text)
            if let translation = segment.translation { lines += ["", "> \(translation)"] }
            lines.append("")
        }
        for row in raw {
            let timestamp = row.createdAt.map { "_\($0)_ " } ?? ""
            let speaker = speakerLabel(row.channelID, speaker: row.speaker).map { "**\($0)** " } ?? ""
            lines.append("\(timestamp)\(speaker)_(raw)_")
            lines.append(row.text)
            if let translation = row.translation { lines += ["", "> \(translation)"] }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func copyAttachments(
        _ rows: [SQLiteRow],
        from attachmentRoot: URL,
        to directory: URL
    ) throws -> [String] {
        var names = Set<String>()
        var copied: [String] = []
        for row in rows {
            try Task.checkCancellation()
            guard let sourcePath = row.string("file_path"), let id = row.int("id") else {
                throw NativeServiceError.decoding
            }
            let source = try NativeDocumentPathPolicy.resolveStoredFile(
                path: sourcePath,
                within: attachmentRoot,
                operation: .read,
                fileManager: fileManager
            )
            var name = URL(fileURLWithPath: row.string("name") ?? "document-\(id)").lastPathComponent
            if name.isEmpty { name = "document-\(id)" }
            if names.contains(name) {
                let url = URL(fileURLWithPath: name)
                name = "\(url.deletingPathExtension().lastPathComponent)-\(id).\(url.pathExtension)"
            }
            let target = directory.appendingPathComponent(name).standardizedFileURL
            guard target.deletingLastPathComponent() == directory.standardizedFileURL else {
                throw NativeServiceError.encoding
            }
            try fileManager.copyItem(at: source, to: target)
            try NativeStoragePathPolicy.securePrivateFile(
                target,
                maximumBytes: 5 * 1_024 * 1_024,
                fileManager: fileManager
            )
            names.insert(name)
            copied.append(name)
        }
        return copied
    }

    private func speakerLabel(_ channel: String?, speaker: String?) -> String? {
        if channel == "ch_0" { return "[Me]" }
        if channel == "ch_1" { return "[Other]" }
        return speaker.map { "[Speaker \($0)]" }
    }

    private func slug(_ value: String) -> String {
        let normalized = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let joined = String(normalized).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        return String((joined.isEmpty ? "meeting" : joined).prefix(60))
    }
}
