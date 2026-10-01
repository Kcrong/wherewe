"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const workspacePath = path.join(
  ROOT,
  "macos/Sources/MeetingTranscriberCore/NativeSpoolWorkspace.swift"
);
const realtime = read("macos/Sources/MeetingTranscriberCore/NativeRealtimeClient.swift");

test("PCM spools use process-owned locked workspaces with verified modes", () => {
  assert.ok(fs.existsSync(workspacePath), "missing native spool workspace");
  const workspace = fs.readFileSync(workspacePath, "utf8");

  assert.match(workspace, /process-.*getpid\(\)/s);
  assert.match(workspace, /\.owner\.lock/);
  assert.match(workspace, /flock\(/);
  assert.match(workspace, /LOCK_EX \| LOCK_NB/);
  assert.match(workspace, /kill\(pid, 0\)/);
  assert.match(workspace, /0o700/);
  assert.match(workspace, /0o600/);
  assert.match(workspace, /verifyMode/);
  assert.doesNotMatch(workspace, /try\? fileManager\.setAttributes/);
});

test("realtime client creates spools only through the owned workspace", () => {
  assert.match(realtime, /NativeSpoolWorkspace/);
  assert.match(realtime, /makeSpoolFile\(\)/);
  assert.doesNotMatch(realtime, /static let launchDate/);
  assert.doesNotMatch(realtime, /sweepOrphanedSpools/);
  assert.doesNotMatch(realtime, /createFile\([\s\S]*\.pcm/);
});
