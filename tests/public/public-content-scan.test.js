"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const scanner = require("../../scripts/scan-public-content.js");
const manifest = require("../../source-manifest.json");
const ci = fs.readFileSync(path.join(ROOT, ".github/workflows/test.yml"), "utf8");
const localGate = fs.readFileSync(path.join(ROOT, "scripts/pre-push-macos.sh"), "utf8");

function candidates() {
  return execFileSync(
    "git",
    ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
    { cwd: ROOT }
  ).toString("utf8").split("\0").filter(Boolean);
}

test("synthetic sensitive content is detected without returning matched values", () => {
  const syntheticToken = ["gh", "p_", "A1b2".repeat(10)].join("");
  const syntheticCloudKey = ["A", "KIA", "A1B2C3D4E5F6G7H8"].join("");
  const syntheticKey = ["-----BEGIN ", "PRIVATE", " KEY-----"].join("");
  const syntheticEmail = ["person", "example.net"].join("@");
  const syntheticAddress = ["10", "20", "30", "40"].join(".");
  const syntheticPath = ["/home/", "private-user", "/project"].join("");
  const source = [
    syntheticToken,
    syntheticCloudKey,
    syntheticKey,
    syntheticEmail,
    syntheticAddress,
    syntheticPath,
  ].join("\n");

  const findings = scanner.scanText(source, "synthetic.txt");
  const rules = new Set(findings.map((item) => item.rule));
  for (const expected of [
    "github-token",
    "cloud-access-key-id",
    "private-key",
    "private-network-address",
    "machine-specific-path",
  ]) {
    assert.ok(rules.has(expected), `missing synthetic detection: ${expected}`);
  }
  assert.ok(!rules.has("email-address"), "documented example domains stay usable");
  for (const item of findings) {
    assert.deepEqual(Object.keys(item).sort(), ["line", "path", "rule"]);
  }
  const report = JSON.stringify(findings);
  for (const value of [syntheticToken, syntheticCloudKey, syntheticKey, syntheticAddress, syntheticPath]) {
    assert.ok(!report.includes(value), "findings must never contain matched values");
  }
});

test("hashed context and focused provider credentials are detected without readable labels", () => {
  const blockedVectors = [
    [97, 109, 97, 122, 111, 110],
    [97, 119, 115],
    [98, 101, 100, 114, 111, 99, 107],
    [97, 119, 115, 32, 111, 117, 116, 108, 111, 111, 107, 32, 109, 99, 112],
    [97, 119, 115, 111, 117, 116, 108, 111, 111, 107, 109, 99, 112],
    [97, 110, 116, 104, 114, 111, 112, 105, 99],
    [99, 108, 97, 117, 100, 101],
    [97, 99, 112],
    [97, 103, 101, 110, 116, 32, 99, 108, 105, 101, 110, 116, 32, 112, 114, 111, 116, 111, 99, 111, 108],
    [97, 103, 101, 110, 116, 99, 108, 105, 101, 110, 116, 112, 114, 111, 116, 111, 99, 111, 108],
    [107, 105, 114, 111, 32, 99, 108, 105],
    [107, 105, 114, 111, 99, 108, 105],
    [119, 104, 105, 115, 112, 101, 114],
    [104, 117, 103, 103, 105, 110, 103, 32, 102, 97, 99, 101],
    [104, 117, 103, 103, 105, 110, 103, 102, 97, 99, 101],
    [109, 101, 101, 116, 105, 110, 103, 32, 108, 111, 103],
    [109, 101, 101, 116, 105, 110, 103, 108, 111, 103],
    [111, 112, 101, 110, 97, 105],
    [105, 110, 116, 101, 114, 118, 105, 101, 119, 32, 114, 101, 104, 101, 97, 114, 115, 97, 108],
    [105, 110, 116, 101, 114, 118, 105, 101, 119, 114, 101, 104, 101, 97, 114, 115, 97, 108],
    [109, 111, 100, 101, 108, 32, 100, 111, 119, 110, 108, 111, 97, 100],
    [109, 111, 100, 101, 108, 100, 111, 119, 110, 108, 111, 97, 100],
    [97, 109, 97, 122, 111, 110, 98, 101, 100, 114, 111, 99, 107],
    [97, 109, 97, 122, 111, 110, 119, 101, 98, 115, 101, 114, 118, 105, 99, 101, 115],
    [119, 104, 105, 115, 112, 101, 114, 99, 112, 112],
    [104, 101, 108, 112, 101, 114, 32, 112, 114, 111, 99, 101, 115, 115],
    [104, 101, 108, 112, 101, 114, 112, 114, 111, 99, 101, 115, 115],
    [108, 105, 115, 116, 101, 110, 101, 114],
    [114, 101, 115, 101, 97, 114, 99, 104],
    [105, 110, 116, 101, 114, 118, 105, 101, 119],
    [99, 104, 97, 116],
    [99, 108, 101, 97, 110, 117, 112],
    [115, 117, 103, 103, 101, 115, 116, 105, 111, 110],
    [114, 101, 112, 108, 121],
    [109, 101, 101, 116, 105, 110, 103, 108, 111, 103, 97, 105],
    [109, 111, 100, 101, 108, 32, 100, 105, 115, 99, 111, 118, 101, 114, 121],
    [109, 111, 100, 101, 108, 100, 105, 115, 99, 111, 118, 101, 114, 121],
  ];
  assert.equal(blockedVectors.length, 37);
  const contextFindings = [];
  for (const vector of blockedVectors) {
    const value = String.fromCharCode(...vector);
    const findings = scanner.scanText(value, "mutation.md");
    assert.ok(findings.some((item) => item.rule === "prohibited-context"));
    contextFindings.push(...findings);
  }

  const hiddenPrefix = String.fromCharCode(65, 73, 122, 97);
  const credential = hiddenPrefix + "A1b2".repeat(9).slice(0, 35);
  assert.equal(credential.length, 39);
  const credentialFindings = scanner.scanText(credential, "mutation.txt");
  assert.ok(credentialFindings.some((item) => item.rule === "provider-credential"));

  for (const benign of [
    "Apple Speech and Apple Translation stay local.",
    "Local transcript export",
    "System recording workflow",
    "Meeting notes",
  ]) {
    assert.deepEqual(scanner.scanText(benign), []);
  }
  assert.deepEqual(scanner.scanText(`Tst0${"A".repeat(35)}`), []);

  const report = JSON.stringify([...contextFindings, ...credentialFindings]);
  for (const vector of blockedVectors) {
    assert.ok(!report.includes(String.fromCharCode(...vector)));
  }
  assert.ok(!report.includes(credential));
});

