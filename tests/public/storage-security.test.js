"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const policyPath = path.join(
  ROOT,
  "macos/Sources/MeetingTranscriberCore/NativeStoragePathPolicy.swift"
);
const settings = read("macos/Sources/MeetingTranscriberCore/NativeSettingsStore.swift");
const sqlite = read("macos/Sources/MeetingTranscriberCore/NativeSQLite.swift");
const documents = read("macos/Sources/MeetingTranscriberCore/NativeServiceDocuments.swift");
const exportsSource = read("macos/Sources/MeetingTranscriberCore/NativeServiceExport.swift");

test("settings and SQLite use one canonical symlink-safe storage policy", () => {
  assert.ok(fs.existsSync(policyPath), "missing native storage path policy");
  const policy = fs.readFileSync(policyPath, "utf8");

  assert.match(policy, /isAbsolutePath/);
  assert.match(policy, /standardizedFileURL/);
  assert.match(policy, /destinationOfSymbolicLink/);
  assert.match(policy, /isDirectoryKey/);
  assert.match(policy, /isRegularFileKey/);
  assert.match(policy, /isSymbolicLinkKey/);
  assert.match(policy, /verifyMode/);
  assert.match(policy, /0o700/);
  assert.match(policy, /0o600/);

  assert.match(settings, /NativeStoragePathPolicy\.canonicalize/);
  assert.match(settings, /NativeStoragePathPolicy\.secureDirectory/);
  assert.match(settings, /NativeStoragePathPolicy\.validateDatabaseURL/);
  assert.match(settings, /request\.paths\.database/);
  assert.match(settings, /request\.paths\.files/);
  assert.doesNotMatch(settings, /try\? fileManager\.setAttributes/);

  assert.match(sqlite, /NativeStoragePathPolicy\.validateDatabaseURL/);
  assert.match(sqlite, /NativeStoragePathPolicy\.securePrivateFile/);
  assert.doesNotMatch(sqlite, /try\? fileManager\.setAttributes/);
});

test("configured content roots and files fail closed on permission changes", () => {
  for (const source of [documents, exportsSource]) {
    assert.match(source, /NativeStoragePathPolicy/);
    assert.doesNotMatch(source, /try\? fileManager\.setAttributes/);
  }
});
