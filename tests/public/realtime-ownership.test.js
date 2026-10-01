"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");

const recording = read("macos/Sources/MeetingTranscriberCore/NativeServiceRecording.swift");
const realtime = read("macos/Sources/MeetingTranscriberCore/NativeRealtimeClient.swift");

function between(source, start, end) {
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex + start.length);
  assert.ok(startIndex >= 0, `missing block start: ${start}`);
  assert.ok(endIndex > startIndex, `missing block end: ${end}`);
  return source.slice(startIndex, endIndex);
}

test("recording ownership is revalidated after every persistence suspension", () => {
  const commit = between(recording, "func commitRealtimeChunk(", "func finishRealtimeTranscription(");
  const finish = between(recording, "func finishRealtimeTranscription(", "private func transcribe(");
  const persist = between(recording, "private func persistTranscription(", "private func deinterleaved(");

  assert.match(recording, /func requireCurrentRecordingClaim\(/);
  assert.match(commit, /await transcribe\([\s\S]*requireCurrentRecordingClaim\(/);
  assert.match(persist, /await translateText\([\s\S]*requireCurrentRecordingClaim\([\s\S]*INSERT INTO transcripts/);
  assert.match(finish, /commitRealtimeChunk\([\s\S]*requireCurrentRecordingClaim\(/);
  assert.match(finish, /clearRecordingClaimIfCurrent\(/);
  assert.doesNotMatch(finish, /recordingClaim = nil/);
});

test("realtime preview work is owned and cancelled by a unique audio session", () => {
  assert.match(realtime, /private struct AudioSession[\s\S]*let id = UUID\(\)/);
  assert.match(realtime, /private struct PreviewWork[\s\S]*let sessionID: UUID/);
  assert.match(realtime, /private var previewTasks: \[UUID: Task<Void, Never>\]/);
  assert.match(realtime, /func cancelPreviewTasks\(/);
  assert.match(realtime, /disconnect\(\)[\s\S]*cancelPreviewTasks/);
  assert.match(realtime, /startTranscription[\s\S]*cancelPreviewTasks/);
  assert.match(realtime, /current\.id == work\.sessionID/);
});

test("recording finalization retries preserve one claim and commit exactly once", () => {
  const observer = read("macos/Sources/MeetingTranscriberCore/NativeRecordingLifecycleObserver.swift");
  const coordinator = read("macos/Sources/MeetingTranscriberCore/RecordingCoordinator.swift");
  const regressionsPath = path.join(
    ROOT,
    "macos/Tests/MeetingTranscriberCoreTests/RecordingFinalizationRecoveryTests.swift"
  );
  assert.ok(fs.existsSync(regressionsPath), "missing finalization recovery regressions");
  const regressions = fs.readFileSync(regressionsPath, "utf8");

  assert.match(observer, /beforeFinalizeRecording/);
  assert.match(
    recording,
    /recordingLifecycleObserver\.beforeFinalizeRecording\(request\)[\s\S]*UPDATE meetings SET ended_at[\s\S]*recordingClaim = nil/
  );
  assert.match(
    coordinator,
    /func retryFinalization\(\)[\s\S]*guard await finalizeClaim\(claim\) else[\s\S]*state = \.idle/
  );
  assert.match(regressions, /finalization retry fail fail succeed preserves one recovery claim and one commit/);
  assert.match(regressions, /remainingFailures: 4/);
  assert.match(regressions, /retryFinalization\(\)/);
  assert.match(regressions, /attemptCount\(\) == 5/);
  assert.match(regressions, /successfulAttemptCount\(\) == 1/);
  assert.match(regressions, /RecordingCoordinatorError\.invalidState/);
  assert.match(regressions, /selectionLocked/);
});
