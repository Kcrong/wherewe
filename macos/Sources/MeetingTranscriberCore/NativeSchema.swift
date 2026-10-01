enum NativeSchema {
    static let tables = """
    CREATE TABLE IF NOT EXISTS meetings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL DEFAULT 'Untitled Meeting',
      context TEXT DEFAULT '',
      lang TEXT DEFAULT 'en-US',
      translate_to TEXT DEFAULT 'ko',
      mode TEXT NOT NULL DEFAULT 'meeting' CHECK (mode = 'meeting'),
      created_at TEXT DEFAULT (datetime('now')),
      ended_at TEXT
    );
    CREATE TABLE IF NOT EXISTS transcripts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      meeting_id INTEGER NOT NULL,
      result_id TEXT,
      speaker TEXT,
      channel_id TEXT,
      text TEXT NOT NULL,
      translation TEXT,
      translation_target TEXT,
      translation_provider TEXT,
      translation_source_hash TEXT,
      translation_source_version INTEGER NOT NULL DEFAULT 1,
      translation_status TEXT NOT NULL DEFAULT 'idle',
      translation_error TEXT,
      translation_attempts INTEGER NOT NULL DEFAULT 0,
      translation_updated_at TEXT,
      lang_code TEXT,
      alternatives TEXT,
      confidence REAL,
      transcription_engine TEXT,
      transcription_provider TEXT,
      transcription_model TEXT,
      transcription_mode TEXT,
      result_stage TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS documents (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      meeting_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      format TEXT NOT NULL,
      file_path TEXT NOT NULL,
      created_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS glossary (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      phrase TEXT NOT NULL,
      display_as TEXT,
      lang TEXT NOT NULL DEFAULT 'en-US',
      meeting_id INTEGER,
      created_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS transcript_segments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      meeting_id INTEGER NOT NULL,
      channel_id TEXT,
      speaker TEXT,
      text TEXT NOT NULL,
      translation TEXT,
      translation_target TEXT,
      translation_provider TEXT,
      translation_source_hash TEXT,
      translation_source_version INTEGER NOT NULL DEFAULT 1,
      translation_status TEXT NOT NULL DEFAULT 'idle',
      translation_error TEXT,
      translation_attempts INTEGER NOT NULL DEFAULT 0,
      translation_updated_at TEXT,
      lang_code TEXT,
      corrections TEXT,
      source_ids TEXT NOT NULL,
      order_index REAL NOT NULL,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS segment_sources (
      segment_id INTEGER NOT NULL,
      transcript_id INTEGER NOT NULL,
      PRIMARY KEY (segment_id, transcript_id),
      FOREIGN KEY (segment_id) REFERENCES transcript_segments(id) ON DELETE CASCADE,
      FOREIGN KEY (transcript_id) REFERENCES transcripts(id) ON DELETE CASCADE
    );
    """

    static let indexes = """
    CREATE INDEX IF NOT EXISTS idx_segments_meeting_channel ON transcript_segments(meeting_id, channel_id, order_index);
    CREATE INDEX IF NOT EXISTS idx_segment_sources_transcript ON segment_sources(transcript_id);
    CREATE INDEX IF NOT EXISTS idx_transcripts_mc ON transcripts(meeting_id, channel_id, id);
    CREATE INDEX IF NOT EXISTS idx_transcripts_mr ON transcripts(meeting_id, result_id);
    CREATE INDEX IF NOT EXISTS idx_documents_meeting ON documents(meeting_id, created_at, id);
    CREATE INDEX IF NOT EXISTS idx_glossary_meeting ON glossary(meeting_id);
    CREATE INDEX IF NOT EXISTS idx_glossary_lang ON glossary(lang, meeting_id, phrase);
    CREATE INDEX IF NOT EXISTS idx_transcripts_translation_state
      ON transcripts(meeting_id, translation_status, translation_target);
    CREATE INDEX IF NOT EXISTS idx_segments_translation_state
      ON transcript_segments(meeting_id, translation_status, translation_target);
    """
}
