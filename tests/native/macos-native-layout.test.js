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
const transcriptStore = fs.readFileSync(
  path.join(ROOT, "macos/Sources/MeetingTranscriberCore/TranscriptStore.swift"),
  "utf8"
);
const preferenceTests = fs.readFileSync(
  path.join(ROOT, "macos/Tests/MeetingTranscriberCoreTests/NativePreferencesTests.swift"),
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

test("Command-comma opens one system Settings window with current app state", () => {
  const appScene = view.slice(view.indexOf("@main"), view.indexOf("private struct RootView"));
  const rootView = swiftView("RootView", "SettingsView");
  const settingsView = swiftView("SettingsView", "SettingsPage<Content: View>");
  const saveStart = model.indexOf("func saveSettings() async -> Bool {");
  const saveEnd = model.indexOf("\n    func refreshAudioDevices()", saveStart);
  assert.notEqual(saveStart, -1, "missing saveSettings");
  assert.ok(saveEnd > saveStart, "missing saveSettings boundary");
  const saveSettings = model.slice(saveStart, saveEnd);

  assert.equal((appScene.match(/\n\s*Settings \{/g) || []).length, 1);
  assert.equal((appScene.match(/\n\s*SettingsView\(model: model\)/g) || []).length, 1);
  assert.match(
    appScene,
    /Settings \{\s*SettingsView\(model: model\)[\s\S]{0,120}\.task \{ await model\.loadSettings\(\) \}/
  );
  assert.match(rootView, /@Environment\(\\\.openSettings\) private var openSettings/);
  assert.match(
    rootView,
    /\.toolbar \{[\s\S]{0,260}Button \{\s*openSettings\(\)\s*\} label: \{\s*Label\("Settings"/
  );
  assert.match(rootView, /\.onChange\(of: model\.phase\)[\s\S]{0,160}phase == \.setupRequired[\s\S]{0,80}openSettings\(\)/);
  assert.doesNotMatch(view, /\.sheet\([^\n]*showingSettings|Window(?:Group)?\("Settings"/);
  assert.match(settingsView, /@Environment\(\\\.dismiss\) private var dismiss/);
  assert.match(settingsView, /Button\("Done"\) \{ dismiss\(\) \}/);
  assert.match(settingsView, /if await model\.saveSettings\(\)[\s\S]{0,80}dismiss\(\)/);
  assert.match(settingsView, /\.preferredColorScheme\(model\.theme\.colorScheme\)/);
  assert.match(model, /if health\.setupRequired \{\s*initialSetupCompletionPending = true/);
  assert.match(model, /initialSetupCompletionPending = false\s*phase = \.ready/);
  assert.match(saveSettings, /let completesInitialSetup = initialSetupCompletionPending \|\| settingsDocument\?\.configured != true/);
  assert.match(saveSettings, /api\.transcriptionCatalogue\(language: catalogueLanguage\)/);
  assert.match(saveSettings, /if completesInitialSetup \{\s*await connect\(\)\s*return phase == \.ready/);
  assert.equal((saveSettings.match(/return phase == \.ready/g) || []).length, 1);
  assert.doesNotMatch(saveSettings, /return true/);
  assert.match(model, /refreshTranscriptionReadiness\([\s\S]{0,100}reportToSettings: Bool = false/);
  assert.doesNotMatch(model, /showingSettings|func openSettings\(|api\.transcriptionCatalogue\(\)/);
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

test("live transcript follows the bottom until the user scrolls away", () => {
  const transcriptPane = swiftView("TranscriptPane", "SegmentEditor");
  assert.match(transcriptStore, /package struct TranscriptAutoFollowState:[\s\S]*recordUserScroll\(isNearBottom:[\s\S]*shouldFollow\(searchIsActive:/);
  assert.match(preferenceTests, /transcript auto-follow preserves user scroll intent/);
  assert.match(transcriptPane, /@State private var scrollPhase: ScrollPhase = \.idle/);
  assert.match(transcriptPane, /ScrollViewReader \{ proxy in[\s\S]*Self\.bottomAnchor/);
  assert.match(transcriptPane, /\.onScrollGeometryChange\(for: ScrollSnapshot\.self\)[\s\S]{0,220}Self\.isUserDriven\(scrollPhase\)[\s\S]{0,260}recordTranscriptUserScroll/);
  assert.match(transcriptPane, /abs\(new\.contentHeight - old\.contentHeight\) > 0\.5[\s\S]{0,420}shouldAutoFollowTranscript[\s\S]{0,260}scrollTo\(Self\.bottomAnchor, anchor: \.bottom\)/);
  assert.match(transcriptPane, /\.onScrollPhaseChange \{ oldPhase, newPhase, context in[\s\S]{0,420}recordTranscriptUserScroll[\s\S]{0,160}context\.geometry/);
  assert.match(model, /transcriptAutoFollowByMeetingID: \[Int: TranscriptAutoFollowState\]/);
  assert.doesNotMatch(transcriptPane, /Task\.yield\(\)|\.onChange\(of: filteredItems\)|\.onAppear[\s\S]{0,80}scrollTo/);
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
