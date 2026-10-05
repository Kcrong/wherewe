"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");

const recording = read("macos/Sources/MeetingTranscriberCore/NativeServiceRecording.swift");
const service = read("macos/Sources/MeetingTranscriberCore/NativeService.swift");
const settings = read("macos/Sources/MeetingTranscriberCore/NativeServiceSettings.swift");
const realtime = read("macos/Sources/MeetingTranscriberCore/NativeRealtimeClient.swift");

function between(source, start, end) {
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex + start.length);
  assert.ok(startIndex >= 0, `missing block start: ${start}`);
  assert.ok(endIndex > startIndex, `missing block end: ${end}`);
  return source.slice(startIndex, endIndex);
}

test("recording ownership is revalidated after every persistence suspension", () => {
  const start = between(recording, "public func startRecording(", "public func finalizeRecording(");
  const commit = between(recording, "func commitRealtimeChunk(", "func finishRealtimeTranscription(");
  const finish = between(recording, "func finishRealtimeTranscription(", "private func transcribe(");
  const persist = between(recording, "private func persistTranscription(", "private func deinterleaved(");

  assert.match(start, /speechPreparation\(language: request\.language\)[\s\S]*APPLE_SPEECH_NOT_READY/);
  assert.match(start, /Task\.checkCancellation\(\)[\s\S]*if let claim = recordingClaim/);
  assert.match(start, /let initialDatabase = try requireDatabase\(\)[\s\S]*speechAssetPreparationLanguage == nil[\s\S]*recordingStartLanguages\[startToken\] = request\.language[\s\S]*defer \{ recordingStartLanguages\.removeValue/);
  assert.match(start, /speechPreparation\(language: request\.language\)[\s\S]*guard databaseStorage === initialDatabase[\s\S]*RECORDING_CONTEXT_CHANGED/);
  assert.match(start, /let update = try initialDatabase\.run[\s\S]*guard update\.changes == 1[\s\S]*recordingGeneration = nextGeneration[\s\S]*recordingClaim = claim/);
  assert.match(service, /var speechAssetPreparationLanguage: String\?[\s\S]*var recordingStartLanguages: \[UUID: String\]/);
  assert.match(settings, /importSettings\([\s\S]*recordingClaim == nil, recordingStartLanguages\.isEmpty[\s\S]*settingsStore\.prepareImport/);
  assert.match(settings, /updateSettings\([\s\S]*guard recordingStartLanguages\.isEmpty[\s\S]*settingsStore\.prepareUpdate/);
  assert.match(settings, /private func activateSettings\([\s\S]*let candidate = try NativeDatabase\([\s\S]*settingsStore\.commit\(prepared\)[\s\S]*databaseStorage = candidate/);
  assert.match(settings, /recordingClaim == nil[\s\S]*recordingStartLanguages\.isEmpty[\s\S]*speechAssetPreparationLanguage == nil[\s\S]*speechAssetPreparationLanguage = language[\s\S]*defer \{ speechAssetPreparationLanguage = nil \}[\s\S]*speechService\.prepare/);
  assert.match(recording, /func requireCurrentRecordingClaim\([\s\S]*claim\.language == request\.language[\s\S]*claim\.translationTarget == canonicalLanguage\(request\.translationTarget\)/);
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

  const realtimeStop = between(
    realtime,
    "public func stopTranscription(",
    "private func makeAudioSession("
  );
  const coordinatorStop = between(
    coordinator,
    "public func stop()",
    "public func retryFinalization()"
  );
  const finalizeClaim = between(
    coordinator,
    "private func finalizeClaim(",
    "private func finalizeClaimViaService("
  );
  assert.match(realtimeStop, /recordingOwnedByRequester \|\| !status\.recordingOwnerConnected[\s\S]*AUDIO_SESSION_UNAVAILABLE[\s\S]*RECORDING_OWNED_BY_ANOTHER_CLIENT/);
  assert.doesNotMatch(realtimeStop, /defer \{ try\? FileManager\.default\.removeItem/);
  assert.match(realtimeStop, /finishRealtimeTranscription\([\s\S]*audioSession\?\.id == session\.id[\s\S]*audioSession = nil[\s\S]*removeItem/);
  assert.doesNotMatch(coordinatorStop, /let socketStop = try\? await realtime\.stopTranscription/);
  assert.match(coordinatorStop, /catch[\s\S]*state = \.recoveryRequired\(claim\)[\s\S]*throw/);
  assert.match(coordinatorStop, /socketStop\.code == "AUDIO_SESSION_UNAVAILABLE"[\s\S]*expectedAudioByteCount == 0[\s\S]*finalizeClaimViaService/);
  assert.doesNotMatch(finalizeClaim, /try\? await realtime\.stopTranscription/);
  assert.match(finalizeClaim, /guard allowsServiceFallback,[\s\S]*acknowledgement\.code == "AUDIO_SESSION_UNAVAILABLE" else \{ return false \}/);
  assert.match(coordinator, /let allowsServiceFallback = !tracksAudioDelivery \|\| expectedAudioByteCount == 0/);
  assert.doesNotMatch(coordinator, /catch let error as NativeServiceError[\s\S]{0,240}RECORDING_CLAIM_STALE/);
  assert.match(coordinator, /case retryingFinalization\(RecordingClaim\)/);
  assert.match(coordinator, /func retryFinalization\(\)[\s\S]*state = \.retryingFinalization\(claim\)[\s\S]*state = \.recoveryRequired\(claim\)[\s\S]*state = \.idle/);
  assert.match(recording, /WHERE NOT EXISTS \([\s\S]*meeting_id = \? AND result_id = \?[\s\S]*SELECT id FROM transcripts WHERE meeting_id = \? AND result_id = \?[\s\S]*databaseID: databaseID/);
  assert.match(regressions, /verifyOwnedAudioRetry\(\)/);
  assert.match(regressions, /verifyPartialPersistenceRetry\(\)/);
  assert.match(regressions, /verifyConnectedOwnerIsNotFinalized\(\)/);
  assert.match(regressions, /tracked PCM cannot bypass its spool through service finalization/);
  assert.match(regressions, /recordingOwnedByRequester/);
  assert.match(regressions, /payloads\[0\] == payloads\[2\]/);
  assert.match(regressions, /Recovered final transcript/);

  assert.match(observer, /beforeFinalizeRecording/);
  assert.match(
    recording,
    /recordingLifecycleObserver\.beforeFinalizeRecording\(request\)[\s\S]*UPDATE meetings SET ended_at[\s\S]*recordingClaim = nil/
  );
  assert.match(
    coordinator,
    /func retryFinalization\(\)[\s\S]*guard await finalizeClaim\(claim, allowsServiceFallback: allowsServiceFallback\) else[\s\S]*state = \.idle/
  );
  assert.match(regressions, /finalization retry fail fail succeed preserves one recovery claim and one commit/);
  assert.match(regressions, /remainingFailures: 4/);
  assert.match(regressions, /retryFinalization\(\)/);
  assert.match(regressions, /attemptCount\(\) == 5/);
  assert.match(regressions, /successfulAttemptCount\(\) == 1/);
  assert.match(regressions, /RecordingCoordinatorError\.invalidState/);
  assert.match(regressions, /selectionLocked/);
});