test("placeholder assignments stay usable while non-placeholder literals are flagged", () => {
  const placeholder = ["api", "_key = \"", "test-placeholder-not-a-secret", "\""].join("");
  const literal = ["api", "_key = \"", "Ab3Def6Gh9Jk2Lm5Np8Qr1St4Uv7Wx0Yz", "\""].join("");
  assert.deepEqual(scanner.scanText(placeholder), []);
  assert.ok(scanner.scanText(literal).some((item) => item.rule === "literal-secret-assignment"));
  assert.ok(scanner.entropy("Ab3Def6Gh9Jk2Lm5Np8Qr1St4Uv7Wx0Yz") > 4);
});

test("forbidden generated and environment paths are rejected", () => {
  for (const relative of [
    ".env.production",
    "dist/macos/Wherewe.dmg",
    "build/Wherewe.app/Contents/Info.plist",
  ]) {
    assert.ok(scanner.scanPath(relative, manifest).some((item) => item.rule === "forbidden-path"));
  }
});

test("current repository tree scans clean with redacted output", () => {
  const result = scanner.scanRepository(ROOT);
  assert.deepEqual(result.findings, []);
  assert.ok(result.files > 80);
  assert.ok(result.bytes > 200_000);
});

test("hosted and local gates run every public contract and the redacted scanner", () => {
  for (const source of [ci, localGate]) {
    assert.match(source, /tests\/public\/\*\.test\.js/);
    assert.match(source, /(?:node|"\$NODE_BIN") scripts\/scan-public-content\.js/);
    assert.match(source, /tests\/native\/\*\.test\.js[\s\\\"]+tests\/public\/\*\.test\.js/);
  }
});

test("omitted media fixture remains unreferenced throughout the repository", () => {
  const heldPath = ["tests", "fixtures", "speech-en" + ".wav"].join("/");
  const violations = candidates().filter((relative) => {
    const absolute = path.join(ROOT, relative);
    return fs.lstatSync(absolute).isFile()
      && fs.readFileSync(absolute, "utf8").includes(heldPath);
  });
  assert.deepEqual(violations, []);
});

test("immutable public source URLs are not treated as secret tokens", () => {
  const commit = "86098128c0b4f24f0e2aa2994de830614b474227";
  const sourceURL = ["https://github.com/example/project/blob/", commit, "/LICENSE"].join("");
  assert.deepEqual(scanner.scanText(sourceURL), []);
  const syntheticEntropy = ["Ab3Def6Gh9Jk2Lm5Np8Qr1", "St4Uv7Wx0YzQ7r9S2t"].join("");
  assert.ok(scanner.scanText(syntheticEntropy).some(
    (item) => item.rule === "high-entropy-token"
  ));
});

test("local planning files remain outside the repository file set", () => {
  const localFiles = new Set([
    "north_star.md",
    "roadmap.md",
    "tasks.md",
    ".wherewe-public-loop.stop",
  ]);
  assert.deepEqual(candidates().filter((relative) => localFiles.has(relative)), []);
});
