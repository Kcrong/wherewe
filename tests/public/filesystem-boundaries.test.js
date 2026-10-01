"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), "utf8");
const documents = read("macos/Sources/MeetingTranscriberCore/NativeServiceDocuments.swift");
const meetings = read("macos/Sources/MeetingTranscriberCore/NativeServiceMeetings.swift");
const exportsSource = read("macos/Sources/MeetingTranscriberCore/NativeServiceExport.swift");
const realtime = read("macos/Sources/MeetingTranscriberCore/NativeRealtimeClient.swift");
const policyPath = path.join(
  ROOT,
  "macos/Sources/MeetingTranscriberCore/NativeDocumentPathPolicy.swift"
);

test("all stored attachment operations use one strict path policy", () => {
  assert.ok(fs.existsSync(policyPath), "missing stored attachment path policy");
  const policy = fs.readFileSync(policyPath, "utf8");

  assert.match(documents, /NativeDocumentPathPolicy/);
  assert.match(meetings, /NativeDocumentPathPolicy/);
  assert.match(exportsSource, /NativeDocumentPathPolicy/);
  assert.doesNotMatch(documents, /removeItem\(atPath: path\)/);
  assert.doesNotMatch(meetings, /removeItem\(atPath: path\)/);
  assert.doesNotMatch(exportsSource, /copyItem\(atPath: sourcePath/);
  assert.match(
    exportsSource,
    /do \{[\s\S]*copyAttachments[\s\S]*\} catch \{[\s\S]*removeItem\(at: exportURL\)[\s\S]*throw error/
  );
  assert.match(policy, /resolvingSymlinksInPath\(\)/);
  assert.match(policy, /isRegularFileKey/);
  assert.match(policy, /isSymbolicLinkKey/);
  assert.match(policy, /fileSizeKey/);
  assert.match(policy, /root\.path \+ "\/"/);
  assert.match(policy, /5 \* 1_024 \* 1_024/);
});

test("realtime registrations are active only while connected", () => {
  assert.match(realtime, /private struct Registration[\s\S]*var active: Bool/);
  assert.match(realtime, /func setActive\(/);
  assert.match(realtime, /connect\(\)[\s\S]*hub\.setActive\(identifier, true\)/);
  assert.match(realtime, /disconnect\(\)[\s\S]*hub\.setActive\(identifier, false\)/);
  assert.match(realtime, /registrations\.values\.filter\(\\\.active\)/);
  assert.match(realtime, /func registrationCount\(/);
});

test("export write failure and cancellation remove the complete partial bundle", () => {
  const observerPath = path.join(
    ROOT,
    "macos/Sources/MeetingTranscriberCore/NativeExportLifecycleObserver.swift"
  );
  const regressionPath = path.join(
    ROOT,
    "macos/Tests/MeetingTranscriberCoreTests/ExportFailureSecurityTests.swift"
  );
  assert.ok(fs.existsSync(observerPath), "missing export lifecycle observer");
  assert.ok(fs.existsSync(regressionPath), "missing export failure regressions");
  const observer = fs.readFileSync(observerPath, "utf8");
  const regressions = fs.readFileSync(regressionPath, "utf8");

  assert.match(observer, /afterDirectoryCreation/);
  assert.match(exportsSource, /await exportLifecycleObserver\.afterDirectoryCreation\(exportURL\)/);
  assert.ok((exportsSource.match(/Task\.checkCancellation\(\)/g) || []).length >= 4);
  assert.match(exportsSource, /catch \{[\s\S]*removeItem\(at: exportURL\)[\s\S]*throw error/);
  assert.match(regressions, /write collision removes the partial export bundle/);
  assert.match(regressions, /cancellation removes the partial export bundle/);
  assert.match(regressions, /task\.cancel\(\)/);
  assert.match(regressions, /fileExists\(atPath: exportURL\.path\)/);
});
