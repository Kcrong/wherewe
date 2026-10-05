import CryptoKit
import Foundation

final class NativeSettingsStore {
    let configuration: NativeServiceConfiguration
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(configuration: NativeServiceConfiguration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    var isConfigured: Bool {
        fileManager.fileExists(atPath: configuration.configURL.path)
    }

    func envelope() throws -> SettingsEnvelope {
        guard isConfigured else {
            return SettingsEnvelope(document: initialDocument(), etag: nil)
        }
        let request = try readRequest(from: configuration.configURL)
        let document = document(for: request, configured: true)
        return SettingsEnvelope(document: document, etag: try etag(for: request))
    }

    struct PreparedUpdate {
        fileprivate let request: SettingsUpdateRequest
        fileprivate let etag: String?
        let document: SettingsDocument
    }

    func prepareImport(_ data: Data, etag: String?) throws -> PreparedUpdate {
        guard data.count <= 256 * 1_024 else { throw NativeServiceError.encoding }
        let request: SettingsUpdateRequest
        if let decoded = try? decoder.decode(SettingsUpdateRequest.self, from: data) {
            request = decoded
        } else if let document = try? decoder.decode(SettingsDocument.self, from: data) {
            request = document.updateRequest
        } else {
            throw NativeServiceError.server(status: 400, code: "SETTINGS_INVALID", message: "The settings file is not valid.")
        }
        return try prepareUpdate(request, etag: etag)
    }

    func prepareUpdate(_ submitted: SettingsUpdateRequest, etag: String?) throws -> PreparedUpdate {
        var request = normalized(submitted)
        request.paths = try NativeStoragePathPolicy.canonicalize(request.paths)
        try validate(request)
        try validateRevision(etag)
        return PreparedUpdate(
            request: request,
            etag: etag,
            document: document(for: request, configured: true)
        )
    }

    func prepareStorage(for prepared: PreparedUpdate) throws {
        let request = prepared.request
        _ = try NativeStoragePathPolicy.secureDirectory(
            configuration.configURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        _ = try NativeStoragePathPolicy.secureDirectory(
            URL(fileURLWithPath: request.paths.files, isDirectory: true),
            fileManager: fileManager
        )
        _ = try NativeStoragePathPolicy.validateDatabaseURL(
            URL(fileURLWithPath: request.paths.database),
            fileManager: fileManager
        )
    }

    func update(_ submitted: SettingsUpdateRequest, etag: String?) throws -> SettingsEnvelope {
        let prepared = try prepareUpdate(submitted, etag: etag)
        try prepareStorage(for: prepared)
        return try commit(prepared)
    }

    func commit(_ prepared: PreparedUpdate) throws -> SettingsEnvelope {
        try validateRevision(prepared.etag)
        let directory = try NativeStoragePathPolicy.secureDirectory(
            configuration.configURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        let data = try encoder.encode(prepared.request)
        let temporary = directory.appendingPathComponent(".\(configuration.configURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            try NativeStoragePathPolicy.securePrivateFile(
                temporary,
                maximumBytes: 256 * 1_024,
                fileManager: fileManager
            )
            if fileManager.fileExists(atPath: configuration.configURL.path) {
                _ = try fileManager.replaceItemAt(configuration.configURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: configuration.configURL)
            }
            try NativeStoragePathPolicy.securePrivateFile(
                configuration.configURL,
                maximumBytes: 256 * 1_024,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw NativeServiceError.server(status: 500, code: "SETTINGS_WRITE", message: "Unable to save settings.")
        }
        return try envelope()
    }

    func initialDocument() -> SettingsDocument {
        document(for: initialRequest(), configured: false)
    }

    private func readRequest(from url: URL) throws -> SettingsUpdateRequest {
        do {
            try NativeStoragePathPolicy.securePrivateFile(
                url,
                maximumBytes: 256 * 1_024,
                fileManager: fileManager
            )
            var request = normalized(try decoder.decode(SettingsUpdateRequest.self, from: Data(contentsOf: url)))
            request.paths = try NativeStoragePathPolicy.canonicalize(request.paths)
            try validate(request)
            return request
        } catch let error as NativeServiceError {
            throw error
        } catch {
            throw NativeServiceError.server(status: 500, code: "SETTINGS_UNAVAILABLE", message: "The settings file is unavailable.")
        }
    }

    private func validateRevision(_ etag: String?) throws {
        if isConfigured {
            let current = try envelope()
            guard let etag, etag == current.etag else {
                throw NativeServiceError.server(
                    status: 412,
                    code: "SETTINGS_REVISION_CONFLICT",
                    message: "Settings changed since they were opened. Reload and try again."
                )
            }
        } else if etag != nil {
            throw NativeServiceError.server(status: 412, code: "SETTINGS_REVISION_CONFLICT", message: nil)
        }
    }

    private func normalized(_ submitted: SettingsUpdateRequest) -> SettingsUpdateRequest {
        var request = submitted
        let submittedApple = request.transcription.local.apple ?? AppleSpeechSettings()
        request.transcription.engine = "apple"
        request.transcription.local.provider = "apple"
        request.transcription.local.model = "system"
        request.transcription.local.apple = AppleSpeechSettings(
            mode: ["live", "accurate"].contains(submittedApple.mode) ? submittedApple.mode : "live",
            showDetails: submittedApple.showDetails
        )
        request.translation.provider = "apple"
        return request
    }

    private func validate(_ request: SettingsUpdateRequest) throws {
        let apple = request.transcription.local.apple
        guard request.version == 1,
              !request.user.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.user.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.transcription.engine == "apple",
              request.transcription.local.provider == "apple",
              request.transcription.local.model == "system",
              let apple,
              ["live", "accurate"].contains(apple.mode),
              request.translation.provider == "apple" else {
            throw NativeServiceError.server(status: 400, code: "SETTINGS_INVALID", message: "The settings request is invalid.")
        }
    }

    private func initialRequest() -> SettingsUpdateRequest {
        let dataRoot = configuration.defaultDataRoot
        return SettingsUpdateRequest(
            version: 1,
            transcription: TranscriptionSettings(),
            translation: TranslationSettings(),
            user: UserSettings(name: "", role: "", organization: "", profile: ""),
            paths: PathSettings(
                database: dataRoot.appendingPathComponent("data/meetings.db").path,
                files: dataRoot.appendingPathComponent("data/files", isDirectory: true).path
            )
        )
    }

    private func document(for request: SettingsUpdateRequest, configured: Bool) -> SettingsDocument {
        SettingsDocument(
            version: request.version,
            revision: nil,
            configured: configured,
            restartRequired: false,
            restartReasons: [],
            environmentOverrides: [],
            transcription: request.transcription,
            translation: request.translation,
            user: request.user,
            paths: request.paths
        )
    }

    private func etag(for request: SettingsUpdateRequest) throws -> String {
        let digest = SHA256.hash(data: try encoder.encode(request))
        let value = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\"settings-v1-\(value)\""
    }
}
