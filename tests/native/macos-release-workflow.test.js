"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const release = read(".github/workflows/release-macos.yml");
const ci = read(".github/workflows/test.yml");
const appBuild = read("scripts/build-macos-app.sh");
const appSmoke = read("scripts/test-macos-app-bundle.sh");
const dmgBuild = read("scripts/build-macos-dmg.sh");
const dmgSmoke = read("scripts/test-macos-dmg.sh");
const localGate = read("scripts/pre-push-macos.sh");
const releaseGate = read("scripts/test-release-prerequisites.sh");

function actionReferences(source) {
  return [...source.matchAll(/^\s*-?\s*uses:\s*(\S+)/gm)].map((match) => match[1]);
}

function namedStep(source, name) {
  const marker = `      - name: ${name}\n`;
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, `missing workflow step: ${name}`);
  const next = source.indexOf("\n      - ", start + marker.length);
  return source.slice(start, next === -1 ? source.length : next);
}

test("automatic CI runs Linux static then macOS build unit and core checks", () => {
  assert.match(ci, /push:\s*\n\s+branches: \[main\]/);
  assert.match(ci, /^\s{2}pull_request:\s*$/m);
  assert.match(ci, /^\s{2}workflow_dispatch:\s*$/m);
  assert.match(ci, /static:[\s\S]*runs-on: ubuntu-24\.04/);
  assert.match(ci, /macos:[\s\S]*needs: static[\s\S]*runs-on: macos-26/);
  assert.match(namedStep(ci, "Build Swift package"), /xcrun swift build/);
  assert.match(namedStep(ci, "Run Swift unit tests"), /xcrun swift test/);
  assert.match(namedStep(ci, "Run native service contract checks"), /MeetingTranscriberCoreChecks/);
  assert.match(namedStep(ci, "Probe available Apple runtime assets"), /if: \$\{\{ github\.event_name == 'workflow_dispatch' \}\}/);
  assert.match(ci, /node scripts\/scan-public-content\.js/);
  assert.match(ci, /node --test tests\/native\/\*\.test\.js tests\/public\/\*\.test\.js/);
});

