import AppKit
import Foundation

extension NativeService {
    public func health() async throws -> NativeServiceHealth {
        if let startupError { throw startupError }
        let configured = settingsStore.isConfigured
        return NativeServiceHealth(
            service: NativeProtocol.service,
            applicationVersion: configuration.applicationVersion,
            protocolVersion: NativeProtocol.version,
            state: configured ? .ready : .setupRequired,
            configured: configured,
            setupRequired: !configured,
            realtimeAvailable: configured
        )
    }

    public func settings() async throws -> SettingsEnvelope {
        try settingsStore.envelope()
    }

    public func importSettings(_ data: Data, etag: String?) async throws -> SettingsEnvelope {
        guard recordingClaim == nil, recordingStartLanguages.isEmpty else {
            throw NativeServiceError.server(
                status: 409,
                code: "SETTINGS_TRANSCRIPTION_ACTIVE",
                message: "Stop recording or wait for recording startup to finish before importing settings."
            )
        }
        return try activateSettings(settingsStore.prepareImport(data, etag: etag))
    }

    public func updateSettings(
        _ request: SettingsUpdateRequest,
        etag: String?
    ) async throws -> SettingsEnvelope {
        guard recordingStartLanguages.isEmpty else {
            throw NativeServiceError.server(
                status: 409,
                code: "SETTINGS_TRANSCRIPTION_ACTIVE",
                message: "Wait for recording startup to finish before changing settings."
            )
        }
        if recordingClaim != nil, settingsStore.isConfigured {
            let current = try settingsStore.envelope().document.updateRequest
            if current.transcription != request.transcription || current.paths != request.paths {
                throw NativeServiceError.server(
                    status: 409,
                    code: "SETTINGS_TRANSCRIPTION_ACTIVE",
                    message: "Stop recording before changing transcription or storage settings."
                )
            }
        }
        return try activateSettings(settingsStore.prepareUpdate(request, etag: etag))
    }

    private func activateSettings(_ prepared: NativeSettingsStore.PreparedUpdate) throws -> SettingsEnvelope {
        let candidate = try NativeDatabase(
            url: URL(fileURLWithPath: prepared.document.paths.database),
            fileManager: fileManager
        )
        let envelope = try settingsStore.commit(prepared)
        databaseStorage = candidate
        startupError = nil
        return envelope
    }

    public func transcriptionCatalogue() async throws -> TranscriptionCatalogueResponse {
        try await transcriptionCatalogue(language: "en-US")
    }

    public func transcriptionCatalogue(language: String) async throws -> TranscriptionCatalogueResponse {
        let available = speechService.isAvailable()
        let readiness: NativeSpeechReadiness
        if available {
            readiness = await speechService.readiness(language: language)
        } else {
            readiness = .unavailable
        }
        let languageLabel = nativeSpeechLanguageLabel(language)
        let status: (state: String, message: String?, reason: String?, error: String?)
        switch readiness {
        case .unavailable:
            let message = "Apple SpeechAnalyzer is unavailable for \(languageLabel) on this Mac."
            status = (
                "unavailable",
                nil,
                message,
                message
            )
        case .unsupported:
            let message = "Apple SpeechAnalyzer does not support \(languageLabel)."
            status = ("unsupported", message, message, message)
        case .installationRequired:
            status = (
                "installation-required",
                "Install \(languageLabel) Speech assets before recording.",
                "\(languageLabel) Speech assets are not installed.",
                nil
            )
        case .ready:
            status = ("ready", "\(languageLabel) Speech assets are installed.", nil, nil)
        }
        return TranscriptionCatalogueResponse(
            localProviders: [
                LocalProviderDescriptor(
                    id: "apple",
                    label: "Apple SpeechAnalyzer",
                    description: "On-device transcription provided by Apple Speech",
                    modelRequired: false,
                    defaultModel: "system",
                    available: available,
                    ready: readiness == .ready,
                    reason: status.reason
                ),
            ],
            progress: TranscriptionProgress(
                state: status.state,
                provider: "apple",
                model: "system",
                message: status.message,
                error: status.error
            )
        )
    }

    public func prepareTranscription(
        provider: String,
        model: String
    ) async throws -> TranscriptionCatalogueResponse {
        try await prepareTranscription(provider: provider, model: model, language: "en-US")
    }

    public func prepareTranscription(
        provider: String,
        model: String,
        language: String
    ) async throws -> TranscriptionCatalogueResponse {
        guard provider == "apple", model == "system" else {
            throw NativeServiceError.server(
                status: 400,
                code: "TRANSCRIPTION_SELECTION_INVALID",
                message: "Apple Speech with the system model is the only supported transcription selection."
            )
        }
        guard recordingClaim == nil,
              recordingStartLanguages.isEmpty,
              speechAssetPreparationLanguage == nil else {
            throw NativeServiceError.server(
                status: 409,
                code: "APPLE_SPEECH_PREPARATION_ACTIVE",
                message: "Wait for recording startup or recording to finish before installing Speech assets."
            )
        }
        speechAssetPreparationLanguage = language
        defer { speechAssetPreparationLanguage = nil }
        try await speechService.prepare(
            language: language,
            mode: "live",
            showDetails: false
        )
        return try await transcriptionCatalogue(language: language)
    }

    public func translationLanguages() async throws -> TranslationLanguagesResponse {
        let definitions = [("en", "English"), ("ko", "Korean"), ("ja", "Japanese"), ("zh", "Chinese")]
        var pairs: [String: TranslationPairStatus] = [:]
        for left in 0..<definitions.count {
            for right in (left + 1)..<definitions.count {
                let source = definitions[left].0
                let target = definitions[right].0
                do {
                    let status = try await translationService.status(source: source, target: target)
                    pairs["\(source)-\(target)"] = TranslationPairStatus(
                        source: source,
                        target: target,
                        status: status,
                        errorCode: nil,
                        error: nil
                    )
                } catch {
                    pairs["\(source)-\(target)"] = TranslationPairStatus(
                        source: source,
                        target: target,
                        status: "error",
                        errorCode: "APPLE_TRANSLATION_STATUS",
                        error: String(error.localizedDescription.prefix(240))
                    )
                }
            }
        }
        return TranslationLanguagesResponse(
            languages: definitions.map { id, label in
                let related = pairs.values.filter { $0.source == id || $0.target == id }
                let installed = related.allSatisfy { $0.status == "installed" }
                return TranslationLanguageStatus(
                    id: id,
                    label: label,
                    installed: installed,
                    status: related.contains(where: { $0.status == "error" })
                        ? "error"
                        : installed ? "installed" : "not-installed"
                )
            },
            pairs: pairs
        )
    }

    public func openTranslationSettings() async throws -> OpenSettingsResponse {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else {
            return OpenSettingsResponse(opened: false)
        }
        return await MainActor.run { OpenSettingsResponse(opened: NSWorkspace.shared.open(url)) }
    }
}
