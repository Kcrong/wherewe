import AppKit
import MeetingTranscriberCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private enum NativeLayoutMetrics {
    static let setupPaneMinimumHeight: CGFloat = 260
    static let setupPaneIdealHeight: CGFloat = 440
    static let workspaceMinimumHeight: CGFloat = 280
}

@main
struct MeetingTranscriberApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Wherewe") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 700)
                .task { await model.connect() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.shutdown()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Meetings") {
                    Task { await model.refreshMeetings() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.phase != .ready)
            }
        }
    }
}

private struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 8) {
                TextField("Search meetings", text: $model.meetingSearchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("meeting-search")
                List(model.filteredMeetings, selection: meetingSelection) { meeting in
                    MeetingRow(
                        meeting: meeting,
                        isRecording: model.recordingMeetingID == meeting.id
                    )
                    .tag(meeting.id)
                }
                .overlay {
                    if model.phase == .ready && model.filteredMeetings.isEmpty {
                        EmptyStateView(
                            title: model.meetings.isEmpty ? "No Meetings" : "No Matches",
                            systemImage: "waveform",
                            message: model.meetings.isEmpty
                                ? "Create a meeting to begin recording."
                                : "No meeting titles match your search.",
                            compact: true
                        )
                    }
                }
            }
            .safeAreaPadding(.top)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
            .navigationTitle("Meetings")
            .toolbar {
                Button {
                    Task { await model.openSettings() }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .disabled(model.recordingPhase != .idle)
                .accessibilityIdentifier("open-settings")

                Button {
                    model.showingNewMeeting = true
                } label: {
                    Label("New Meeting", systemImage: "plus")
                }
                .disabled(model.recordingPhase != .idle)
                .accessibilityIdentifier("new-meeting")
            }
        } detail: {
            detail
                .safeAreaPadding(.top)
        }
        .task(id: model.selectedMeetingID) {
            await model.loadSelectedMeeting()
        }
        .sheet(isPresented: $model.showingNewMeeting) {
            NewMeetingView(model: model)
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView(model: model)
        }
        .preferredColorScheme(preferredColorScheme)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.phase {
        case .connecting:
            ProgressView("Starting Wherewe…")
                .controlSize(.large)
                .accessibilityIdentifier("native-service-connecting")
        case .setupRequired:
            EmptyStateView(
                title: "Setup Required",
                systemImage: "gearshape.2",
                message: "Configure Apple Speech, Apple Translation, and local storage before using the app.",
                actionTitle: "Open Settings",
                action: { Task { await model.openSettings() } }
            )
            .accessibilityIdentifier("setup-required")
        case .ready:
            if let meeting = model.selectedMeeting {
                MeetingDetailView(model: model, meeting: meeting)
            } else {
                EmptyStateView(
                    title: "Select a Meeting",
                    systemImage: "sidebar.left",
                    message: "Choose a meeting from the sidebar or create one and start recording.",
                    actionTitle: model.meetings.isEmpty ? "Create and Record" : nil,
                    action: model.meetings.isEmpty
                        ? { Task { await model.startRecordingWithoutMeeting() } }
                        : nil
                )
            }
        case let .failed(message):
            EmptyStateView(
                title: "Wherewe Is Unavailable",
                systemImage: "exclamationmark.triangle",
                message: message,
                actionTitle: "Retry",
                action: { Task { await model.connect() } }
            )
            .accessibilityIdentifier("native-service-error")
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var meetingSelection: Binding<Int?> {
        Binding(
            get: { model.selectedMeetingID },
            set: { model.selectMeeting($0) }
        )
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Text(model.settingsDocument?.configured == true ? "Settings" : "Set Up Wherewe")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("Appearance")
                    .foregroundStyle(.secondary)
                Picker("Appearance", selection: $model.theme) {
                    Text("System").tag(NativePreferences.Theme.system)
                    Text("Light").tag(NativePreferences.Theme.light)
                    Text("Dark").tag(NativePreferences.Theme.dark)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 108)
                if model.settingsDocument?.configured == true {
                    Button("Done") { model.showingSettings = false }
                }
            }

            if model.settingsDraft == nil {
                ProgressView("Loading settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView {
                    SpeechSettingsView(model: model)
                        .tabItem { Label("Transcription", systemImage: "waveform") }
                    TranslationSettingsView(model: model)
                        .tabItem { Label("Translation", systemImage: "character.book.closed") }
                    StorageSettingsView(model: model)
                        .tabItem { Label("Storage", systemImage: "externaldrive") }
                }
                .frame(minHeight: 440)
            }

            if let error = model.settingsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Text("Audio and language processing stay on this Mac through Apple system frameworks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.settingsInProgress { ProgressView().controlSize(.small) }
                Button("Save Settings") {
                    Task { await model.saveSettings() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.settingsInProgress || model.settingsDraft == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 600)
        .interactiveDismissDisabled(
            model.settingsInProgress || model.settingsDocument?.configured != true
        )
    }
}

private struct SettingsPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 720, alignment: .topLeading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private extension View {
    func settingsFieldFrame() -> some View {
        frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
    }

    func settingsLabelFrame() -> some View {
        frame(minWidth: 140, alignment: .trailing)
            .foregroundStyle(.secondary)
    }
}

private struct SpeechSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Apple Speech") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("Provider").settingsLabelFrame()
                            Text("Apple Speech").settingsFieldFrame()
                        }
                        GridRow {
                            Text("Model").settingsLabelFrame()
                            Text("System").settingsFieldFrame()
                        }
                        GridRow {
                            Text("Result priority").settingsLabelFrame()
                            Picker("Result priority", selection: modeBinding) {
                                Text("Real-time priority").tag("live")
                                Text("Final accuracy priority").tag("accurate")
                            }
                            .labelsHidden()
                            .settingsFieldFrame()
                        }
                        GridRow {
                            Text("Details").settingsLabelFrame()
                            Toggle("Show alternatives and confidence", isOn: detailsBinding)
                                .settingsFieldFrame()
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Availability") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let provider = appleProvider {
                            Label(
                                provider.available ? "Apple Speech is available" : "Apple Speech is unavailable",
                                systemImage: provider.available ? "checkmark.circle" : "exclamationmark.triangle"
                            )
                            .foregroundStyle(provider.available ? Color.green : Color.secondary)
                            if let reason = provider.reason {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView("Checking Apple Speech…")
                        }
                        Text("Speech language assets are installed by macOS. Wherewe only checks whether the English assets are ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Check English Speech Assets") {
                                Task { await model.prepareAppleSpeech() }
                            }
                            .disabled(model.settingsInProgress)
                            Button("Open Language & Region…") {
                                Task { await model.openAppleTranslationSettings() }
                            }
                            if let message = model.transcriptionCatalogue?.progress.message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var appleProvider: LocalProviderDescriptor? {
        model.transcriptionCatalogue?.localProviders.first { $0.id == "apple" }
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { model.settingsDraft?.transcription.local.apple?.mode ?? "live" },
            set: { model.setAppleSpeechMode($0) }
        )
    }

    private var detailsBinding: Binding<Bool> {
        Binding(
            get: { model.settingsDraft?.transcription.local.apple?.showDetails ?? false },
            set: { model.setAppleSpeechDetails($0) }
        )
    }
}

