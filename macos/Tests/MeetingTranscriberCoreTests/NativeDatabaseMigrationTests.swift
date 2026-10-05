import Foundation
import SQLite3
import Testing
@testable import MeetingTranscriberCore

@Suite("Native database migration")
struct NativeDatabaseMigrationTests {
    @Test("legacy migration restores transcript cascade without rewriting history")
    func legacyMigrationRestoresTranscriptCascade() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-db-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("meetings.db")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { if let handle { sqlite3_close(handle) } }
        let legacy = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE meetings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          context TEXT DEFAULT '',
          lang TEXT DEFAULT 'en-US',
          translate_to TEXT DEFAULT 'ko',
          mode TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          ended_at TEXT
        );
        CREATE TABLE transcripts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          meeting_id INTEGER NOT NULL,
          result_id TEXT,
          speaker TEXT,
          channel_id TEXT,
          text TEXT NOT NULL,
          translation TEXT,
          translation_provider TEXT,
          lang_code TEXT,
          transcription_engine TEXT,
          transcription_provider TEXT,
          transcription_model TEXT,
          transcription_mode TEXT,
          result_stage TEXT,
          refinement_source_text TEXT,
          refinement_source_provider TEXT,
          created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE legacy_auxiliary (
          id INTEGER PRIMARY KEY,
          value TEXT NOT NULL
        );
        INSERT INTO meetings (title, mode) VALUES ('Legacy meeting', 'legacy-mode');
        INSERT INTO transcripts (
          meeting_id, result_id, text, translation, translation_provider,
          transcription_engine, transcription_provider, transcription_model,
          transcription_mode, result_stage, refinement_source_text,
          refinement_source_provider
        ) VALUES (
          1, 'legacy-1', 'Hello', '안녕하세요', 'historical-translation',
          'historical-engine', 'historical-provider', 'historical-model',
          'historical-mode', 'historical-stage', 'historical-source-text',
          'historical-source-provider'
        );
        INSERT INTO legacy_auxiliary (id, value) VALUES (1, 'preserve');
        """
        #expect(sqlite3_exec(handle, legacy, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        handle = nil

        let database = try NativeDatabase(url: url)
        let meetingColumns = Set(try database.query("PRAGMA table_info(meetings)").compactMap { $0.string("name") })
        let transcriptColumns = Set(try database.query("PRAGMA table_info(transcripts)").compactMap { $0.string("name") })
        #expect(meetingColumns.contains("mode"))
        #expect(transcriptColumns.isSuperset(of: [
            "alternatives", "confidence", "transcription_provider",
            "translation_status", "translation_source_version",
        ]))
        #expect(try database.first("SELECT mode FROM meetings WHERE id = 1")?.string("mode") == "meeting")

        let storedRow = try database.first("SELECT * FROM transcripts WHERE id = 1")
        let row = try #require(storedRow)
        #expect(row.string("text") == "Hello")
        #expect(row.string("translation") == "안녕하세요")
        #expect(row.string("transcription_engine") == "historical-engine")
        #expect(row.string("transcription_provider") == "historical-provider")
        #expect(row.string("transcription_model") == "historical-model")
        #expect(row.string("transcription_mode") == "historical-mode")
        #expect(row.string("result_stage") == "historical-stage")
        #expect(row.string("translation_provider") == "historical-translation")
        #expect(row.string("translation_status") == "succeeded")
        #expect(row.string("refinement_source_text") == "historical-source-text")
        #expect(row.string("refinement_source_provider") == "historical-source-provider")
        #expect(try database.first("SELECT value FROM legacy_auxiliary WHERE id = 1")?.string("value") == "preserve")
        #expect(try database.first("SELECT COUNT(*) AS count FROM transcripts")?.int("count") == 1)

        let foreignKeys = try database.query("PRAGMA foreign_key_list(transcripts)")
        #expect(foreignKeys.contains { row in
            row.string("table") == "meetings"
                && row.string("from") == "meeting_id"
                && row.string("to") == "id"
                && row.string("on_delete") == "CASCADE"
        })
        #expect(try database.query("PRAGMA foreign_key_check").isEmpty)

        _ = try database.run("DELETE FROM meetings WHERE id = 1")
        #expect(try database.first("SELECT COUNT(*) AS count FROM transcripts")?.int("count") == 0)
        #expect(try database.first("SELECT value FROM legacy_auxiliary WHERE id = 1")?.string("value") == "preserve")
    }
}
