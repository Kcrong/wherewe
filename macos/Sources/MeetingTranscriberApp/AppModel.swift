import AppKit
import AVFoundation
import Foundation
import MeetingTranscriberCore

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case setupRequired
        case ready
        case failed(String)
    }

    enum RecordingPhase: Equatable {
        case idle
        case preparing
        case recording
        case stopping
        case recoveryRequired
    }

    enum WorkspaceTab: String, CaseIterable, Identifiable {
        case transcript
        case files
        case glossary
        case export

        var id: String { rawValue }
    }

    struct DocumentPreview: Identifiable {
        let id: Int
        let name: String
        let contentType: String?
        let data: Data
    }

    @Published private(set) var phase: Phase = .connecting
    @Published var theme: NativePreferences.Theme = .system {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    @Published private(set) var meetings: [MeetingSummary] = []
    @Published var meetingSearchText = ""
    @Published private var meetingSelection = MeetingSelectionState()
    @Published private(set) var meetingDetail: MeetingDetail?
    @Published var showingNewMeeting = false
    @Published var showingDeleteMeetingConfirmation = false
    @Published var newMeetingTitle = ""
    @Published var meetingTitleDraft = ""
    @Published var meetingContextDraft = ""
    @Published private(set) var meetingMutationInProgress = false
    @Published private(set) var meetingMutationError: String?

    @Published private(set) var transcriptItems: [VisibleTranscriptItem] = []
    @Published private var transcriptAutoFollowByMeetingID: [Int: TranscriptAutoFollowState] = [:]
    @Published var transcriptSearchText = ""
    @Published var transcriptView: NativePreferences.TranscriptView = .edited {
        didSet {
            UserDefaults.standard.set(transcriptView.rawValue, forKey: "transcriptView")
            Task { await refreshTranscriptItems() }
        }
    }
    @Published var editingSegmentID: Int?
    @Published var editingTranscriptID: Int?
    @Published var editingSegmentText = ""

    @Published var workspaceTab: WorkspaceTab = .transcript {
        didSet { UserDefaults.standard.set(workspaceTab.rawValue, forKey: "native.workspaceTab") }
    }
    @Published private(set) var workspaceError: String?

    @Published private(set) var documents: [UploadedDocument] = []
    @Published var documentPreview: DocumentPreview?
    @Published private(set) var fileOperationInProgress = false

    @Published var glossaryLanguage = "en" {
        didSet {
            persist(glossaryLanguage, key: "sel.glossaryLang")
            Task { await loadGlossary() }
        }
    }
    @Published private(set) var globalGlossary: [GlossaryEntry] = []
    @Published private(set) var meetingGlossary: [GlossaryEntry] = []
    @Published var glossaryPhrase = ""
    @Published var glossaryDisplayAs = ""
    @Published var editingGlossaryID: Int?
    @Published var editingGlossaryPhrase = ""
    @Published var editingGlossaryDisplayAs = ""
    @Published private(set) var glossaryOperationInProgress = false

    @Published private(set) var exportResult: MeetingExportResponse?

    @Published var settingsDraft: SettingsUpdateRequest?
    @Published private(set) var settingsDocument: SettingsDocument?
    @Published private(set) var settingsETag: String?
    @Published private(set) var transcriptionCatalogue: TranscriptionCatalogueResponse?
    @Published private(set) var transcriptionCatalogueLanguage: String?
    @Published private(set) var translationLanguagesStatus: TranslationLanguagesResponse?
    @Published private(set) var settingsInProgress = false
    @Published private(set) var databaseTransitionInProgress = false
    @Published private(set) var speechPreparationInProgress = false
    @Published private(set) var settingsError: String?

    @Published private(set) var audioDevices: [AudioInputDevice] = []
    @Published private(set) var recordingPhase: RecordingPhase = .idle
    @Published private(set) var recordingMeetingID: Int?
    @Published private(set) var recordingElapsedSeconds = 0
    @Published private(set) var captureLive = false
    @Published private(set) var captureStartStalled = false
    @Published private(set) var captureLevels: [Double] = []
    @Published private(set) var captureChannelLabels: [String] = []
    @Published private(set) var awaitingRecordingPermission = false
    @Published private(set) var recordingError: String?
    @Published private(set) var audioDeliveryWarning = false

    @Published var selectedMicrophoneID: String? {
        didSet { persist(selectedMicrophoneID, key: "sel.mic") }
    }
    @Published var selectedSystemInputID: String? {
        didSet { persist(selectedSystemInputID, key: "sel.sys") }
    }
    @Published var microphoneMuted = false {
        didSet {
            UserDefaults.standard.set(microphoneMuted ? "1" : "0", forKey: "mic.muted")
            Task { await capture.setMicrophoneMuted(microphoneMuted) }
        }
    }
    @Published var recognitionLanguage = "en-US" {
        didSet {
            transcriptionCatalogue = nil
            transcriptionCatalogueLanguage = nil
            guard !restoringMeetingValues else { return }
            persist(recognitionLanguage, key: "sel.lang")
            let language = recognitionLanguage
            Task { await refreshTranscriptionReadiness(for: language) }
        }
    }
    @Published var translationTarget = "ko" {
        didSet {
            if !restoringMeetingValues { persist(translationTarget, key: "sel.translate") }
        }
    }

    private let api: NativeService
    private let realtime: NativeRealtimeClient
    private let coordinator: RecordingCoordinator
    private let capture: CoreAudioCaptureSession
    private var transcriptStore = TranscriptStore()
    private var transcriptEditOperation = TranscriptEditOperationTracker()

    private var frameTask: Task<Void, Never>?
    private var realtimeEventTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private var captureStallTask: Task<Void, Never>?
    private var speechPreparationTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStopTask: Task<Void, Never>?
    private var recordingRetryTask: Task<Void, Never>?
    private var preserveRecordingErrorOnNextStop = false
    private var shutdownTask: Task<Bool, Never>?
    private var terminationRequested = false
    private var levelMeter: CaptureLevelMeter?
    private var meetingLoadGeneration = 0
    private var exportRequestScope = MeetingExportRequestScope()
    private var restoringMeetingValues = false
    private var suppressDisconnectRecovery = false
    private var initialSetupCompletionPending = false
    private var completedDrainTokens = Set<UUID>()
    private var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private static let captureStallSeconds = 3.0
    private static var recordingPermissionUndecided: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    init() {
        let service = NativeService(configuration: .live())
        let realtime = NativeRealtimeClient(service: service)
        let capture = CoreAudioCaptureSession()
        self.api = service
        self.realtime = realtime
        self.capture = capture
        self.coordinator = RecordingCoordinator(api: service, realtime: realtime)

        self.selectedMicrophoneID = UserDefaults.standard.string(forKey: "sel.mic")
        self.selectedSystemInputID = UserDefaults.standard.string(forKey: "sel.sys")
        self.microphoneMuted = UserDefaults.standard.string(forKey: "mic.muted") == "1"
        self.theme = NativePreferences.Theme(
            rawValue: UserDefaults.standard.string(forKey: "theme") ?? "system"
        ) ?? .system
        self.workspaceTab = WorkspaceTab(
            rawValue: UserDefaults.standard.string(forKey: "native.workspaceTab") ?? ""
        ) ?? .transcript
        self.recognitionLanguage = Self.allowedPreference(
            key: "sel.lang",
            allowed: ["en-US", "ko-KR", "ja-JP", "zh-CN"],
            fallback: "en-US"
        )
        self.translationTarget = Self.allowedPreference(
            key: "sel.translate",
            allowed: ["en", "ko", "ja", "zh"],
            fallback: "ko"
        )
        self.glossaryLanguage = Self.allowedPreference(
            key: "sel.glossaryLang",
            allowed: ["en", "ko", "ja", "zh"],
            fallback: "en"
        )
        self.transcriptView = UserDefaults.standard.string(forKey: "transcriptView") == "raw"
            ? .raw
            : .edited

        startFramePump()
        startRealtimeEventPump()
    }

    var selectedMeetingID: Int? { meetingSelection.selectedID }

    var selectedMeetingIsLoaded: Bool { loadedSelectedMeetingID != nil }

    private var loadedSelectedMeetingID: Int? { meetingSelection.mutationID }

    var selectedMeeting: MeetingSummary? {
        guard let selectedMeetingID else { return nil }
        return meetings.first { $0.id == selectedMeetingID }
    }

    var filteredMeetings: [MeetingSummary] {
        let query = meetingSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings }
        return meetings.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var visibleTranscriptText: String {
        let dualChannel = transcriptItems.contains { item in
            switch item {
            case let .segment(segment): segment.channelID == "ch_1"
            case let .transcript(row), let .partial(row): row.channelID == "ch_1"
            }
        }
        return transcriptItems.compactMap { item -> String? in
            let channelID: String?
            let text: String
            switch item {
            case let .segment(segment):
                channelID = segment.channelID
                text = segment.text
            case let .transcript(row):
                channelID = row.channelID
                text = row.text
            case .partial:
                return nil
            }
            guard dualChannel, let channelID else { return text }
            return "[\(channelID == "ch_0" ? "Me" : "Other")] \(text)"
        }.joined(separator: "\n")
    }

    func shouldAutoFollowTranscript(meetingID: Int?, searchIsActive: Bool) -> Bool {
        guard let meetingID else { return !searchIsActive }
        return (transcriptAutoFollowByMeetingID[meetingID] ?? TranscriptAutoFollowState())
            .shouldFollow(searchIsActive: searchIsActive)
    }

    func recordTranscriptUserScroll(isNearBottom: Bool, meetingID: Int?) {
        guard let meetingID else { return }
        var state = transcriptAutoFollowByMeetingID[meetingID] ?? TranscriptAutoFollowState()
        state.recordUserScroll(isNearBottom: isNearBottom)
        transcriptAutoFollowByMeetingID[meetingID] = state
    }

    var canStartRecording: Bool {
        phase == .ready
            && recordingPhase == .idle
            && !databaseTransitionInProgress
            && !terminationRequested
            && loadedSelectedMeetingID != nil
            && (selectedMicrophone != nil || selectedSystemInput != nil)
            && selectedTranscriptionReady
    }

    var selectedTranscriptionReady: Bool {
        guard transcriptionCatalogueLanguage == recognitionLanguage,
              let provider = transcriptionCatalogue?.localProviders.first(where: { $0.id == "apple" }) else {
            return false
        }
        return provider.available && provider.ready
    }

    func connect() async {
        guard phase != .ready else { return }
        phase = .connecting
        do {
            let health = try await api.health()
            if health.setupRequired {
                initialSetupCompletionPending = true
                meetings = []
                phase = .setupRequired
                return
            }

            try await coordinator.connect()
            do { try loadAudioDevices() }
            catch { recordingError = error.localizedDescription }
            let catalogueLanguage = recognitionLanguage
            let catalogue = try await api.transcriptionCatalogue(language: catalogueLanguage)
            applyTranscriptionCatalogue(catalogue, for: catalogueLanguage)
            meetings = try await api.meetings()

            let status = try await api.recordingStatus(socketID: realtime.clientID)
            if status.selectionLocked,
               let meetingID = status.recordingMeetingID,
               let generation = status.recordingGeneration,
               let socketID = realtime.clientID {
                let claim = RecordingClaim(
                    meetingID: meetingID,
                    generation: generation,
                    socketID: socketID,
                    sampleRate: 48_000,
                    channelCount: 1
                )
                try await coordinator.adoptRecoveryClaim(claim)
                recordingPhase = .recoveryRequired
                recordingMeetingID = meetingID
                recordingError = "A previous recording was not finalised. Retry finalisation before starting again."
                updateMeetingSelection(meetingID)
            }
            if selectedMeetingID == nil {
                updateMeetingSelection(meetings.first?.id)
            }
            initialSetupCompletionPending = false
            phase = .ready
        } catch {
            meetings = []
            phase = .failed(error.localizedDescription)
        }
    }

    func selectMeeting(_ id: Int?) {
        guard recordingPhase == .idle, !databaseTransitionInProgress else { return }
        updateMeetingSelection(id)
    }

    private func updateMeetingSelection(_ id: Int?) {
        var nextSelection = meetingSelection
        guard nextSelection.select(id) else { return }
        meetingSelection = nextSelection
        _ = exportRequestScope.selectMeeting(id)
        meetingLoadGeneration += 1
        clearMeetingDependentState()
    }

    private func clearMeetingDependentState() {
        meetingDetail = nil
        meetingTitleDraft = ""
        meetingContextDraft = ""
        transcriptItems = []
        transcriptSearchText = ""
        cancelEditingSegment()
        documents = []
        documentPreview = nil
        globalGlossary = []
        meetingGlossary = []
        exportResult = nil
        showingDeleteMeetingConfirmation = false
        meetingMutationError = nil
        workspaceError = nil
    }

    func refreshMeetings() async {
        guard phase == .ready, !databaseTransitionInProgress else { return }
        do {
            meetings = try await api.meetings()
            if let selectedMeetingID,
               !meetings.contains(where: { $0.id == selectedMeetingID }) {
                updateMeetingSelection(meetings.first?.id)
            }
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func loadSelectedMeeting() async {
        meetingLoadGeneration += 1
        let generation = meetingLoadGeneration
        var loadingSelection = meetingSelection
        let meetingID = loadingSelection.beginLoading()
        meetingSelection = loadingSelection
        clearMeetingDependentState()
        guard let meetingID else { return }
        do {
            let detail = try await api.meeting(id: meetingID)
            guard generation == meetingLoadGeneration, selectedMeetingID == meetingID else { return }
            _ = try await api.activateMeeting(id: meetingID)
            guard generation == meetingLoadGeneration, selectedMeetingID == meetingID else { return }

            meetingDetail = detail
            meetingTitleDraft = detail.title
            meetingContextDraft = detail.context
            restoringMeetingValues = true
            recognitionLanguage = detail.language
            translationTarget = detail.translationTarget
            restoringMeetingValues = false
            await refreshTranscriptionReadiness(for: recognitionLanguage)
            guard generation == meetingLoadGeneration, selectedMeetingID == meetingID else { return }
            _ = await transcriptStore.activate(detail)
            await refreshTranscriptItems()
            await loadDocuments()
            await loadGlossary()
            guard generation == meetingLoadGeneration, selectedMeetingID == meetingID else { return }
            var loadedSelection = meetingSelection
            guard loadedSelection.finishLoading(meetingID) else { return }
            meetingSelection = loadedSelection
        } catch {
            guard generation == meetingLoadGeneration, selectedMeetingID == meetingID else { return }
            workspaceError = error.localizedDescription
        }
    }

    func startRecordingWithoutMeeting() async {
        guard recordingPhase == .idle,
              !meetingMutationInProgress,
              !databaseTransitionInProgress else { return }
        meetingMutationInProgress = true
        workspaceError = nil
        do {
            let response = try await api.createMeeting(CreateMeetingRequest(
                title: "Untitled Meeting",
                language: preferredRecognitionLanguage,
                translationTarget: preferredTranslationTarget
            ))
            meetingMutationInProgress = false
            await refreshMeetings()
            updateMeetingSelection(response.id)
            await loadSelectedMeeting()
            await startRecording()
        } catch {
            meetingMutationInProgress = false
            workspaceError = error.localizedDescription
        }
    }

    func createMeeting() async {
        guard recordingPhase == .idle,
              !meetingMutationInProgress,
              !databaseTransitionInProgress else { return }
        meetingMutationInProgress = true
        meetingMutationError = nil
        defer { meetingMutationInProgress = false }
        do {
            let title = newMeetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try await api.createMeeting(CreateMeetingRequest(
                title: title.isEmpty ? "Untitled Meeting" : title,
                language: preferredRecognitionLanguage,
                translationTarget: preferredTranslationTarget
            ))
            newMeetingTitle = ""
            showingNewMeeting = false
            await refreshMeetings()
            updateMeetingSelection(response.id)
        } catch {
            meetingMutationError = error.localizedDescription
        }
    }

    func saveMeetingDetails() async {
        guard let meetingID = loadedSelectedMeetingID,
              recordingPhase == .idle,
              !meetingMutationInProgress,
              !databaseTransitionInProgress else { return }
        let title = meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            meetingMutationError = "Meeting title cannot be empty."
            return
        }
        meetingMutationInProgress = true
        meetingMutationError = nil
        defer { meetingMutationInProgress = false }
        do {
            _ = try await api.updateMeeting(
                id: meetingID,
                request: UpdateMeetingRequest(title: title, context: meetingContextDraft)
            )
            await refreshMeetings()
            await loadSelectedMeeting()
        } catch {
            meetingMutationError = error.localizedDescription
        }
    }

    func deleteSelectedMeeting() async {
        guard let meetingID = loadedSelectedMeetingID,
              !meetingMutationInProgress,
              !databaseTransitionInProgress else { return }
        if recordingPhase == .recording { await stopRecording() }
        guard recordingPhase == .idle else {
            meetingMutationError = "Confirm recording finalisation before deleting this meeting."
            return
        }
        guard loadedSelectedMeetingID == meetingID else { return }
        meetingMutationInProgress = true
        meetingMutationError = nil
        defer { meetingMutationInProgress = false }
        do {
            _ = try await api.deleteMeeting(id: meetingID, socketID: realtime.clientID)
            if selectedMeetingID == meetingID {
                updateMeetingSelection(nil)
            }
            await refreshMeetings()
            if selectedMeetingID == nil {
                updateMeetingSelection(meetings.first?.id)
            }
        } catch {
            meetingMutationError = error.localizedDescription
        }
    }

    func changeTranslationTarget(_ target: String) async {
        guard let meetingID = loadedSelectedMeetingID,
              recordingPhase == .idle,
              !databaseTransitionInProgress else { return }
        do {
            _ = try await api.updateTranslationTarget(meetingID: meetingID, target: target)
            await resyncTranscriptState()
        } catch {
            workspaceError = error.localizedDescription
            if let meetingDetail { translationTarget = meetingDetail.translationTarget }
        }
    }

    func beginEditingSegment(_ segment: TranscriptSegment) {
        guard loadedSelectedMeetingID == segment.meetingID else { return }
        editingTranscriptID = nil
        editingSegmentID = segment.id
        editingSegmentText = segment.text
        transcriptEditOperation.begin()
    }

    func beginEditingTranscript(_ row: LiveTranscriptRow) {
        guard loadedSelectedMeetingID != nil, let transcriptID = row.databaseID else { return }
        editingSegmentID = nil
        editingTranscriptID = transcriptID
        editingSegmentText = row.text
        transcriptEditOperation.begin()
    }

    func cancelEditingSegment() {
        transcriptEditOperation.cancel()
        editingSegmentID = nil
        editingTranscriptID = nil
        editingSegmentText = ""
    }

    func saveSegmentEdit() async {
        guard let meetingID = loadedSelectedMeetingID,
              let editOperationID = transcriptEditOperation.activeID,
              !databaseTransitionInProgress else { return }
        let text = editingSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            if let segmentID = editingSegmentID {
                _ = try await api.editSegment(
                    meetingID: meetingID,
                    segmentID: segmentID,
                    text: text
                )
            } else if let transcriptID = editingTranscriptID {
                _ = try await api.editTranscript(
                    meetingID: meetingID,
                    transcriptID: transcriptID,
                    text: text
                )
            } else {
                return
            }
            if transcriptEditOperation.finish(editOperationID) {
                editingSegmentID = nil
                editingTranscriptID = nil
                editingSegmentText = ""
            }
            await resyncTranscriptState()
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func retryTranslation(entityType: TranslationEntityType, entityID: Int) async {
        guard let meetingID = loadedSelectedMeetingID, !databaseTransitionInProgress else { return }
        do {
            _ = try await api.retryTranslation(
                meetingID: meetingID,
                entityType: entityType,
                entityID: entityID
            )
            await resyncTranscriptState()
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func loadDocuments() async {
        guard let meetingID = selectedMeetingID else {
            documents = []
            return
        }
        do {
            let rows = try await api.documents(meetingID: meetingID)
            if selectedMeetingID == meetingID { documents = rows }
        } catch {
            if selectedMeetingID == meetingID { workspaceError = error.localizedDescription }
        }
    }

    @discardableResult
    func uploadDocuments(_ urls: [URL]) async -> [DocumentUploadResult] {
        guard let meetingID = loadedSelectedMeetingID,
              !fileOperationInProgress,
              !databaseTransitionInProgress else { return [] }
        fileOperationInProgress = true
        workspaceError = nil
        defer { fileOperationInProgress = false }

        let results = await api.uploadDocuments(meetingID: meetingID, urls: urls)
        guard loadedSelectedMeetingID == meetingID else { return results }

        let failures = results.filter { !$0.succeeded }
        if !failures.isEmpty {
            workspaceError = failures.map(\.statusMessage).joined(separator: "\n")
        }
        await loadDocuments()
        return results
    }

    func previewDocument(_ document: UploadedDocument) async {
        guard let meetingID = loadedSelectedMeetingID,
              documents.contains(where: { $0.id == document.id }),
              !fileOperationInProgress else { return }
        fileOperationInProgress = true
        workspaceError = nil
        defer { fileOperationInProgress = false }
        do {
            let content = try await api.documentContent(id: document.id)
            guard loadedSelectedMeetingID == meetingID,
                  documents.contains(where: { $0.id == document.id }) else { return }
            documentPreview = DocumentPreview(
                id: document.id,
                name: document.name,
                contentType: content.contentType,
                data: content.data
            )
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func deleteDocument(_ document: UploadedDocument) async {
        guard loadedSelectedMeetingID != nil,
              documents.contains(where: { $0.id == document.id }),
              !fileOperationInProgress,
              !databaseTransitionInProgress else { return }
        fileOperationInProgress = true
        workspaceError = nil
        defer { fileOperationInProgress = false }
        do {
            _ = try await api.deleteDocument(id: document.id)
            if documentPreview?.id == document.id { documentPreview = nil }
            await loadDocuments()
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func loadGlossary() async {
        guard let meetingID = selectedMeetingID else {
            globalGlossary = []
            meetingGlossary = []
            return
        }
        do {
            async let global = api.glossary(language: glossaryLanguage)
            async let local = api.meetingGlossary(meetingID: meetingID)
            let (globalRows, meetingRows) = try await (global, local)
            if selectedMeetingID == meetingID {
                globalGlossary = globalRows
                meetingGlossary = meetingRows.filter { $0.language == glossaryLanguage }
            }
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func addGlossaryEntry() async {
        guard !glossaryOperationInProgress, !databaseTransitionInProgress else { return }
        let phrase = glossaryPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        glossaryOperationInProgress = true
        workspaceError = nil
        defer { glossaryOperationInProgress = false }
        do {
            let display = glossaryDisplayAs.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await api.createGlossary(GlossaryMutationRequest(
                phrase: phrase,
                displayAs: display.isEmpty ? nil : display,
                language: glossaryLanguage
            ))
            glossaryPhrase = ""
            glossaryDisplayAs = ""
            await loadGlossary()
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func beginEditingGlossary(_ entry: GlossaryEntry) {
        guard entry.meetingID == nil else { return }
        editingGlossaryID = entry.id
        editingGlossaryPhrase = entry.phrase
        editingGlossaryDisplayAs = entry.displayAs ?? ""
    }

    func cancelEditingGlossary() {
        editingGlossaryID = nil
        editingGlossaryPhrase = ""
        editingGlossaryDisplayAs = ""
    }

    func saveGlossaryEdit() async {
        guard let id = editingGlossaryID,
              !glossaryOperationInProgress,
              !databaseTransitionInProgress else { return }
        let phrase = editingGlossaryPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        glossaryOperationInProgress = true
        workspaceError = nil
        defer { glossaryOperationInProgress = false }
        do {
            let display = editingGlossaryDisplayAs.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await api.updateGlossary(
                id: id,
                request: GlossaryMutationRequest(
                    phrase: phrase,
                    displayAs: display.isEmpty ? nil : display,
                    language: glossaryLanguage
                )
            )
            cancelEditingGlossary()
            await loadGlossary()
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func deleteGlossaryEntry(_ entry: GlossaryEntry) async {
        if let meetingID = entry.meetingID {
            guard loadedSelectedMeetingID == meetingID,
                  meetingGlossary.contains(where: { $0.id == entry.id }) else { return }
        }
        guard !glossaryOperationInProgress, !databaseTransitionInProgress else { return }
        glossaryOperationInProgress = true
        workspaceError = nil
        defer { glossaryOperationInProgress = false }
        do {
            _ = try await api.deleteGlossary(id: entry.id)
            await loadGlossary()
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func exportSelectedMeeting() async {
        guard let meetingID = loadedSelectedMeetingID,
              let request = exportRequestScope.begin(for: meetingID) else { return }
        exportResult = nil
        workspaceError = nil
        do {
            let result = try await api.exportMeeting(id: request.meetingID)
            guard loadedSelectedMeetingID == meetingID,
                  exportRequestScope.isCurrent(request) else { return }
            exportResult = result
        } catch {
            guard loadedSelectedMeetingID == meetingID,
                  exportRequestScope.isCurrent(request) else { return }
            workspaceError = error.localizedDescription
        }
    }

    func revealExport() async {
        guard let path = exportResult?.path else { return }
        do {
            _ = try await api.reveal(path: path)
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func loadSettings() async {
        guard !settingsInProgress else { return }
        settingsInProgress = true
        settingsError = nil
        defer { settingsInProgress = false }
        do {
            let catalogueLanguage = recognitionLanguage
            async let envelopeCall = api.settings()
            async let transcriptionCall = api.transcriptionCatalogue(language: catalogueLanguage)
            let (envelope, transcription) = try await (envelopeCall, transcriptionCall)
            settingsDocument = envelope.document
            settingsETag = envelope.etag
            settingsDraft = envelope.document.updateRequest
            applyTranscriptionCatalogue(transcription, for: catalogueLanguage)
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func setAppleSpeechMode(_ mode: String) {
        guard ["live", "accurate"].contains(mode), var draft = settingsDraft else { return }
        var apple = draft.transcription.local.apple ?? AppleSpeechSettings()
        apple.mode = mode
        draft.transcription.local.apple = apple
        settingsDraft = draft
    }

    func setAppleSpeechDetails(_ enabled: Bool) {
        guard var draft = settingsDraft else { return }
        var apple = draft.transcription.local.apple ?? AppleSpeechSettings()
        apple.showDetails = enabled
        draft.transcription.local.apple = apple
        settingsDraft = draft
    }

    private func applyTranscriptionCatalogue(
        _ catalogue: TranscriptionCatalogueResponse,
        for language: String
    ) {
        guard recognitionLanguage == language else { return }
        transcriptionCatalogue = catalogue
        transcriptionCatalogueLanguage = language
    }

    private func refreshTranscriptionReadiness(
        for language: String,
        reportToSettings: Bool = false
    ) async {
        do {
            let catalogue = try await api.transcriptionCatalogue(language: language)
            applyTranscriptionCatalogue(catalogue, for: language)
        } catch {
            guard recognitionLanguage == language else { return }
            if reportToSettings {
                settingsError = error.localizedDescription
            } else {
                recordingError = error.localizedDescription
            }
        }
    }

    func startAppleSpeechPreparation() {
        guard speechPreparationTask == nil, !settingsInProgress else { return }
        let language = recognitionLanguage
        speechPreparationTask = Task { [weak self] in
            await self?.prepareAppleSpeech(language: language)
        }
    }

    func cancelAppleSpeechPreparation() {
        speechPreparationTask?.cancel()
    }

    private func prepareAppleSpeech(language: String) async {
        guard !settingsInProgress else {
            speechPreparationTask = nil
            return
        }
        settingsInProgress = true
        speechPreparationInProgress = true
        settingsError = nil
        defer {
            speechPreparationInProgress = false
            settingsInProgress = false
            speechPreparationTask = nil
        }
        do {
            let catalogue = try await api.prepareTranscription(
                provider: "apple",
                model: "system",
                language: language
            )
            try Task.checkCancellation()
            if recognitionLanguage == language {
                applyTranscriptionCatalogue(catalogue, for: language)
            } else {
                await refreshTranscriptionReadiness(
                    for: recognitionLanguage,
                    reportToSettings: true
                )
            }
        } catch is CancellationError {
            await refreshTranscriptionReadiness(
                for: recognitionLanguage,
                reportToSettings: true
            )
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func loadTranslationLanguages() async {
        do {
            translationLanguagesStatus = try await api.translationLanguages()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func openAppleTranslationSettings() async {
        do {
            _ = try await api.openTranslationSettings()
            await loadTranslationLanguages()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    // Returns true only when first-run setup completed and the Settings window should close.
    func saveSettings() async -> Bool {
        guard var draft = settingsDraft,
              !settingsInProgress,
              !databaseTransitionInProgress else { return false }
        guard (draft.paths.database as NSString).isAbsolutePath,
              (draft.paths.files as NSString).isAbsolutePath else {
            settingsError = "Storage paths must be absolute."
            return false
        }

        draft.transcription.engine = "apple"
        draft.transcription.local.provider = "apple"
        draft.transcription.local.model = "system"
        draft.transcription.local.apple = draft.transcription.local.apple ?? AppleSpeechSettings()
        draft.translation.provider = "apple"
        if draft.user.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.user.name = "Wherewe User"
        }
        if draft.user.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.user.profile = "Uses on-device Apple transcription and translation."
        }

        let switchesDatabase = settingsDocument?.paths.database != draft.paths.database
        if switchesDatabase,
           meetingMutationInProgress || fileOperationInProgress || glossaryOperationInProgress {
            settingsError = "Wait for the current meeting operation to finish before changing databases."
            return false
        }

        settingsInProgress = true
        databaseTransitionInProgress = switchesDatabase
        settingsError = nil
        if switchesDatabase { clearDatabaseBackedState() }
        defer {
            databaseTransitionInProgress = false
            settingsInProgress = false
        }
        let completesInitialSetup = initialSetupCompletionPending || settingsDocument?.configured != true
        var databaseStateReloaded = false
        do {
            let envelope = try await api.updateSettings(draft, etag: settingsETag)
            settingsDocument = envelope.document
            settingsETag = envelope.etag
            settingsDraft = envelope.document.updateRequest
            if switchesDatabase {
                await reloadDatabaseBackedState()
                databaseStateReloaded = true
            }
            let catalogueLanguage = recognitionLanguage
            let catalogue = try await api.transcriptionCatalogue(language: catalogueLanguage)
            applyTranscriptionCatalogue(catalogue, for: catalogueLanguage)
            if completesInitialSetup {
                await connect()
                return phase == .ready
            }
        } catch {
            let message = error.localizedDescription
            if switchesDatabase, !databaseStateReloaded {
                await reloadDatabaseBackedState()
            }
            settingsError = message
        }
        return false
    }

    private func clearDatabaseBackedState() {
        updateMeetingSelection(nil)
        meetings = []
        meetingDetail = nil
        showingNewMeeting = false
        showingDeleteMeetingConfirmation = false
        newMeetingTitle = ""
        meetingTitleDraft = ""
        meetingContextDraft = ""
        meetingMutationError = nil
        meetingSearchText = ""

        transcriptStore = TranscriptStore()
        transcriptItems = []
        transcriptAutoFollowByMeetingID = [:]
        transcriptSearchText = ""
        cancelEditingSegment()

        documents = []
        documentPreview = nil
        globalGlossary = []
        meetingGlossary = []
        glossaryPhrase = ""
        glossaryDisplayAs = ""
        editingGlossaryID = nil
        editingGlossaryPhrase = ""
        editingGlossaryDisplayAs = ""
        exportResult = nil
        workspaceError = nil

        restoringMeetingValues = true
        recognitionLanguage = preferredRecognitionLanguage
        translationTarget = preferredTranslationTarget
        restoringMeetingValues = false
    }

    private func reloadDatabaseBackedState() async {
        do {
            meetings = try await api.meetings()
            updateMeetingSelection(meetings.first?.id)
            await loadSelectedMeeting()
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func refreshAudioDevices() {
        do {
            try loadAudioDevices()
            recordingError = nil
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func startRecording() async {
        if let recordingStartTask {
            await recordingStartTask.value
            return
        }
        guard canStartRecording else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStartRecording()
        }
        recordingStartTask = task
        await task.value
        recordingStartTask = nil
    }

    private func performStartRecording() async {
        guard canStartRecording, let meetingID = loadedSelectedMeetingID else { return }
        let microphone = selectedMicrophone
        let systemInput = selectedSystemInput
        let sameDevice = microphone?.uid == systemInput?.uid && microphone != nil
        let channelCount = microphone != nil && systemInput != nil && !sameDevice ? 2 : 1
        var startedClaim: RecordingClaim?

        recordingPhase = .preparing
        recordingError = nil
        audioDeliveryWarning = false
        do {
            try await persistMeetingDraft(meetingID: meetingID)
            let claim = try await coordinator.start(
                meetingID: meetingID,
                language: recognitionLanguage,
                translationTarget: translationTarget,
                channelCount: channelCount
            )
            startedClaim = claim
            await transcriptStore.beginRecording(meetingID: claim.meetingID, generation: claim.generation)
            recordingMeetingID = claim.meetingID
            armCaptureFeedback(
                labels: channelCount == 2
                    ? ["Microphone", "System audio"]
                    : [microphone != nil ? "Microphone" : "System audio"],
                sampleRate: claim.sampleRate
            )
            awaitingRecordingPermission = microphone != nil && Self.recordingPermissionUndecided
            let captureChannels = try await capture.start(
                microphone: microphone,
                systemInput: systemInput,
                microphoneMuted: microphoneMuted
            )
            awaitingRecordingPermission = false
            guard captureChannels == channelCount else { throw RecordingCoordinatorError.invalidState }
            recordingPhase = .recording
            watchForCaptureStall()
        } catch {
            awaitingRecordingPermission = false
            stopRecordingTimer()
            if let token = await capture.stop() { await waitUntilDrained(token) }
            if case .recording = await coordinator.state { _ = try? await coordinator.stop() }
            if let startedClaim {
                _ = await transcriptStore.endRecording(
                    meetingID: startedClaim.meetingID,
                    generation: startedClaim.generation
                )
            }
            recordingError = error.localizedDescription
            let needsRecovery = await coordinatorNeedsRecovery()
            recordingPhase = needsRecovery ? .recoveryRequired : .idle
            if !needsRecovery { recordingMeetingID = nil }
        }
    }

    func stopRecording() async {
        if let recordingStopTask {
            await recordingStopTask.value
            return
        }
        guard recordingPhase == .recording else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStopRecording()
        }
        recordingStopTask = task
        await task.value
        recordingStopTask = nil
    }

    private func performStopRecording() async {
        guard recordingPhase == .recording else { return }
        let preserveRecordingError = preserveRecordingErrorOnNextStop
        preserveRecordingErrorOnNextStop = false
        recordingPhase = .stopping
        stopRecordingTimer()
        if !preserveRecordingError { recordingError = nil }
        let activeClaim: RecordingClaim? = if case let .recording(claim) = await coordinator.state {
            claim
        } else {
            nil
        }

        if let token = await capture.stop() { await waitUntilDrained(token) }
        do {
            let outcome = try await coordinator.stop()
            audioDeliveryWarning = !outcome.audioDeliveryConfirmed
            if let activeClaim {
                _ = await transcriptStore.endRecording(
                    meetingID: activeClaim.meetingID,
                    generation: activeClaim.generation
                )
            }
            recordingPhase = .idle
            recordingMeetingID = nil
            await refreshMeetings()
            await loadSelectedMeeting()
        } catch {
            recordingError = error.localizedDescription
            recordingPhase = .recoveryRequired
        }
    }

    func retryFinalization() async {
        if let recordingRetryTask {
            await recordingRetryTask.value
            return
        }
        guard !terminationRequested, recordingPhase == .recoveryRequired else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRetryFinalization()
        }
        recordingRetryTask = task
        await task.value
        recordingRetryTask = nil
    }

    private func performRetryFinalization() async {
        guard recordingPhase == .recoveryRequired else { return }
        do {
            try await coordinator.connect()
            try await coordinator.retryFinalization()
            recordingError = nil
            recordingPhase = .idle
            recordingMeetingID = nil
            await refreshMeetings()
            await loadSelectedMeeting()
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func shutdown() async -> Bool {
        if let shutdownTask {
            return await shutdownTask.value
        }
        terminationRequested = true
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return true }
            if let startTask = self.recordingStartTask {
                await startTask.value
            }
            if Task.isCancelled {
                self.terminationRequested = false
                return false
            }
            if let stopTask = self.recordingStopTask {
                await stopTask.value
            }
            if Task.isCancelled {
                self.terminationRequested = false
                return false
            }
            if let retryTask = self.recordingRetryTask {
                await retryTask.value
            }
            if Task.isCancelled {
                self.terminationRequested = false
                return false
            }
            if self.recordingPhase == .recording {
                await self.stopRecording()
            }
            if Task.isCancelled {
                self.terminationRequested = false
                return false
            }
            let coordinatorState = await self.coordinator.state
            if Task.isCancelled {
                self.terminationRequested = false
                return false
            }
            guard self.recordingPhase == .idle, coordinatorState == .idle else {
                self.terminationRequested = false
                return false
            }

            self.speechPreparationTask?.cancel()
            self.realtimeEventTask?.cancel()
            self.recordingTimerTask?.cancel()
            self.captureStallTask?.cancel()
            self.frameTask?.cancel()
            return true
        }
        shutdownTask = task
        let shouldTerminate = await task.value
        if !shouldTerminate {
            shutdownTask = nil
        }
        return shouldTerminate
    }

    func cancelTerminationPreparation() {
        shutdownTask?.cancel()
        terminationRequested = false
    }

    private var preferredRecognitionLanguage: String {
        Self.allowedPreference(
            key: "sel.lang",
            allowed: ["en-US", "ko-KR", "ja-JP", "zh-CN"],
            fallback: "en-US"
        )
    }

    private var preferredTranslationTarget: String {
        Self.allowedPreference(
            key: "sel.translate",
            allowed: ["en", "ko", "ja", "zh"],
            fallback: "ko"
        )
    }

    private var selectedMicrophone: AudioInputDevice? {
        audioDevices.first { $0.uid == selectedMicrophoneID }
    }

    private var selectedSystemInput: AudioInputDevice? {
        audioDevices.first { $0.uid == selectedSystemInputID }
    }

    private func loadAudioDevices() throws {
        audioDevices = try CoreAudioDeviceCatalog().inputDevices()
        let available = Set(audioDevices.map(\.uid))
        if let selectedMicrophoneID, !available.contains(selectedMicrophoneID) {
            self.selectedMicrophoneID = nil
        }
        if let selectedSystemInputID, !available.contains(selectedSystemInputID) {
            self.selectedSystemInputID = nil
        }
        if selectedMicrophoneID == nil {
            selectedMicrophoneID = audioDevices.first(where: \.isDefaultInput)?.uid
                ?? audioDevices.first?.uid
        }
    }

    private func startRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingElapsedSeconds = 0
        NSApplication.shared.windows.first?.title = "Recording — Wherewe"
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.recordingElapsedSeconds += 1
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        captureStallTask?.cancel()
        captureStallTask = nil
        recordingElapsedSeconds = 0
        levelMeter = nil
        captureLive = false
        captureStartStalled = false
        captureLevels = []
        captureChannelLabels = []
        NSApplication.shared.windows.first?.title = "Wherewe"
    }

    private func armCaptureFeedback(labels: [String], sampleRate: Double) {
        levelMeter = CaptureLevelMeter(channelCount: labels.count, sampleRate: sampleRate)
        captureChannelLabels = labels
        captureLevels = Array(repeating: 0, count: labels.count)
        captureLive = false
        captureStartStalled = false
    }

    private func watchForCaptureStall() {
        captureStallTask?.cancel()
        captureStallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.captureStallSeconds))
            guard let self, !Task.isCancelled, !self.captureLive,
                  self.recordingPhase == .recording else { return }
            self.captureStartStalled = true
        }
    }

    private func noteCapturedAudio(_ samples: [Int16]) {
        guard levelMeter != nil else { return }
        if !captureLive {
            captureLive = true
            captureStartStalled = false
            captureStallTask?.cancel()
            startRecordingTimer()
        }
        if let levels = levelMeter?.consume(samples) {
            captureLevels = levels
        }
    }

    private func startRealtimeEventPump() {
        let events = coordinator.events
        realtimeEventTask = Task { [weak self] in
            for await message in events {
                guard let self, !Task.isCancelled else { return }
                switch message.name {
                case .transcription:
                    guard let event = try? message.decode(TranscriptionEvent.self),
                          event.meetingID == self.loadedSelectedMeetingID,
                          await self.transcriptStore.apply(event) != nil else { continue }
                    await self.refreshTranscriptItems()
                case .segmentsUpdated, .translationUpdated, .translationTargetChanged:
                    await self.resyncTranscriptState()
                case .transcribeError:
                    if let error = try? message.decode(NativeTranscriptionError.self) {
                        self.recordingError = error.message ?? "Apple Speech transcription failed."
                    }
                case .disconnected:
                    if self.suppressDisconnectRecovery { continue }
                    if self.recordingPhase == .recording
                        || self.recordingPhase == .preparing
                        || self.recordingPhase == .stopping {
                        await self.handleRecordingDisconnect()
                    } else {
                        self.phase = .failed("The native realtime service disconnected unexpectedly.")
                    }
                case .connected:
                    await self.resyncTranscriptState()
                case .readyForAudio:
                    continue
                }
            }
        }
    }

    private func handleRecordingDisconnect() async {
        stopRecordingTimer()
        if let token = await capture.stop() { await waitUntilDrained(token) }
        await coordinator.markConnectionLost()
        recordingPhase = .recoveryRequired
        recordingError = "The native service connection ended during recording. Retry finalisation before starting again."
    }

    private func resyncTranscriptState() async {
        guard let meetingID = loadedSelectedMeetingID else { return }
        let generation = meetingLoadGeneration
        do {
            let state = try await api.transcriptState(meetingID: meetingID)
            guard generation == meetingLoadGeneration, selectedMeetingID == meetingID else { return }
            guard await transcriptStore.applyState(state) != nil else { return }
            await refreshTranscriptItems()
        } catch {
            if selectedMeetingID == meetingID { workspaceError = error.localizedDescription }
        }
    }

    private func refreshTranscriptItems() async {
        transcriptItems = await transcriptStore.visibleItems(view: transcriptView)
    }

    private func startFramePump() {
        let frames = capture.frames
        frameTask = Task { [weak self] in
            for await event in frames {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case let .frame(samples):
                    self.noteCapturedAudio(samples)
                    do { try await self.coordinator.sendPCM(samples) }
                    catch {
                        self.recordingError = error.localizedDescription
                        self.requestStopAfterAudioDeliveryFailure()
                    }
                case let .drained(token):
                    self.markDrained(token)
                }
            }
        }
    }

    private func requestStopAfterAudioDeliveryFailure() {
        guard recordingPhase == .recording, recordingStopTask == nil else { return }
        preserveRecordingErrorOnNextStop = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStopRecording()
            self.recordingStopTask = nil
        }
        recordingStopTask = task
    }

    private func markDrained(_ token: UUID) {
        if let waiter = drainWaiters.removeValue(forKey: token) {
            waiter.resume()
        } else {
            completedDrainTokens.insert(token)
        }
    }

    private func waitUntilDrained(_ token: UUID) async {
        if completedDrainTokens.remove(token) != nil { return }
        await withCheckedContinuation { continuation in
            drainWaiters[token] = continuation
        }
    }

    private func coordinatorNeedsRecovery() async -> Bool {
        if case .recoveryRequired = await coordinator.state { return true }
        return false
    }

    private func persistMeetingDraft(meetingID: Int) async throws {
        let title = meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MeetingDraftError.emptyTitle }
        _ = try await api.updateMeeting(
            id: meetingID,
            request: UpdateMeetingRequest(title: title, context: meetingContextDraft)
        )
    }

    private func persist(_ value: String?, key: String) {
        if let value, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func allowedPreference(key: String, allowed: Set<String>, fallback: String) -> String {
        guard let value = UserDefaults.standard.string(forKey: key), allowed.contains(value) else {
            return fallback
        }
        return value
    }
}

private struct NativeTranscriptionError: Decodable {
    let message: String?
}

private enum MeetingDraftError: LocalizedError {
    case emptyTitle

    var errorDescription: String? {
        "Meeting title cannot be empty."
    }
}
