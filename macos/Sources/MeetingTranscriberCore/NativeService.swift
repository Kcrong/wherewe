import Foundation

public actor NativeService: NativeServiceServing {
    public nonisolated let eventHub: NativeRealtimeHub
    let configuration: NativeServiceConfiguration
    let settingsStore: NativeSettingsStore
    let speechService: any NativeSpeechServing
    let translationService: any NativeTranslationServing
    let fileManager: FileManager
    var databaseStorage: NativeDatabase?
    var startupError: Error?
    var activeMeetingID: Int?
    var connectedClientIDs: Set<String> = []
    var recordingClaim: NativeRecordingClaim?
    var recordingGeneration: Int64 = 0
    var speechAssetPreparationLanguage: String?
    var recordingStartLanguages: [UUID: String] = [:]
    var recordingLifecycleObserver = NativeRecordingLifecycleObserver()
    var exportLifecycleObserver = NativeExportLifecycleObserver()

    public init(
        configuration: NativeServiceConfiguration = .live(),
        fileManager: FileManager = .default,
        eventHub: NativeRealtimeHub = NativeRealtimeHub()
    ) {
        self.eventHub = eventHub
        self.configuration = configuration
        self.fileManager = fileManager
        self.settingsStore = NativeSettingsStore(configuration: configuration, fileManager: fileManager)
        self.speechService = NativeAppleSpeechService()
        self.translationService = NativeAppleTranslation()
        if settingsStore.isConfigured {
            do {
                let document = try settingsStore.envelope().document
                self.databaseStorage = try NativeDatabase(
                    url: URL(fileURLWithPath: document.paths.database),
                    fileManager: fileManager
                )
            } catch {
                self.startupError = error
            }
        }
    }

    init(
        configuration: NativeServiceConfiguration,
        fileManager: FileManager = .default,
        eventHub: NativeRealtimeHub = NativeRealtimeHub(),
        speechService: any NativeSpeechServing,
        translationService: any NativeTranslationServing
    ) {
        self.eventHub = eventHub
        self.configuration = configuration
        self.fileManager = fileManager
        self.settingsStore = NativeSettingsStore(configuration: configuration, fileManager: fileManager)
        self.speechService = speechService
        self.translationService = translationService
        if settingsStore.isConfigured {
            do {
                let document = try settingsStore.envelope().document
                self.databaseStorage = try NativeDatabase(
                    url: URL(fileURLWithPath: document.paths.database),
                    fileManager: fileManager
                )
            } catch {
                self.startupError = error
            }
        }
    }

    func requireDatabase() throws -> NativeDatabase {
        guard let databaseStorage else {
            throw NativeServiceError.server(
                status: 409,
                code: "SETUP_REQUIRED",
                message: "Complete setup before using the native service."
            )
        }
        return databaseStorage
    }

    func replaceDatabase(for document: SettingsDocument) throws {
        databaseStorage = try NativeDatabase(
            url: URL(fileURLWithPath: document.paths.database),
            fileManager: fileManager
        )
    }

    public func shutdown() async {
        recordingClaim = nil
        connectedClientIDs.removeAll()
        await translationService.reset()
    }
}

struct NativeRecordingClaim: Equatable {
    let meetingID: Int
    let generation: Int64
    let clientID: String
    let language: String
    let translationTarget: String
}

extension NativeService {
    func clientConnected(_ id: String) {
        connectedClientIDs.insert(id)
    }

    func clientDisconnected(_ id: String) {
        connectedClientIDs.remove(id)
    }
}
