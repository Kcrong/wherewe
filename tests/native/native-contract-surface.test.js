"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const contract = JSON.parse(read("macos/contract.json"));
const protocol = read("macos/Sources/MeetingTranscriberCore/NativeServiceProtocol.swift");
const realtimeContract = read("macos/Sources/MeetingTranscriberCore/RealtimeContracts.swift");
const packageSource = read("macos/Package.swift");
const coreDirectory = path.join(ROOT, "macos/Sources/MeetingTranscriberCore");
const appDirectory = path.join(ROOT, "macos/Sources/MeetingTranscriberApp");

function swiftFiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true })
    .flatMap((entry) => {
      const fullPath = path.join(directory, entry.name);
      if (entry.isDirectory()) return swiftFiles(fullPath);
      return entry.isFile() && entry.name.endsWith(".swift") ? [fullPath] : [];
    })
    .sort();
}

function swiftSources(directory) {
  return swiftFiles(directory).map((file) => fs.readFileSync(file, "utf8")).join("\n");
}

function imports(directory) {
  const values = new Set();
  for (const file of swiftFiles(directory)) {
    const source = fs.readFileSync(file, "utf8");
    for (const match of source.matchAll(/^import\s+([A-Za-z0-9_]+)/gm)) values.add(match[1]);
  }
  return [...values].sort();
}

function body(source, start, end) {
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex + start.length);
  assert.ok(startIndex >= 0, `missing ${start}`);
  assert.ok(endIndex > startIndex, `missing ${end}`);
  return source.slice(startIndex, endIndex);
}

const coreSource = swiftSources(coreDirectory);
const appSource = swiftSources(appDirectory);

test("machine-readable service methods exactly match the Swift protocol", () => {
  assert.equal(contract.transport, "in-process");
  assert.equal(contract.minimumMacOS, "26.0");
  const serviceProtocol = body(protocol, "public protocol NativeServiceServing", "public extension NativeServiceServing");
  const swiftMethods = [...serviceProtocol.matchAll(/\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\b/g)]
    .map((match) => match[1])
    .sort();
  assert.deepEqual([...contract.serviceMethods].sort(), swiftMethods);
});

test("realtime methods and events have exact bidirectional parity", () => {
  const serving = realtimeContract.slice(realtimeContract.indexOf("public protocol RealtimeServing"));
  const swiftMethods = [...serving.matchAll(/\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\b/g)]
    .map((match) => match[1])
    .sort();
  assert.deepEqual([...contract.realtimeClientMethods].sort(), swiftMethods);

  const eventBody = body(realtimeContract, "public enum RealtimeEventName", "public struct RealtimeMessage");
  const swiftEvents = [...eventBody.matchAll(/^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)/gm)]
    .map((match) => match[1])
    .sort();
  assert.deepEqual([...contract.serverEvents].sort(), swiftEvents);
});

test("production imports only approved Apple platform and local modules", () => {
  assert.deepEqual(imports(coreDirectory), [
    "AVFoundation",
    "AppKit",
    "AudioToolbox",
    "CoreAudio",
    "CoreMedia",
    "CryptoKit",
    "Darwin",
    "Foundation",
    "SQLite3",
    "Speech",
    "Translation",
  ]);
  assert.deepEqual(imports(appDirectory), [
    "AVFoundation",
    "AppKit",
    "Foundation",
    "MeetingTranscriberCore",
    "PDFKit",
    "SwiftUI",
    "UniformTypeIdentifiers",
  ]);
  assert.match(coreSource, /SpeechAnalyzer/);
  assert.match(coreSource, /TranslationSession/);
});

test("production has no custom network downloader or child-process launch API", () => {
  const production = `${coreSource}\n${appSource}`;
  const forbiddenCalls = [
    /URLSession|NSURLConnection|CFReadStream|CFWriteStream|CFSocket|NWListener|NWConnection|(?:Foundation\.)?Process(?:\.init)?\s*\(|NSTask/,
    /(?:(?<!\.)\b(?:posix_spawnp?|fork|exec[lvpe]*|system|popen|socket)|\b(?:Darwin|Glibc)\.(?:posix_spawnp?|fork|exec[lvpe]*|system|popen|socket))\s*\(/,
    /URL\(string:\s*["'](?:https?|wss?):/,
  ];
  for (const pattern of forbiddenCalls) assert.doesNotMatch(production, pattern);
  for (const sample of [
    "Foundation.Process.init()",
    "Darwin.socket(AF_INET, SOCK_STREAM, 0)",
    "posix_spawn(nil, path, nil, nil, argv, env)",
  ]) {
    assert.ok(forbiddenCalls.some((pattern) => pattern.test(sample)), `undetected forbidden call: ${sample}`);
  }
  assert.doesNotMatch(production, /^import\s+(?:CFNetwork|Network|WebKit)$/m);
  const speech = read("macos/Sources/MeetingTranscriberCore/NativeAppleSpeech.swift");
  assert.match(speech, /AssetInventory\.assetInstallationRequest\(supporting: \[transcriber\]\)/);
  assert.match(speech, /downloadAndInstall\(\)/);
  assert.equal((production.match(/assetInstallationRequest/g) || []).length, 1);
  assert.equal((production.match(/downloadAndInstall/g) || []).length, 1);
});

test("Swift package has no external dependency or binary target", () => {
  assert.match(packageSource, /dependencies:\s*\[\]/);
  assert.doesNotMatch(packageSource, /\.binaryTarget\s*\(/);
  assert.doesNotMatch(packageSource, /https?:\/\//);
  assert.match(packageSource, /\.target\(\s*name: "MeetingTranscriberCore"\s*\)/s);
});

test("legacy migration preserves transcript provenance", () => {
  const database = read("macos/Sources/MeetingTranscriberCore/NativeSQLite.swift");
  const migration = body(database, "private func migrate()", "private func ensureColumn");
  assert.match(migration, /UPDATE meetings SET mode = 'meeting'/);
  assert.doesNotMatch(migration, /SET transcription_engine|SET transcription_provider|SET transcription_model/);
  assert.doesNotMatch(migration, /SET result_stage|SET refinement_source|SET translation_provider/);
});

test("bundle scripts enforce the native bundle allowlist", () => {
  const build = read("scripts/build-macos-app.sh");
  const appSmoke = read("scripts/test-macos-app-bundle.sh");
  const dmgSmoke = read("scripts/test-macos-dmg.sh");
  const entitlement = read("macos/Resources/MeetingTranscriber.entitlements");
  assert.match(build, /mkdir -p "\$CONTENTS\/MacOS" "\$CONTENTS\/Resources"/);
  assert.match(build, /ditto "\$BIN_DIR\/Wherewe" "\$CONTENTS\/MacOS\/Wherewe"/);
  assert.match(build, /ditto "\$PACKAGE_DIR\/Resources\/Info\.plist" "\$CONTENTS\/Info\.plist"/);
  for (const source of [build, appSmoke, dmgSmoke]) {
    assert.match(source, /for forbidden_directory in Frameworks Agents Models/);
    assert.match(source, /\.framework/);
    assert.match(source, /\.mlmodel/);
  }
  assert.doesNotMatch(build, /install_name_tool|PlistBuddy/);
  const entitlementKeys = [...entitlement.matchAll(/<key>([^<]+)<\/key>/g)].map((match) => match[1]);
  assert.deepEqual(entitlementKeys, ["com.apple.security.device.audio-input"]);
});
