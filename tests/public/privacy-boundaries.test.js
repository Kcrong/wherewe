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
const speechSettings = read("macos/Sources/MeetingTranscriberCore/NativeServiceSettings.swift");
const appView = read("macos/Sources/MeetingTranscriberApp/MeetingTranscriberApp.swift");
const appModel = read("macos/Sources/MeetingTranscriberApp/AppModel.swift");
const translation = read("macos/Sources/MeetingTranscriberCore/NativeAppleTranslation.swift");
const build = read("scripts/build-macos-app.sh");
const appSmoke = read("scripts/test-macos-app-bundle.sh");
const entitlement = read("macos/Resources/MeetingTranscriber.entitlements");

function sourceBetween(source, start, end) {
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex + start.length);
  assert.ok(startIndex >= 0, `missing block start: ${start}`);
  assert.ok(endIndex > startIndex, `missing block end: ${end}`);
  return source.slice(startIndex, endIndex);
}

function swiftSources(directory) {
  return fs.readdirSync(directory, { withFileTypes: true })
    .flatMap((entry) => {
      const fullPath = path.join(directory, entry.name);
      if (entry.isDirectory()) return [swiftSources(fullPath)];
      return entry.isFile() && entry.name.endsWith(".swift")
        ? [fs.readFileSync(fullPath, "utf8")]
        : [];
    })
    .join("\n");
}

test("production performs language processing and asset installation through Apple system frameworks", () => {
  const speechPanel = appView.slice(
    appView.indexOf("private struct SpeechSettingsView"),
    appView.indexOf("private struct TranslationSettingsView")
  );
  const loadSelectedMeeting = sourceBetween(
    appModel,
    "func loadSelectedMeeting()",
    "func startRecordingWithoutMeeting()"
  );

  assert.match(speech, /import Speech/);
  assert.match(speech, /SpeechAnalyzer/);
  assert.match(speech, /AssetInventory\.assetInstallationRequest\(supporting: \[transcriber\]\)/);
  assert.match(speech, /downloadAndInstall\(\)/);
  assert.match(speechSettings, /await speechService\.readiness\(language: language\)/);
  assert.match(speechPanel, /Button\("Install Selected Speech Assets"\)/);
  assert.match(speechPanel, /speechPreparationInProgress/);
  assert.match(speechPanel, /cancelAppleSpeechPreparation/);
  assert.match(appModel, /transcriptionCatalogueLanguage == recognitionLanguage/);
  assert.match(appModel, /transcriptionCatalogue = nil\s+transcriptionCatalogueLanguage = nil/);
  assert.match(appModel, /func applyTranscriptionCatalogue\(/);
  assert.equal((appModel.match(/transcriptionCatalogue = catalogue/g) || []).length, 1);
  assert.match(appModel, /speechPreparationTask\?\.cancel\(\)/);
  assert.match(loadSelectedMeeting, /await refreshTranscriptionReadiness\(for: recognitionLanguage\)\s+guard generation == meetingLoadGeneration, selectedMeetingID == meetingID else \{ return \}\s+_ = await transcriptStore\.activate\(detail\)/);
  assert.doesNotMatch(speechPanel, /Open Language & Region|openAppleTranslationSettings/);
  assert.match(translation, /import Translation/);
  assert.match(translation, /TranslationSession/);
});

test("production has no custom downloader or child executable path", () => {
  const production = `${swiftSources(coreDirectory)}\n${swiftSources(appDirectory)}`;
  for (const pattern of [
    /URLSession|NSURLConnection|CFReadStream|CFWriteStream|CFSocket|NWListener|NWConnection|(?:Foundation\.)?Process(?:\.init)?\s*\(|NSTask/,
    /(?:(?<!\.)\b(?:posix_spawnp?|fork|exec[lvpe]*|system|popen|socket)|\b(?:Darwin|Glibc)\.(?:posix_spawnp?|fork|exec[lvpe]*|system|popen|socket))\s*\(/,
    /URL\(string:\s*["'](?:https?|wss?):/,
  ]) {
    assert.doesNotMatch(production, pattern);
  }
  assert.match(appSmoke, /unexpectedly spawned child processes/);
});

test("local data controls remain enforced and disclosed concisely", () => {
  assert.match(documents, /Files must be 5 MB or smaller/);
  assert.match(documents, /\["pdf", "md", "txt", "html", "csv"\]/);
  assert.match(documents, /NativeDocumentPathPolicy/);
  assert.match(meetings, /safeFiles[\s\S]*NativeDocumentPathPolicy/);
  assert.match(exportService, /fileManager\.temporaryDirectory/);
  assert.match(exportService, /NativeStoragePathPolicy\.securePrivateFile/);
  assert.match(realtime, /NativeSpoolWorkspace/);
  assert.match(spool, /sweepStaleWorkspaces/);
  assert.match(spool, /0o600/);
  assert.match(readme, /## Privacy/);
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
