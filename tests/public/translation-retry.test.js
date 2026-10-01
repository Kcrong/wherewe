"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const translation = read("macos/Sources/MeetingTranscriberCore/NativeServiceTranslation.swift");
const mutations = read("macos/Sources/MeetingTranscriberCore/NativeServiceTranscriptMutations.swift");
const database = read("macos/Sources/MeetingTranscriberCore/NativeSQLite.swift");

test("explicit Apple Translation retries persist attempts and recover interrupted work", () => {
  const regressionsPath = path.join(
    ROOT,
    "macos/Tests/MeetingTranscriberCoreTests/TranslationRetryRecoveryTests.swift"
  );
  assert.ok(fs.existsSync(regressionsPath), "missing translation retry recovery regressions");
  const regressions = fs.readFileSync(regressionsPath, "utf8");

  assert.match(translation, /provider: "apple"/);
  assert.match(translation, /translation_attempts = translation_attempts \+ 1/);
  assert.match(mutations, /func retryTranslation\(/);
  assert.match(database, /UPDATE transcripts SET translation_status = 'idle', translation_error = NULL WHERE translation_status = 'pending'/);
  assert.match(regressions, /repeated translation failures and pending restart recover without duplicate rows/);
  assert.match(regressions, /for _ in 0\.\.<3/);
  assert.match(regressions, /markTranslationPendingForRestart/);
  assert.match(regressions, /translationAttempts == 3/);
  assert.match(regressions, /translationStatus == \.idle/);
  assert.match(regressions, /translationAttempts == 4/);
  assert.match(regressions, /translationStatus == \.succeeded/);
  assert.match(regressions, /transcripts\.count == 1/);
});
