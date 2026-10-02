"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const swiftTestDirectory = path.join(ROOT, "macos/Tests/MeetingTranscriberCoreTests");

function files(directory, suffix) {
  return fs.readdirSync(directory)
    .filter((name) => name.endsWith(suffix))
    .sort()
    .map((name) => path.join(directory, name));
}

test("testing guide matches the executable Apple-only inventory", () => {
  const guidePath = path.join(ROOT, "docs/testing.md");
  assert.ok(fs.existsSync(guidePath), "docs/testing.md is required");
  const guide = fs.readFileSync(guidePath, "utf8");
  const testWorkflow = read(".github/workflows/test.yml");
  const releaseWorkflow = read(".github/workflows/release-macos.yml");
  const releaseGate = read("scripts/test-release-prerequisites.sh");
  const localGate = read("scripts/pre-push-macos.sh");

  const swiftFiles = files(swiftTestDirectory, ".swift");
  const swiftSource = swiftFiles.map((file) => fs.readFileSync(file, "utf8")).join("\n");
  const swiftTests = (swiftSource.match(/@Test\(/g) || []).length;
  const swiftSuites = (swiftSource.match(/@Suite\(/g) || []).length;
  const gatedTests = (swiftSource.match(/\.enabled\(if: NativeRuntimeEvidence\.isRequested\("WHEREWE_NATIVE_REAL_/g) || []).length;
  const evidenceRecords = (swiftSource.match(/NativeRuntimeEvidence\.record\("/g) || []).length;
  const runtimeKeys = [...new Set(swiftSource.match(/WHEREWE_NATIVE_REAL_[A-Z_]+/g) || [])].sort();

  const nodeFiles = [
    ...files(path.join(ROOT, "tests/native"), ".test.js"),
    ...files(path.join(ROOT, "tests/public"), ".test.js"),
  ];
  const nodeSource = nodeFiles.map((file) => fs.readFileSync(file, "utf8")).join("\n");
  const nodeTests = (nodeSource.match(/^test\(/gm) || []).length;
  const evidenceMarkers = [
    "apple-speech-accurate",
    "apple-speech-commit-boundary",
    "apple-translation",
    "physical-dual-input",
    "physical-system-only",
  ];

  assert.equal(gatedTests, 5);
  assert.equal(evidenceRecords, 5);
  assert.doesNotMatch(swiftSource, /guard ProcessInfo\.processInfo\.environment\["WHEREWE_NATIVE_REAL_/);
  for (const marker of evidenceMarkers) {
    assert.ok(swiftSource.includes(`NativeRuntimeEvidence.record("${marker}")`));
    assert.ok(guide.includes(`\`${marker}\``), `guide missing evidence marker ${marker}`);
  }
  for (const marker of evidenceMarkers.slice(0, 3)) {
    assert.ok(localGate.includes(marker), `required local gate missing ${marker}`);
  }
  assert.doesNotMatch(releaseGate, /WHEREWE_NATIVE_REAL_APPLE_(?:SPEECH|TRANSLATION)|NativeRuntimeIntegrationTests/);
  assert.match(
    releaseWorkflow,
    /name: Probe available Apple runtime assets[\s\S]{0,160}continue-on-error: true[\s\S]{0,80}timeout-minutes: 5[\s\S]{0,240}WHEREWE_NATIVE_REAL_APPLE_SPEECH: 'auto'[\s\S]{0,120}WHEREWE_NATIVE_REAL_APPLE_TRANSLATION: 'auto'/
  );
  assert.doesNotMatch(releaseGate, /required Apple runtime evidence is missing/);
  assert.match(testWorkflow, /name: Probe available Apple runtime assets/);
  assert.match(testWorkflow, /WHEREWE_NATIVE_REAL_APPLE_SPEECH: 'auto'/);
  assert.match(testWorkflow, /WHEREWE_NATIVE_REAL_APPLE_TRANSLATION: 'auto'/);
  assert.match(testWorkflow, /actions\/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a/);

  assert.ok(guide.includes(`Swift test sources: ${swiftFiles.length} files, ${swiftSuites} suites, ${swiftTests} declared tests.`));
  assert.ok(guide.includes(`Deterministic Swift baseline: ${swiftTests - gatedTests} tests.`));
  assert.ok(guide.includes(`Opt-in Swift runtime and hardware checks: ${gatedTests} tests across ${runtimeKeys.length} environment keys.`));
  assert.ok(guide.includes(`Node source contracts: ${nodeFiles.length} files, ${nodeTests} declared tests.`));
  for (const file of [...swiftFiles, ...nodeFiles]) {
    assert.ok(guide.includes(path.basename(file)), `guide missing ${path.basename(file)}`);
  }
  for (const key of runtimeKeys) {
    assert.ok(guide.includes(`\`${key}\``), `guide missing ${key}`);
  }

  for (const required of [
    "No XCUIAutomation target",
    "No coverage baseline",
    "Pre-secret release gate",
    "Hardware, TCC, route changes, unplug, and sleep/wake",
    "Retry and recovery",
    "Export rollback",
  ]) {
    assert.ok(guide.includes(required), `guide missing risk: ${required}`);
  }

  assert.match(testWorkflow, /macos:[\s\S]*needs: static[\s\S]*runs-on: macos-26/);
  assert.match(releaseWorkflow, /bash scripts\/test-release-prerequisites\.sh/);
  assert.ok(
    releaseWorkflow.indexOf("Run complete non-secret release gate")
      < releaseWorkflow.indexOf("Require release credentials")
  );
});
