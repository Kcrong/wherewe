"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "../..");
const model = fs.readFileSync(
  path.join(ROOT, "macos/Sources/MeetingTranscriberApp/AppModel.swift"),
  "utf8"
);
const view = fs.readFileSync(
  path.join(ROOT, "macos/Sources/MeetingTranscriberApp/MeetingTranscriberApp.swift"),
  "utf8"
);

function swiftView(name, nextName) {
  const start = view.indexOf(`private struct ${name}: View {`);
  const end = view.indexOf(`\nprivate struct ${nextName}: View {`, start);
  assert.notEqual(start, -1, `missing SwiftUI view: ${name}`);
  assert.notEqual(end, -1, `missing SwiftUI boundary after: ${name}`);
  return view.slice(start, end);
}

test("settings expose fixed Apple providers and supported storage paths", () => {
  assert.match(view, /GroupBox\("Apple Speech"\)/);
  assert.match(view, /Text\("Provider"\)[\s\S]{0,180}Text\("Apple Speech"\)/);
  assert.match(view, /Text\("Model"\)[\s\S]{0,180}Text\("System"\)/);
  assert.match(view, /GroupBox\("Apple Translation"\)/);
  assert.match(view, /binding\(\\\.paths\.database\)/);
  assert.match(view, /binding\(\\\.paths\.files\)/);
  assert.match(model, /provider: "apple",\s*model: "system"/);
});

test("meeting and CoreAudio recording controls remain available", () => {
  assert.match(view, /TextField\("Search meetings"/);
  assert.match(view, /Label\("New Meeting", systemImage: "plus"\)/);
  assert.match(view, /TextField\("Meeting title"/);
  assert.match(view, /private var recordingControls:[\s\S]*Text\("Microphone"\)/);
  assert.match(view, /Text\("System audio input"\)/);
  assert.match(view, /Text\("Recognition language"\)/);
  assert.match(view, /Button\("Start Recording"\)/);
  assert.match(view, /Button\("Stop Recording"\)/);
  assert.match(model, /CoreAudioCaptureSession\(\)/);
  assert.match(model, /RecordingCoordinator\(api: service, realtime: realtime\)/);
});

test("workspace contains only retained local tools", () => {
  assert.deepEqual(
    [...model.matchAll(/^\s{8}case (transcript|files|glossary|export)$/gm)].map((match) => match[1]),
    ["transcript", "files", "glossary", "export"]
  );
  assert.match(view, /Text\("Transcript"\)\.tag\(AppModel\.WorkspaceTab\.transcript\)/);
  assert.match(view, /Text\("Files"\)\.tag\(AppModel\.WorkspaceTab\.files\)/);
  assert.match(view, /Text\("Glossary"\)\.tag\(AppModel\.WorkspaceTab\.glossary\)/);
  assert.match(view, /Text\("Export"\)\.tag\(AppModel\.WorkspaceTab\.export\)/);
});

test("transcript search copy editing and translation retry remain", () => {
  assert.match(view, /TextField\("Search transcript"/);
  assert.match(view, /Label\("Copy", systemImage: "doc\.on\.doc"\)/);
  assert.match(view, /Text\("Edited"\)\.tag\(NativePreferences\.TranscriptView\.edited\)/);
  assert.match(view, /Button\("Edit"\)/);
  assert.match(view, /Button\("Retry Translation"\)/);
  assert.match(model, /api\.editTranscript\(/);
  assert.match(model, /api\.editSegment\(/);
  assert.match(model, /api\.retryTranslation\(/);
});

test("attachments glossary and export remain local UI surfaces", () => {
  assert.match(view, /private struct FilesPane/);
  assert.match(view, /private struct DocumentPreviewView/);
  assert.match(view, /private struct GlossaryPane/);
  assert.match(view, /private struct ExportPane/);
  assert.match(model, /api\.uploadDocument\(/);
  assert.match(model, /api\.createGlossary\(/);
  assert.match(model, /api\.exportMeeting\(/);
  assert.match(model, /api\.reveal\(/);
});

test("native layout keeps adaptive system controls", () => {
  const rootView = swiftView("RootView", "SettingsView");
  const meetingDetail = swiftView("MeetingDetailView", "NewMeetingView");
  const bodyStart = meetingDetail.indexOf("var body: some View {");
  const bodyEnd = meetingDetail.indexOf("private var meetingSetupContent");
  const detailBody = meetingDetail.slice(bodyStart, bodyEnd);

  assert.match(view, /\.frame\(minWidth: 900, minHeight: 700\)/);
  assert.match(rootView, /navigationSplitViewColumnWidth\(min: 180, ideal: 220, max: 300\)/);
  assert.match(view, /Grid\(alignment: \.leading/);
  assert.doesNotMatch(view, /\.shadow\(|LinearGradient|AngularGradient|RadialGradient/);
  assert.match(meetingDetail, /ToolbarItemGroup\(placement: \.primaryAction\)/);
  assert.match(view, /static let setupPaneMinimumHeight: CGFloat = 260/);
  assert.match(view, /static let setupPaneIdealHeight: CGFloat = 440/);
  assert.match(view, /static let workspaceMinimumHeight: CGFloat = 280/);

  assert.equal((rootView.match(/\.safeAreaPadding\(\.top\)/g) || []).length, 2);
  assert.match(
    rootView,
    /VStack\(spacing: 8\) \{[\s\S]*?\n            \}\n            \.safeAreaPadding\(\.top\)\n            \.navigationSplitViewColumnWidth/
  );
  assert.match(
    rootView,
    /\} detail: \{\n            detail\n                \.safeAreaPadding\(\.top\)\n        \}/
  );

  assert.match(detailBody, /^var body: some View \{\n        VSplitView \{/);
  assert.equal((detailBody.match(/VSplitView \{/g) || []).length, 1);
  assert.equal((detailBody.match(/ScrollView\(\.vertical\)/g) || []).length, 1);
  assert.doesNotMatch(detailBody, /GeometryReader|compactDetailHeight|if\s+geometry/);
  assert.ok(detailBody.indexOf("ScrollView(.vertical)") < detailBody.indexOf("WorkspacePane(model: model)"));
  assert.match(
    detailBody,
    /meetingSetupContent[\s\S]{0,260}minHeight: NativeLayoutMetrics\.setupPaneMinimumHeight[\s\S]{0,120}idealHeight: NativeLayoutMetrics\.setupPaneIdealHeight/
  );
  assert.match(
    detailBody,
    /WorkspacePane\(model: model\)[\s\S]{0,240}minHeight: NativeLayoutMetrics\.workspaceMinimumHeight/
  );
});
