"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const scanner = require("../../scripts/scan-public-content.js");

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
const modelTests = fs.readFileSync(
  path.join(ROOT, "macos/Tests/MeetingTranscriberCoreTests/ModelsTests.swift"),
  "utf8"
);
const coreModels = fs.readFileSync(
  path.join(ROOT, "macos/Sources/MeetingTranscriberCore/Models.swift"),
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
  assert.equal((appScene.match(/\n\s*SettingsView\(model: lifecycleDelegate\.model\)/g) || []).length, 1);
  assert.match(
    appScene,
    /Settings \{\s*SettingsView\(model: lifecycleDelegate\.model\)[\s\S]{0,120}\.task \{ await lifecycleDelegate\.model\.loadSettings\(\) \}/
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

test("database changes clear and reload application state before mutations resume", () => {
  const rootView = swiftView("RootView", "SettingsView");
  const saveStart = model.indexOf("func saveSettings() async -> Bool {");
  const clearStart = model.indexOf("private func clearDatabaseBackedState()");
  const reloadStart = model.indexOf("private func reloadDatabaseBackedState() async");
  const refreshAudioStart = model.indexOf("func refreshAudioDevices()", reloadStart);

  assert.notEqual(saveStart, -1, "missing saveSettings");
  assert.ok(clearStart > saveStart, "missing database state reset");
  assert.ok(reloadStart > clearStart, "missing database state reload");
  assert.ok(refreshAudioStart > reloadStart, "missing database reload boundary");

  const saveSettings = model.slice(saveStart, clearStart);
  const clearState = model.slice(clearStart, reloadStart);
  const reloadState = model.slice(reloadStart, refreshAudioStart);
  const transitionStart = saveSettings.indexOf("databaseTransitionInProgress = switchesDatabase");
  const clearCall = saveSettings.indexOf("if switchesDatabase { clearDatabaseBackedState() }");
  const databaseUpdate = saveSettings.indexOf("api.updateSettings(draft, etag: settingsETag)");
  const reloadCall = saveSettings.indexOf("await reloadDatabaseBackedState()", databaseUpdate);

  assert.match(model, /@Published private\(set\) var databaseTransitionInProgress = false/);
  assert.match(rootView, /\.disabled\(model\.databaseTransitionInProgress\)/);
  assert.match(saveSettings, /let switchesDatabase = settingsDocument\?\.paths\.database != draft\.paths\.database/);
  assert.match(
    saveSettings,
    /switchesDatabase,[\s\S]{0,180}meetingMutationInProgress \|\| fileOperationInProgress \|\| glossaryOperationInProgress/
  );
  assert.match(
    saveSettings,
    /defer \{\s*databaseTransitionInProgress = false\s*settingsInProgress = false\s*\}/
  );
  assert.ok(transitionStart >= 0 && transitionStart < clearCall);
  assert.ok(clearCall < databaseUpdate);
  assert.ok(databaseUpdate < reloadCall);

  assert.match(clearState, /meetingLoadGeneration \+= 1/);
  assert.match(clearState, /meetings = \[\][\s\S]*selectedMeetingID = nil[\s\S]*meetingDetail = nil/);
  assert.match(clearState, /meetingTitleDraft = ""[\s\S]*meetingContextDraft = ""/);
  assert.match(clearState, /transcriptStore = TranscriptStore\(\)[\s\S]*transcriptItems = \[\]/);
  assert.match(clearState, /documents = \[\][\s\S]*globalGlossary = \[\][\s\S]*meetingGlossary = \[\]/);
  assert.match(
    reloadState,
    /meetings = try await api\.meetings\(\)[\s\S]*selectedMeetingID = meetings\.first\?\.id[\s\S]*await loadSelectedMeeting\(\)/
  );
  assert.match(model, /var canStartRecording:[\s\S]{0,220}!databaseTransitionInProgress/);
  assert.match(model, /func selectMeeting[\s\S]{0,140}!databaseTransitionInProgress/);
  assert.match(model, /func refreshMeetings[\s\S]{0,140}!databaseTransitionInProgress/);

  const guardedMutations = [
    "startRecordingWithoutMeeting",
    "createMeeting",
    "saveMeetingDetails",
    "deleteSelectedMeeting",
    "changeTranslationTarget",
    "saveSegmentEdit",
    "retryTranslation",
    "uploadDocuments",
    "deleteDocument",
    "addGlossaryEntry",
    "saveGlossaryEdit",
    "deleteGlossaryEntry",
  ];
  for (const functionName of guardedMutations) {
    const start = model.indexOf(`func ${functionName}(`);
    const end = model.indexOf("\n    func ", start + 1);
    assert.notEqual(start, -1, `missing ${functionName}`);
    assert.ok(end > start, `missing boundary after ${functionName}`);
    assert.match(
      model.slice(start, end),
      /!databaseTransitionInProgress/,
      `${functionName} must reject database mutations during a transition`
    );
  }
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

test("meeting selection clears stale state and fences meeting mutations", () => {
  const rootView = swiftView("RootView", "SettingsView");
  const loadStart = model.indexOf("func loadSelectedMeeting() async {");
  const loadEnd = model.indexOf("\n    func startRecordingWithoutMeeting()", loadStart);
  const loadSelectedMeeting = model.slice(loadStart, loadEnd);
  const clearStart = model.indexOf("private func clearMeetingDependentState() {");
  const clearEnd = model.indexOf("\n    func refreshMeetings()", clearStart);
  const clearMeetingDependentState = model.slice(clearStart, clearEnd);

  assert.notEqual(loadStart, -1, "missing selected meeting load");
  assert.ok(loadEnd > loadStart, "missing selected meeting load boundary");
  assert.notEqual(clearStart, -1, "missing meeting state invalidation");
  assert.ok(clearEnd > clearStart, "missing meeting state invalidation boundary");
  assert.match(model, /@Published private var meetingSelection = MeetingSelectionState\(\)/);
  assert.match(
    coreModels,
    /package struct MeetingSelectionState:[\s\S]{0,180}package init\(\) \{[\s\S]{0,100}selectedID = nil[\s\S]{0,100}loadedID = nil/
  );
  assert.match(model, /var selectedMeetingID: Int\? \{ meetingSelection\.selectedID \}/);
  assert.match(model, /var selectedMeetingIsLoaded: Bool \{ loadedSelectedMeetingID != nil \}/);
  assert.match(
    model,
    /private func updateMeetingSelection\(_ id: Int\?\)[\s\S]{0,240}nextSelection\.select\(id\)[\s\S]{0,160}meetingLoadGeneration \+= 1[\s\S]{0,100}clearMeetingDependentState\(\)/
  );
  for (const state of [
    "meetingDetail = nil",
    'meetingTitleDraft = ""',
    'meetingContextDraft = ""',
    "transcriptItems = []",
    "documents = []",
    "documentPreview = nil",
    "meetingGlossary = []",
    "exportResult = nil",
  ]) {
    assert.ok(clearMeetingDependentState.includes(state), `selection change must clear ${state}`);
  }

  const loadOrder = [
    "beginLoading()",
    "clearMeetingDependentState()",
    "api.meeting(id: meetingID)",
    "api.activateMeeting(id: meetingID)",
    "await loadDocuments()",
    "await loadGlossary()",
    "finishLoading(meetingID)",
    "meetingSelection = loadedSelection",
  ];
  let prior = -1;
  for (const expression of loadOrder) {
    const index = loadSelectedMeeting.indexOf(expression);
    assert.ok(index > prior, `meeting load ordering is missing or invalid: ${expression}`);
    prior = index;
  }
  assert.match(
    loadSelectedMeeting,
    /guard generation == meetingLoadGeneration, selectedMeetingID == meetingID else \{ return \}[\s\S]{0,160}finishLoading\(meetingID\)/
  );

  for (const method of [
    "saveMeetingDetails",
    "deleteSelectedMeeting",
    "changeTranslationTarget",
    "saveSegmentEdit",
    "retryTranslation",
    "uploadDocuments",
    "exportSelectedMeeting",
    "resyncTranscriptState",
  ]) {
    const start = model.indexOf(`func ${method}(`);
    assert.notEqual(start, -1, `missing mutation method: ${method}`);
    const nextPublic = model.indexOf("\n    func ", start + 1);
    const nextPrivate = model.indexOf("\n    private func ", start + 1);
    const boundaries = [nextPublic, nextPrivate].filter((index) => index > start);
    const end = boundaries.length > 0 ? Math.min(...boundaries) : model.length;
    assert.match(
      model.slice(start, end),
      /loadedSelectedMeetingID/,
      `${method} must require the loaded selection`
    );
  }

  assert.match(model, /func deleteSelectedMeeting[\s\S]{0,900}api\.deleteMeeting[\s\S]{0,140}if selectedMeetingID == meetingID[\s\S]{0,100}updateMeetingSelection\(nil\)[\s\S]{0,180}if selectedMeetingID == nil/);
  assert.match(model, /func beginEditingSegment[\s\S]{0,140}loadedSelectedMeetingID == segment\.meetingID/);
  assert.match(model, /func previewDocument[\s\S]{0,220}let meetingID = loadedSelectedMeetingID[\s\S]{0,140}documents\.contains/);
  assert.match(model, /func uploadDocuments[\s\S]{0,900}guard loadedSelectedMeetingID == meetingID else \{ return \}[\s\S]{0,140}api\.uploadDocument/);
  assert.match(model, /func exportSelectedMeeting[\s\S]{0,260}api\.exportMeeting[\s\S]{0,140}guard loadedSelectedMeetingID == meetingID/);
  assert.match(model, /func deleteDocument[\s\S]{0,220}loadedSelectedMeetingID != nil[\s\S]{0,140}documents\.contains/);
  assert.match(model, /func deleteGlossaryEntry[\s\S]{0,260}loadedSelectedMeetingID == meetingID[\s\S]{0,120}meetingGlossary\.contains/);
  assert.match(model, /event\.meetingID == self\.loadedSelectedMeetingID/);
  assert.match(rootView, /if model\.selectedMeetingIsLoaded \{\s*MeetingDetailView/);
  assert.match(rootView, /ProgressView\("Loading meeting…"\)/);
  assert.match(rootView, /title: "Meeting Unavailable"[\s\S]{0,300}await model\.loadSelectedMeeting\(\)/);
  assert.match(modelTests, /meeting selection admits mutations only after the matching load/);
  assert.doesNotMatch(
    modelTests,
    /#expect\([^\n]*selection\.(?:select|beginLoading|finishLoading)\(/
  );
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


test("application termination waits for recording finalization before replying", () => {
  const delegateStart = view.indexOf("private final class AppLifecycleDelegate");
  const appStart = view.indexOf("@main");
  const shutdownStart = model.indexOf("func shutdown() async -> Bool {");
  const shutdownEnd = model.indexOf("\n    private var preferredRecognitionLanguage", shutdownStart);
  const startStart = model.indexOf("func startRecording() async {");
  const startEnd = model.indexOf("\n    private func performStartRecording() async {", startStart);
  const stopStart = model.indexOf("func stopRecording() async {");
  const stopEnd = model.indexOf("\n    private func performStopRecording() async {", stopStart);
  const retryStart = model.indexOf("func retryFinalization() async {");
  const retryEnd = model.indexOf("\n    private func performRetryFinalization() async {", retryStart);
  const cancelStart = model.indexOf("func cancelTerminationPreparation() {");
  const cancelEnd = model.indexOf("\n    private var preferredRecognitionLanguage", cancelStart);

  assert.notEqual(delegateStart, -1, "missing AppKit lifecycle delegate");
  assert.ok(appStart > delegateStart, "lifecycle delegate must precede the app declaration");
  assert.notEqual(shutdownStart, -1, "shutdown must return a termination decision");
  assert.ok(shutdownEnd > shutdownStart, "missing shutdown boundary");
  assert.notEqual(startStart, -1, "missing tracked recording start");
  assert.ok(startEnd > startStart, "missing start implementation boundary");
  assert.notEqual(stopStart, -1, "missing tracked recording stop");
  assert.ok(stopEnd > stopStart, "missing stop implementation boundary");
  assert.notEqual(retryStart, -1, "missing tracked finalization retry");
  assert.ok(retryEnd > retryStart, "missing retry implementation boundary");
  assert.notEqual(cancelStart, -1, "missing termination cancellation");
  assert.ok(cancelEnd > cancelStart, "missing termination cancellation boundary");

  const delegateSource = view.slice(delegateStart, appStart);
  const delegate = scanner.swiftCodeOnly(delegateSource);
  const appScene = scanner.swiftCodeOnly(view.slice(appStart, view.indexOf("private struct RootView")));
  const shutdown = scanner.swiftCodeOnly(model.slice(shutdownStart, shutdownEnd));
  const trackedStart = scanner.swiftCodeOnly(model.slice(startStart, startEnd));
  const trackedStop = scanner.swiftCodeOnly(model.slice(stopStart, stopEnd));
  const trackedRetry = scanner.swiftCodeOnly(model.slice(retryStart, retryEnd));
  const cancellation = scanner.swiftCodeOnly(model.slice(cancelStart, cancelEnd));

  assert.match(appScene, /@NSApplicationDelegateAdaptor\(AppLifecycleDelegate\.self\) private var lifecycleDelegate/);
  assert.match(appScene, /RootView\(model: lifecycleDelegate\.model\)/);
  assert.match(appScene, /SettingsView\(model: lifecycleDelegate\.model\)/);
  assert.match(appScene, /RefreshMeetingsCommand\(model: lifecycleDelegate\.model\)/);
  assert.match(appScene, /private struct RefreshMeetingsCommand: View \{[\s\S]*@ObservedObject var model: AppModel/);
  assert.doesNotMatch(appScene, /willTerminateNotification|@StateObject[^\n]*AppModel/);

  assert.match(delegate, /private static let terminationDeadline: Duration = \.seconds\(110\)/);
  assert.match(delegate, /func applicationShouldTerminate\(_ sender: NSApplication\) -> NSApplication\.TerminateReply/);
  assert.match(delegate, /guard terminationID == nil else \{ return \.terminateLater \}/);
  assert.match(delegate, /Task\.sleep\(for: Self\.terminationDeadline\)/);
  assert.match(delegate, /self\.model\.cancelTerminationPreparation\(\)/);
  assert.match(delegate, /self\.completeTermination\(false, sender: sender, id: id\)/);
  assert.match(delegate, /return \.terminateLater/);
  const shutdownAwait = delegate.indexOf("let shouldTerminate = await self.model.shutdown()");
  assert.ok(shutdownAwait >= 0);
  assert.ok(delegate.indexOf("self.completeTermination(shouldTerminate", shutdownAwait) > shutdownAwait);
  const terminationReplyCall = ["sender.", "rep", "ly(toApplicationShouldTerminate: shouldTerminate)"].join("");
  assert.equal(delegate.split(terminationReplyCall).length - 1, 1);

  assert.match(model, /private var recordingStartTask: Task<Void, Never>\?/);
  assert.match(model, /private var recordingStopTask: Task<Void, Never>\?/);
  assert.match(model, /private var recordingRetryTask: Task<Void, Never>\?/);
  assert.match(model, /private var shutdownTask: Task<Bool, Never>\?/);
  assert.match(model, /private var terminationRequested = false/);
  assert.match(model, /&& !terminationRequested/);
  assert.match(trackedStart, /if let recordingStartTask[\s\S]*await recordingStartTask\.value/);
  assert.match(trackedStart, /recordingStartTask = task[\s\S]*await task\.value[\s\S]*recordingStartTask = nil/);
  assert.match(trackedStop, /if let recordingStopTask[\s\S]*await recordingStopTask\.value/);
  assert.match(trackedStop, /recordingStopTask = task[\s\S]*await task\.value[\s\S]*recordingStopTask = nil/);
  assert.match(trackedRetry, /if let recordingRetryTask[\s\S]*await recordingRetryTask\.value/);
  assert.match(trackedRetry, /guard !terminationRequested, recordingPhase == \.recoveryRequired/);
  assert.match(trackedRetry, /recordingRetryTask = task[\s\S]*await task\.value[\s\S]*recordingRetryTask = nil/);

  const orderedShutdown = [
    "terminationRequested = true",
    "await startTask.value",
    "await stopTask.value",
    "await retryTask.value",
    "await self.stopRecording()",
    "let coordinatorState = await self.coordinator.state",
    "guard self.recordingPhase == .idle, coordinatorState == .idle",
    "speechPreparationTask?.cancel()",
    "realtimeEventTask?.cancel()",
    "recordingTimerTask?.cancel()",
    "captureStallTask?.cancel()",
    "frameTask?.cancel()",
  ];
  let prior = -1;
  for (const expression of orderedShutdown) {
    const index = shutdown.indexOf(expression);
    assert.ok(index > prior, `shutdown ordering is missing or invalid: ${expression}`);
    prior = index;
  }
  assert.ok(shutdown.lastIndexOf("return true") > prior);
  assert.match(shutdown, /let coordinatorState = await self\.coordinator\.state[\s\S]{0,180}if Task\.isCancelled \{[\s\S]{0,100}return false[\s\S]{0,120}guard self\.recordingPhase == \.idle/);
  assert.match(shutdown, /guard self\.recordingPhase == \.idle, coordinatorState == \.idle else \{[\s\S]{0,140}return false/);
  assert.doesNotMatch(shutdown, /coordinator\.close\(\)|api\.shutdown\(\)/);
  assert.match(cancellation, /shutdownTask\?\.cancel\(\)[\s\S]{0,100}terminationRequested = false/);
  const nestedCommentedReply = ["/* outer", "/* inner */", terminationReplyCall, "*/"].join("\n");
  const rawStringifiedReply = ['let value = #"""', '"""', terminationReplyCall, '"""#'].join("\n");
  assert.ok(!scanner.swiftCodeOnly(nestedCommentedReply).includes(terminationReplyCall));
  assert.ok(!scanner.swiftCodeOnly(rawStringifiedReply).includes(terminationReplyCall));
});

test("new windows preserve an established connection during recording", () => {
  const connectStart = model.indexOf("func connect() async {");
  const connectEnd = model.indexOf("\n    func selectMeeting", connectStart);
  assert.notEqual(connectStart, -1, "missing connect");
  assert.ok(connectEnd > connectStart, "missing connect boundary");
  const connect = model.slice(connectStart, connectEnd);

  const establishedGuard = connect.indexOf("guard phase != .ready else { return }");
  const phaseReset = connect.indexOf("phase = .connecting");
  const statusRead = connect.indexOf("api.recordingStatus(socketID: realtime.clientID)");
  assert.ok(establishedGuard >= 0, "an established shared model must ignore repeated setup");
  assert.ok(phaseReset > establishedGuard, "the guard must preserve the ready UI state");
  assert.ok(statusRead > establishedGuard, "the guard must not re-adopt the active recording claim");
});