private struct TranslationSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Apple Translation") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Provider") { Text("Apple Translation") }
                        Text("Language packs are managed by macOS. Install missing packs in Language & Region, then refresh their status here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Refresh") { Task { await model.loadTranslationLanguages() } }
                            Button("Install Language Packs…") {
                                Task { await model.openAppleTranslationSettings() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let status = model.translationLanguagesStatus {
                    GroupBox("Languages") {
                        VStack(spacing: 8) {
                            ForEach(status.languages) { language in
                                HStack {
                                    Text(language.label)
                                    Spacer()
                                    Label(
                                        language.installed ? "Installed" : language.status,
                                        systemImage: language.installed ? "checkmark.circle" : "arrow.down.circle"
                                    )
                                    .foregroundStyle(language.installed ? Color.green : Color.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ProgressView("Checking language packs…")
                }
            }
        }
        .task {
            if model.translationLanguagesStatus == nil {
                await model.loadTranslationLanguages()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.loadTranslationLanguages() }
        }
    }
}

private struct StorageSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Local storage") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("Database").settingsLabelFrame()
                            TextField("Database", text: binding(\.paths.database))
                                .settingsFieldFrame()
                        }
                        GridRow {
                            Text("Uploaded files").settingsLabelFrame()
                            TextField("Uploaded files", text: binding(\.paths.files))
                                .settingsFieldFrame()
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Paths must be absolute. Changing a path selects a new location; existing data is not moved automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<SettingsUpdateRequest, String>) -> Binding<String> {
        Binding(
            get: { model.settingsDraft?[keyPath: keyPath] ?? "" },
            set: { value in
                guard var draft = model.settingsDraft else { return }
                draft[keyPath: keyPath] = value
                model.settingsDraft = draft
            }
        )
    }
}

private struct MeetingRow: View {
    let meeting: MeetingSummary
    let isRecording: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(meeting.title).lineLimit(1)
                    if isRecording {
                        Text("REC")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.red)
                    }
                }
                if let createdAt = meeting.createdAt {
                    Text(createdAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: "waveform")
        }
        .accessibilityLabel("Meeting transcription: \(meeting.title)")
    }
}

