"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const packageManifest = read("macos/Package.swift");
const infoPlist = read("macos/Resources/Info.plist");
const appBuild = read("scripts/build-macos-app.sh");
const appTest = read("scripts/test-macos-app-bundle.sh");
const dmgBuild = read("scripts/build-macos-dmg.sh");
const dmgTest = read("scripts/test-macos-dmg.sh");
const localGate = read("scripts/pre-push-macos.sh");
const releaseWorkflow = read(".github/workflows/release-macos.yml");
const testWorkflow = read(".github/workflows/test.yml");
const runtimeConfiguration = read("macos/Sources/MeetingTranscriberCore/NativeServiceConfiguration.swift");
const gitignore = read(".gitignore");
const readme = read("README.md");

function plistString(key) {
  const match = infoPlist.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`));
  assert.ok(match, `missing plist string: ${key}`);
  return match[1];
}

function candidateFiles() {
  return execFileSync(
    "git",
    ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    { cwd: ROOT }
  ).toString("utf8").split("\0").filter(Boolean);
}

test("Swift executable and app bundle use permanent Wherewe identity", () => {
  assert.match(packageManifest, /let package = Package\(\s*name: "Wherewe"/);
  assert.match(packageManifest, /\.executable\(\s*name: "Wherewe",\s*targets: \["MeetingTranscriberApp"\]/);
  assert.equal(plistString("CFBundleDisplayName"), "Wherewe");
  assert.equal(plistString("CFBundleExecutable"), "Wherewe");
  assert.equal(plistString("CFBundleIdentifier"), "com.kcrong.wherewe");
  assert.equal(plistString("CFBundleName"), "Wherewe");
  assert.match(plistString("NSMicrophoneUsageDescription"), /^Wherewe uses /);
  assert.match(appBuild, /APP_PATH="\$DIST_DIR\/Wherewe\.app"/);
  assert.match(appBuild, /--product Wherewe/);
  assert.match(appTest, /Contents\/MacOS\/Wherewe/);
});

test("DMG and release workflow publish Wherewe from the Wherewe repository", () => {
  assert.match(dmgBuild, /VOLUME_NAME="Wherewe"/);
  assert.match(dmgBuild, /DMG_NAME="Wherewe-\$\{VERSION\}-arm64\.dmg"/);
  assert.match(dmgTest, /Wherewe-\*-arm64\.dmg/);
  assert.match(dmgTest, /MOUNT_POINT\/Wherewe\.app/);
  assert.match(localGate, /Wherewe-\*-arm64\.dmg/);
  assert.match(releaseWorkflow, /github\.repository == 'Kcrong\/wherewe'/);
  assert.match(releaseWorkflow, /MACOS_BUNDLE_IDENTIFIER: com\.kcrong\.wherewe/);
  assert.match(releaseWorkflow, /Wherewe-\$RELEASE_VERSION-arm64\.dmg/);
  assert.match(releaseWorkflow, /--title "Wherewe \$RELEASE_VERSION"/);
  assert.match(testWorkflow, /WHEREWE_NATIVE_APP_PATH=\$RUNNER_TEMP\/native-full-dist\/Wherewe\.app/);
});

test("runtime defaults use Wherewe and keep legacy namespace normalization isolated", () => {
  assert.match(runtimeConfiguration, /appendingPathComponent\("Wherewe", isDirectory: true\)/);
  assert.match(runtimeConfiguration, /\["WHEREWE_DEFAULT_DATA_ROOT"\]/);
  assert.match(runtimeConfiguration, /\["WHEREWE_CONFIG_PATH"\]/);
  assert.match(runtimeConfiguration, /\.wherewe-config\.json/);
  assert.match(runtimeConfiguration, /TRANSCRIBER_/);
  assert.match(gitignore, /^\.wherewe-config\.json$/m);
  assert.match(gitignore, /^\.transcriber-config\.json$/m);
});

test("concrete legacy environment keys stay confined to compatibility tests", () => {
  const allowed = new Set([
    "macos/Tests/MeetingTranscriberCoreTests/NativeServiceConfigurationTests.swift",
  ]);
  const violations = [];
  for (const relative of candidateFiles()) {
    const source = fs.readFileSync(path.join(ROOT, relative), "utf8");
    if (/TRANSCRIBER_[A-Z0-9_]+/.test(source) && !allowed.has(relative)) violations.push(relative);
  }
  assert.deepEqual(violations, []);
});

test("distribution surfaces use the current product identity", () => {
  const surfaces = [
    infoPlist,
    appBuild,
    appTest,
    dmgBuild,
    dmgTest,
    localGate,
    releaseWorkflow,
    testWorkflow,
    readme,
  ].join("\n");
  assert.match(surfaces, /Wherewe/);
  assert.match(infoPlist, /<string>Wherewe<\/string>/);
  assert.match(readme, /^# Wherewe$/m);
  assert.match(releaseWorkflow, /Kcrong\/wherewe/);
});