test("manual CI publishes a mount-verified test DMG without requiring host assets", () => {
  for (const source of [localGate, releaseGate]) {
    assert.match(source, /WHEREWE_NATIVE_REAL_APPLE_SPEECH/);
    assert.match(source, /WHEREWE_NATIVE_REAL_APPLE_TRANSLATION/);
    assert.match(source, /apple-speech-accurate/);
    assert.match(source, /apple-speech-commit-boundary/);
    assert.match(source, /apple-translation/);
    assert.match(source, /NativeRuntimeIntegrationTests/);
  }

  const buildStep = namedStep(ci, "Build native app");
  const smokeStep = namedStep(ci, "Smoke-test clean launch and relaunch");
  const dmgStep = namedStep(ci, "Build and mount-verify DMG");
  const uploadStep = namedStep(ci, "Upload downloadable test DMG");
  const summaryStep = namedStep(ci, "Publish test DMG download details");
  const probeStep = namedStep(ci, "Probe available Apple runtime assets");
  const orderedNames = [
    "Build native app",
    "Smoke-test clean launch and relaunch",
    "Build and mount-verify DMG",
    "Upload downloadable test DMG",
    "Publish test DMG download details",
    "Probe available Apple runtime assets",
  ];
  const indices = orderedNames.map((name) => ci.indexOf(`name: ${name}`));
  assert.ok(indices.every((value, index) => index === 0 || value > indices[index - 1]));

  for (const step of [buildStep, smokeStep, dmgStep, uploadStep]) {
    assert.match(step, /if: \$\{\{ github\.event_name == 'workflow_dispatch' \}\}/);
  }
  assert.match(ci, /group: native-test-\$\{\{ github\.workflow \}\}-\$\{\{ github\.event_name \}\}-\$\{\{ github\.ref \}\}/);
  assert.match(ci, /cancel-in-progress: \$\{\{ github\.event_name != 'workflow_dispatch' \}\}/);

  assert.match(dmgStep, /bash scripts\/test-macos-dmg\.sh/);
  assert.match(dmgStep, /dmg_candidates=/);
  assert.match(dmgStep, /\$\{#dmg_candidates\[@\]\}.*-eq 1/);
  assert.match(dmgStep, /GITHUB_RUN_ID/);
  assert.match(dmgStep, /GITHUB_RUN_ATTEMPT/);

  assert.match(uploadStep, /uses: actions\/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7\.0\.1/);
  assert.match(uploadStep, /path: \$\{\{ env\.WHEREWE_DMG_OUTPUT_DIR \}\}\/Wherewe-\*-arm64-run-\$\{\{ github\.run_id \}\}-attempt-\$\{\{ github\.run_attempt \}\}\.dmg/);
  assert.match(uploadStep, /if-no-files-found: error/);
  assert.match(uploadStep, /retention-days: 7/);
  assert.doesNotMatch(uploadStep, /overwrite:/);
  assert.match(uploadStep, /archive: false/);

  assert.match(summaryStep, /steps\.upload-test-dmg\.outputs\.artifact-url/);
  assert.match(summaryStep, /steps\.upload-test-dmg\.outputs\.artifact-digest/);
  assert.match(summaryStep, /GitHub sign-in is required/);
  assert.match(summaryStep, /unsigned, non-notarized DMG containing an ad-hoc-signed app/);

  assert.match(probeStep, /continue-on-error: true/);
  assert.match(probeStep, /timeout-minutes: 5/);
  assert.match(probeStep, /WHEREWE_NATIVE_REAL_APPLE_SPEECH: 'auto'/);
  assert.match(probeStep, /WHEREWE_NATIVE_REAL_APPLE_TRANSLATION: 'auto'/);
  assert.match(probeStep, /--filter NativeRuntimeIntegrationTests/);
  assert.doesNotMatch(ci, /name: Require real Apple Speech and Translation evidence/);
});

test("local and release gates keep artifacts outside the repository", () => {
  for (const source of [localGate, releaseGate]) {
    assert.match(source, /uname -m\)" == "arm64"/);
    assert.match(source, /MACOS_MAJOR" -ge 26/);
    assert.match(source, /KIROCREW_SCRATCH/);
    assert.match(source, /RUNNER_TEMP/);
    assert.match(source, /TMPDIR/);
    assert.match(source, /scratch root must be outside the repository/);
    assert.match(source, /status --porcelain=v1 -z --untracked-files=all/g);
    assert.match(source, /(?:node|"\$NODE_BIN") --test tests\/native\/\*\.test\.js tests\/public\/\*\.test\.js/);
    assert.match(source, /MeetingTranscriberCoreChecks/);
    assert.match(source, /test-macos-app-bundle\.sh/);
    assert.match(source, /test-macos-dmg\.sh/);
  }
});

test("app and DMG packaging reject non-system payloads", () => {
  assert.match(appBuild, /for forbidden_directory in Frameworks Agents Models/);
  assert.match(appSmoke, /for forbidden_directory in Frameworks Agents Models Sidecar Helpers/);
  assert.match(dmgSmoke, /for forbidden_directory in Frameworks Agents Models Sidecar Helpers/);
  for (const source of [appBuild, appSmoke, dmgSmoke]) {
    assert.match(source, /\.framework/);
    assert.match(source, /\.xcframework/);
    assert.match(source, /\.mlmodel/);
    assert.match(source, /\.bin/);
  }
  assert.doesNotMatch(appBuild, /install_name_tool|PlistBuddy/);
  const entitlement = read("macos/Resources/MeetingTranscriber.entitlements");
  const entitlementKeys = [...entitlement.matchAll(/<key>([^<]+)<\/key>/g)].map((match) => match[1]);
  assert.deepEqual(entitlementKeys, ["com.apple.security.device.audio-input"]);
  assert.match(appBuild, /codesign --verify --deep --strict/);
  assert.match(appSmoke, /unexpectedly spawned child processes/);
});

test("release is tag-bound and publishes a versioned ARM64 DMG", () => {
  assert.match(release, /^\s{4}tags:\s*$/m);
  assert.match(release, /^\s{2}workflow_dispatch:\s*$/m);
  assert.match(release, /\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$/);
  assert.match(release, /TAG_COMMIT/);
  assert.match(release, /current origin\/main commit/);
  assert.match(release, /Wherewe-\$RELEASE_VERSION-arm64\.dmg/);
  assert.match(release, /shasum -a 256/);
  assert.match(release, /gh release (?:create|upload)/);
  assert.match(release, /--verify-tag/);
  assert.match(release, /--generate-notes/);
});

test("signing and notarization credentials are used only after the non-secret gate", () => {
  const gateIndex = release.indexOf("name: Run complete non-secret release gate");
  const firstSecret = release.indexOf("${{ secrets.");
  assert.ok(gateIndex >= 0 && firstSecret > gateIndex);
  for (const name of [
    "MACOS_CERTIFICATE_P12_BASE64",
    "MACOS_CERTIFICATE_PASSWORD",
    "APPLE_ID",
    "APPLE_TEAM_ID",
    "APPLE_APP_SPECIFIC_PASSWORD",
  ]) {
    assert.ok(release.includes(`secrets.${name}`), `missing release secret: ${name}`);
    assert.ok(!releaseGate.includes(name), `non-secret gate references ${name}`);
  }
  assert.match(release, /Developer ID Application:/);
  assert.match(release, /notarytool submit/);
  assert.match(release, /stapler staple/);
  assert.match(release, /stapler validate/);
  assert.match(release, /spctl --assess --type open/);
  assert.match(release, /security delete-keychain/);
});

test("all third-party workflow actions are pinned to full commits", () => {
  const references = [...actionReferences(ci), ...actionReferences(release)];
  assert.ok(references.length >= 3);
  assert.ok(references.every((reference) => /@[0-9a-f]{40}$/.test(reference)));
});

test("DMG builder preserves signed versioned arm64 output", () => {
  assert.match(dmgBuild, /DMG_NAME="Wherewe-\$\{VERSION\}-arm64\.dmg"/);
  assert.match(dmgBuild, /codesign --verify --deep --strict/);
  assert.match(dmgBuild, /hdiutil create/);
  assert.match(dmgBuild, /hdiutil verify/);
  assert.match(dmgSmoke, /Applications/);
  assert.match(dmgSmoke, /LSMinimumSystemVersion/);
});