private struct MeetingDetailView: View {
    @ObservedObject var model: AppModel
    let meeting: MeetingSummary

    var body: some View {
        VSplitView {
            ScrollView(.vertical) {
                meetingSetupContent
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(
                minHeight: NativeLayoutMetrics.setupPaneMinimumHeight,
                idealHeight: NativeLayoutMetrics.setupPaneIdealHeight
            )

            WorkspacePane(model: model)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(
                    minHeight: NativeLayoutMetrics.workspaceMinimumHeight,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.saveMeetingDetails() }
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .disabled(model.recordingPhase != .idle || model.meetingMutationInProgress)

                Button(role: .destructive) {
                    model.showingDeleteMeetingConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(model.recordingPhase != .idle || model.meetingMutationInProgress)
            }
        }
        .confirmationDialog(
            "Delete this meeting and its attached files?",
            isPresented: $model.showingDeleteMeetingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                Task { await model.deleteSelectedMeeting() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var meetingSetupContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Meeting title", text: $model.meetingTitleDraft)
                    .font(.title)
                    .fontWeight(.semibold)
                    .textFieldStyle(.plain)
                    .disabled(model.recordingPhase != .idle || model.meetingMutationInProgress)
                    .accessibilityIdentifier("meeting-title")
                Label("Meeting transcription", systemImage: "waveform")
                    .foregroundStyle(.secondary)
            }

            if let error = model.meetingMutationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            GroupBox("Meeting setup") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meeting context")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $model.meetingContextDraft)
                            .frame(minHeight: 52, maxHeight: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                            .disabled(model.recordingPhase != .idle || model.meetingMutationInProgress)
                            .accessibilityIdentifier("meeting-context")
                    }
                    Divider()
                    recordingControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Microphone").foregroundStyle(.secondary)
                    Picker("Microphone", selection: $model.selectedMicrophoneID) {
                        Text("None").tag(String?.none)
                        ForEach(model.audioDevices) { device in
                            Text(device.name).tag(Optional(device.uid))
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 220, idealWidth: 320, maxWidth: 420)
                    .disabled(selectionLocked)
                }

                GridRow {
                    Text("System audio input").foregroundStyle(.secondary)
                    Picker("System audio input", selection: $model.selectedSystemInputID) {
                        Text("None").tag(String?.none)
                        ForEach(model.audioDevices) { device in
                            Text(device.name).tag(Optional(device.uid))
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 220, idealWidth: 320, maxWidth: 420)
                    .disabled(selectionLocked)
                }

                GridRow {
                    Text("Recognition language").foregroundStyle(.secondary)
                    Picker("Recognition language", selection: $model.recognitionLanguage) {
                        Text("English").tag("en-US")
                        Text("한국어").tag("ko-KR")
                        Text("日本語").tag("ja-JP")
                        Text("中文").tag("zh-CN")
                    }
                    .labelsHidden()
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
                    .disabled(selectionLocked)
                }

                GridRow {
                    Text("Translate to").foregroundStyle(.secondary)
                    Picker("Translation target", selection: translationBinding) {
                        Text("English").tag("en")
                        Text("한국어").tag("ko")
                        Text("日本語").tag("ja")
                        Text("中文").tag("zh")
                    }
                    .labelsHidden()
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
                    .disabled(selectionLocked)
                }
            }

            HStack {
                Toggle("Mute microphone", isOn: $model.microphoneMuted)
                    .disabled(model.recordingPhase == .preparing || model.recordingPhase == .stopping)
                Spacer()
                Button("Refresh Inputs") { model.refreshAudioDevices() }
                    .disabled(selectionLocked)
            }

            HStack(spacing: 12) {
                switch model.recordingPhase {
                case .idle:
                    Button("Start Recording") {
                        Task { await model.startRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartRecording)
                    .accessibilityIdentifier("start-recording")
                    if !model.selectedTranscriptionReady {
                        Text("Prepare Apple Speech in Settings before recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .preparing:
                    ProgressView()
                        .controlSize(.small)
                    Text(model.awaitingRecordingPermission
                         ? "Waiting for microphone permission…"
                         : "Preparing Apple Speech and audio inputs…")
                case .recording:
                    Button("Stop Recording") {
                        Task { await model.stopRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("stop-recording")
                    if model.captureLive {
                        Label(recordingElapsedLabel, systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                            .fontWeight(.semibold)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(model.captureStartStalled
                             ? "No audio from the selected input yet"
                             : "Starting audio capture…")
                            .foregroundStyle(model.captureStartStalled ? .orange : .secondary)
                    }
                case .stopping:
                    ProgressView("Finalising recording…")
                case .recoveryRequired:
                    Button("Retry Finalisation") {
                        Task { await model.retryFinalization() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if model.recordingPhase == .recording, model.captureLive {
                captureLevelRow
            }
            if let error = model.recordingError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.audioDeliveryWarning {
                Label(
                    "Recording stopped, but final audio delivery was not confirmed.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    private var translationBinding: Binding<String> {
        Binding(
            get: { model.translationTarget },
            set: { target in
                model.translationTarget = target
                Task { await model.changeTranslationTarget(target) }
            }
        )
    }

    private var captureLevelRow: some View {
        HStack(spacing: 18) {
            ForEach(Array(model.captureChannelLabels.enumerated()), id: \.offset) { index, label in
                let muted = label == "Microphone" && model.microphoneMuted
                let level = model.captureLevels.indices.contains(index) ? model.captureLevels[index] : 0
                HStack(spacing: 6) {
                    Image(systemName: label == "Microphone" ? (muted ? "mic.slash" : "mic") : "speaker.wave.2")
                    Text(muted ? "\(label) (muted)" : label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Gauge(value: muted ? 0 : level) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(level > 0.9 ? .orange : .green)
                        .frame(width: 90)
                }
            }
        }
        .accessibilityIdentifier("capture-levels")
    }

    private var recordingElapsedLabel: String {
        String(
            format: "Recording %02d:%02d",
            model.recordingElapsedSeconds / 60,
            model.recordingElapsedSeconds % 60
        )
    }

    private var selectionLocked: Bool {
        model.recordingPhase != .idle
    }
}

private struct NewMeetingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Meeting")
                .font(.title)
                .fontWeight(.semibold)
            TextField("Meeting title", text: $model.newMeetingTitle)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("new-meeting-title")

            if let error = model.meetingMutationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.showingNewMeeting = false }
                Button("Create Meeting") {
                    Task { await model.createMeeting() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.meetingMutationInProgress)
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled(model.meetingMutationInProgress)
    }
}

private struct WorkspacePane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Workspace", selection: $model.workspaceTab) {
                Text("Transcript").tag(AppModel.WorkspaceTab.transcript)
                Text("Files").tag(AppModel.WorkspaceTab.files)
                Text("Glossary").tag(AppModel.WorkspaceTab.glossary)
                Text("Export").tag(AppModel.WorkspaceTab.export)
            }
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("workspace-tabs")

            if let error = model.workspaceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                switch model.workspaceTab {
                case .transcript: TranscriptPane(model: model)
                case .files: FilesPane(model: model)
                case .glossary: GlossaryPane(model: model)
                case .export: ExportPane(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $model.documentPreview) { preview in
            DocumentPreviewView(preview: preview)
        }
    }
}

private struct TranscriptPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Transcript").font(.headline)
                Spacer()
                Picker("Transcript view", selection: $model.transcriptView) {
                    Text("Edited").tag(NativePreferences.TranscriptView.edited)
                    Text("Raw").tag(NativePreferences.TranscriptView.raw)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.visibleTranscriptText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.visibleTranscriptText.isEmpty)
            }
            TextField("Search transcript", text: $model.transcriptSearchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("transcript-search")

            if filteredItems.isEmpty {
                EmptyStateView(
                    title: model.transcriptSearchText.isEmpty ? "No Transcript Yet" : "No Matches",
                    systemImage: model.transcriptSearchText.isEmpty ? "waveform" : "magnifyingglass",
                    message: model.transcriptSearchText.isEmpty
                        ? "Transcript lines will appear after recording starts."
                        : "No transcript lines match your search.",
                    compact: true
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredItems) { item in
                            if isEditing(item) {
                                SegmentEditor(model: model)
                                    .id(item.id)
                            } else {
                                TranscriptItemView(model: model, item: item, dualChannel: dualChannel)
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func isEditing(_ item: VisibleTranscriptItem) -> Bool {
        switch item {
        case let .segment(segment):
            return model.editingSegmentID == segment.id
        case let .transcript(row):
            return row.databaseID == model.editingTranscriptID
        case .partial:
            return false
        }
    }

    private var filteredItems: [VisibleTranscriptItem] {
        let query = model.transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.transcriptItems }
        return model.transcriptItems.filter { item in
            switch item {
            case let .segment(segment):
                return segment.text.localizedCaseInsensitiveContains(query)
                    || (segment.translation?.localizedCaseInsensitiveContains(query) ?? false)
            case let .transcript(row), let .partial(row):
                return row.text.localizedCaseInsensitiveContains(query)
                    || (row.translation?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
    }

    private var dualChannel: Bool {
        model.transcriptItems.contains { item in
            switch item {
            case let .segment(segment): segment.channelID == "ch_1"
            case let .transcript(row), let .partial(row): row.channelID == "ch_1"
            }
        }
    }
}

private struct SegmentEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Edited transcript text", text: $model.editingSegmentText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.saveSegmentEdit() } }
            HStack {
                Button("Save") { Task { await model.saveSegmentEdit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.editingSegmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { model.cancelEditingSegment() }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TranscriptItemView: View {
    @ObservedObject var model: AppModel
    let item: VisibleTranscriptItem
    let dualChannel: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if dualChannel, let channelID {
                    Text(channelID == "ch_0" ? "Me" : "Other")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(channelID == "ch_0" ? Color.blue : Color.purple)
                }
                Text(text)
                    .textSelection(.enabled)
                    .italic(isPartial)
                    .foregroundStyle(isPartial ? Color.secondary : Color.primary)
                if isPartial {
                    Text("Live")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                switch item {
                case let .segment(segment):
                    Button("Edit") { model.beginEditingSegment(segment) }
                        .buttonStyle(.plain)
                case let .transcript(row):
                    if row.databaseID != nil {
                        Button("Edit") { model.beginEditingTranscript(row) }
                            .buttonStyle(.plain)
                    }
                case .partial:
                    EmptyView()
                }
                if translationStatus == .failed, let retryEntity {
                    Button("Retry Translation") {
                        Task {
                            await model.retryTranslation(
                                entityType: retryEntity.type,
                                entityID: retryEntity.id
                            )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if let corrections, !corrections.isEmpty {
                Text(corrections.map { "\($0.from) → \($0.to)" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let metadata {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            translationView
        }
        .padding(10)
        .background(Color.secondary.opacity(isPartial ? 0.05 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var translationView: some View {
        switch translationStatus {
        case .succeeded:
            if let translation, !translation.isEmpty {
                Text(translation)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .pending:
            Label("Translating", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Label("Translation failed", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case .idle, .notRequired:
            EmptyView()
        }
    }

    private var text: String {
        switch item {
        case let .segment(segment): segment.text
        case let .transcript(row), let .partial(row): row.text
        }
    }

    private var channelID: String? {
        switch item {
        case let .segment(segment): segment.channelID
        case let .transcript(row), let .partial(row): row.channelID
        }
    }

    private var isPartial: Bool {
        if case .partial = item { return true }
        return false
    }

    private var corrections: [SegmentCorrection]? {
        if case let .segment(segment) = item { return segment.corrections }
        return nil
    }

    private var translation: String? {
        switch item {
        case let .segment(segment): segment.translation
        case let .transcript(row), let .partial(row): row.translation
        }
    }

    private var translationStatus: TranslationStatus {
        switch item {
        case let .segment(segment): segment.translationStatus
        case let .transcript(row), let .partial(row): row.translationStatus
        }
    }

    private var retryEntity: (type: TranslationEntityType, id: Int)? {
        switch item {
        case let .segment(segment):
            return (.segment, segment.id)
        case let .transcript(row):
            guard let id = row.databaseID else { return nil }
            return (.transcript, id)
        case .partial:
            return nil
        }
    }

    private var metadata: String? {
        guard case let .transcript(row) = item else { return nil }
        var parts: [String] = []
        if let provider = row.transcriptionProvider { parts.append(provider.capitalized) }
        if let systemModel = row.transcriptionModel { parts.append(systemModel.capitalized) }
        if let mode = row.transcriptionMode { parts.append(mode.capitalized) }
        if let confidence = row.confidence {
            parts.append("Confidence: \(Int((confidence * 100).rounded()))%")
        }
        if let alternative = row.alternatives.first {
            parts.append("Alternative: \(alternative)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct FilesPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attached files").font(.headline)
                Spacer()
                Button {
                    chooseFiles()
                } label: {
                    Label("Add Files", systemImage: "paperclip")
                }
                .disabled(model.fileOperationInProgress)
            }

            if model.documents.isEmpty {
                EmptyStateView(
                    title: "No Attached Files",
                    systemImage: "paperclip",
                    message: "Add PDF, Markdown, text, HTML, or CSV files for this meeting.",
                    compact: true
                )
            } else {
                List(model.documents) { document in
                    HStack {
                        Button {
                            Task { await model.previewDocument(document) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(document.name).lineLimit(1)
                                Text("\(document.format.uppercased()) · \(ByteCountFormatter.string(fromByteCount: Int64(document.size), countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.deleteDocument(document) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(model.fileOperationInProgress)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .pdf,
            .plainText,
            .commaSeparatedText,
            .html,
            UTType(filenameExtension: "md") ?? .plainText,
        ]
        panel.begin { response in
            guard response == .OK else { return }
            Task { await model.uploadDocuments(panel.urls) }
        }
    }
}

private struct DocumentPreviewView: View {
    let preview: AppModel.DocumentPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.name)
                .font(.headline)
                .padding([.top, .horizontal])
            Divider()
            if preview.contentType?.lowercased().hasPrefix("application/pdf") == true {
                PDFDocumentView(data: preview.data)
            } else {
                ScrollView {
                    Text(String(decoding: preview.data, as: UTF8.self))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

private struct PDFDocumentView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
    }
}

private struct GlossaryPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Glossary").font(.headline)
                Spacer()
                Picker("Glossary language", selection: $model.glossaryLanguage) {
                    Text("English").tag("en")
                    Text("한국어").tag("ko")
                    Text("日本語").tag("ja")
                    Text("中文").tag("zh")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 108)
            }

            Text("Terms are stored locally for reference during transcript review.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("Add term") {
                HStack {
                    TextField("Phrase", text: $model.glossaryPhrase)
                    TextField("Display as (optional)", text: $model.glossaryDisplayAs)
                    Button {
                        Task { await model.addGlossaryEntry() }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.glossaryOperationInProgress
                            || model.glossaryPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }

            if model.globalGlossary.isEmpty && model.meetingGlossary.isEmpty {
                EmptyStateView(
                    title: "No Glossary Terms",
                    systemImage: "character.book.closed",
                    message: "Add names and technical phrases that are useful for this meeting.",
                    compact: true
                )
            } else {
                List {
                    Section("Global") {
                        ForEach(model.globalGlossary) { entry in
                            GlossaryEntryRow(model: model, entry: entry, editable: true)
                        }
                    }
                    Section("This meeting") {
                        ForEach(model.meetingGlossary) { entry in
                            GlossaryEntryRow(model: model, entry: entry, editable: false)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GlossaryEntryRow: View {
    @ObservedObject var model: AppModel
    let entry: GlossaryEntry
    let editable: Bool

    var body: some View {
        if editable && model.editingGlossaryID == entry.id {
            HStack {
                TextField("Phrase", text: $model.editingGlossaryPhrase)
                TextField("Display as", text: $model.editingGlossaryDisplayAs)
                Button("Save") { Task { await model.saveGlossaryEdit() } }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { model.cancelEditingGlossary() }
            }
        } else {
            HStack {
                Text(entry.phrase)
                if let displayAs = entry.displayAs, !displayAs.isEmpty {
                    Text("→ \(displayAs)").foregroundStyle(.secondary)
                }
                Spacer()
                if editable {
                    Button("Edit") { model.beginEditingGlossary(entry) }
                        .buttonStyle(.plain)
                }
                Button(role: .destructive) {
                    Task { await model.deleteGlossaryEntry(entry) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(model.glossaryOperationInProgress)
            }
        }
    }
}

private struct ExportPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.headline)
            Text("Create a local bundle containing meeting metadata, transcript, context, glossary, and attached files.")
                .foregroundStyle(.secondary)
            Button("Export Meeting") {
                Task { await model.exportSelectedMeeting() }
            }
            .buttonStyle(.borderedProminent)

            if let result = model.exportResult {
                GroupBox("Export complete") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.path)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("\(result.counts.transcripts) transcripts · \(result.counts.segments) edited segments · \(result.counts.documents) files · \(result.counts.glossary) glossary terms")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result.path, forType: .string)
                            }
                            Button("Show in Finder") {
                                Task { await model.revealExport() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 28 : 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(compact ? .headline : .title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text(message)
                .font(compact ? .callout : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(compact ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: compact ? 220 : 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(compact ? 12 : 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
