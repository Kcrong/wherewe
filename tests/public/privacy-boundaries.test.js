"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const readme = read("README.md");
const coreDirectory = path.join(ROOT, "macos/Sources/MeetingTranscriberCore");
const appDirectory = path.join(ROOT, "macos/Sources/MeetingTranscriberApp");
const documents = read("macos/Sources/MeetingTranscriberCore/NativeServiceDocuments.swift");
const meetings = read("macos/Sources/MeetingTranscriberCore/NativeServiceMeetings.swift");
const exportService = read("macos/Sources/MeetingTranscriberCore/NativeServiceExport.swift");
const realtime = read("macos/Sources/MeetingTranscriberCore/NativeRealtimeClient.swift");
const spool = read("macos/Sources/MeetingTranscriberCore/NativeSpoolWorkspace.swift");
const speech = read("macos/Sources/MeetingTranscriberCore/NativeAppleSpeech.swift");
const translation = read("macos/Sources/MeetingTranscriberCore/NativeAppleTranslation.swift");
const build = read("scripts/build-macos-app.sh");
const appSmoke = read("scripts/test-macos-app-bundle.sh");
const entitlement = read("macos/Resources/MeetingTranscriber.entitlements");

function swiftSources(directory) {
  return fs.readdirSync(directory)
    .filter((name) => name.endsWith(".swift"))
    .sort()
    .map((name) => fs.readFileSync(path.join(directory, name), "utf8"))
    .join("\n");
}

test("production performs language processing through Apple system frameworks", () => {
  assert.match(speech, /import Speech/);
  assert.match(speech, /SpeechAnalyzer/);
  assert.match(speech, /AssetInventory/);
  assert.match(translation, /import Translation/);
  assert.match(translation, /TranslationSession/);
  assert.match(readme, /Wherewe itself sends no meeting content over a network/);
  assert.match(readme, /macOS may contact Apple\s+services/);
});

test("production has no downloader or child executable path", () => {
  const production = `${swiftSources(coreDirectory)}\n${swiftSources(appDirectory)}`;
  assert.doesNotMatch(production, /URLSession|Process\s*\(|NSTask|NWListener|NWConnection/);
  assert.match(readme, /no\s+listening port, network downloader, helper executable, or child process/);
  assert.match(appSmoke, /unexpectedly spawned child processes/);
});

test("README distinguishes local database attachments spools exports and deletion", () => {
  assert.match(documents, /Files must be 5 MB or smaller/);
  assert.match(documents, /\["pdf", "md", "txt", "html", "csv"\]/);
  assert.match(documents, /NativeDocumentPathPolicy/);
  assert.match(meetings, /safeFiles[\s\S]*NativeDocumentPathPolicy/);
  assert.match(exportService, /fileManager\.temporaryDirectory/);
  assert.match(exportService, /NativeStoragePathPolicy\.securePrivateFile/);
  assert.match(realtime, /NativeSpoolWorkspace/);
  assert.match(spool, /sweepStaleWorkspaces/);
  assert.match(spool, /0o600/);

  for (const disclosure of [
    /SQLite stores meetings, transcripts, edited segments, translation state,/,
    /Attachment bodies remain separate\s+files/,
    /5 MB/,
    /Cancelling an export removes its partial directory/,
    /Deleting a\s+meeting removes its database rows/,
    /Raw PCM is temporary and process-owned/,
  ]) {
    assert.match(readme, disclosure);
  }
});

test("bundle keeps library validation and rejects non-system payloads", () => {
  assert.doesNotMatch(build, /install_name_tool|PlistBuddy/);
  const entitlementKeys = [...entitlement.matchAll(/<key>([^<]+)<\/key>/g)].map((match) => match[1]);
  assert.deepEqual(entitlementKeys, ["com.apple.security.device.audio-input"]);
  assert.match(build, /for forbidden_directory in Frameworks Agents Models/);
  assert.match(build, /\.framework/);
  assert.match(build, /\.mlmodel/);
  assert.match(appSmoke, /for forbidden_directory in Frameworks Agents Models Sidecar Helpers/);
});
