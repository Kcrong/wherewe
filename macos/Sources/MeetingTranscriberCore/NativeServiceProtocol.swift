import Foundation

public protocol NativeServiceServing: Sendable {
    func health() async throws -> NativeServiceHealth
    func meetings() async throws -> [MeetingSummary]
    func meeting(id: Int) async throws -> MeetingDetail
    func transcriptState(meetingID: Int) async throws -> TranscriptStateResponse
    func createMeeting(_ request: CreateMeetingRequest) async throws -> CreateMeetingResponse
    func activateMeeting(id: Int) async throws -> SuccessResponse
    func updateMeeting(id: Int, request: UpdateMeetingRequest) async throws -> SuccessResponse
    func updateMeetingContext(id: Int, context: String) async throws -> SuccessResponse
    func deleteMeeting(id: Int, socketID: String?) async throws -> SuccessResponse
    func editTranscript(meetingID: Int, transcriptID: Int, text: String) async throws -> SegmentEditResponse
    func editSegment(meetingID: Int, segmentID: Int, text: String) async throws -> SegmentEditResponse
    func updateTranslationTarget(meetingID: Int, target: String) async throws -> TranslationTargetResponse
    func retryTranslation(meetingID: Int, entityType: TranslationEntityType, entityID: Int) async throws -> TranslationRetryResponse
    func documents(meetingID: Int) async throws -> [UploadedDocument]
    func uploadDocument(meetingID: Int, name: String, data: Data) async throws -> UploadResponse
    func documentContent(id: Int) async throws -> DocumentContent
    func deleteDocument(id: Int) async throws -> SuccessResponse
    func glossary(language: String) async throws -> [GlossaryEntry]
    func meetingGlossary(meetingID: Int) async throws -> [GlossaryEntry]
    func createGlossary(_ request: GlossaryMutationRequest) async throws -> CreatedIDResponse
    func updateGlossary(id: Int, request: GlossaryMutationRequest) async throws -> SuccessResponse
    func deleteGlossary(id: Int) async throws -> SuccessResponse
    func exportMeeting(id: Int) async throws -> MeetingExportResponse
    func reveal(path: String) async throws -> SuccessResponse
    func settings() async throws -> SettingsEnvelope
    func importSettings(_ data: Data, etag: String?) async throws -> SettingsEnvelope
    func updateSettings(_ request: SettingsUpdateRequest, etag: String?) async throws -> SettingsEnvelope
    @available(*, deprecated, message: "Pass the selected recognition language explicitly.")
    func transcriptionCatalogue() async throws -> TranscriptionCatalogueResponse
    func transcriptionCatalogue(language: String) async throws -> TranscriptionCatalogueResponse
    func translationLanguages() async throws -> TranslationLanguagesResponse
    func openTranslationSettings() async throws -> OpenSettingsResponse
    @available(*, deprecated, message: "Pass the selected recognition language explicitly.")
    func prepareTranscription(provider: String, model: String) async throws -> TranscriptionCatalogueResponse
    func prepareTranscription(provider: String, model: String, language: String) async throws -> TranscriptionCatalogueResponse
    func recordingStatus(socketID: String?) async throws -> RecordingStatus
    func recordingPreparation(meetingID: Int) async throws -> RecordingPreparation
    func startRecording(meetingID: Int, request: StartRecordingRequest) async throws -> StartRecordingResponse
    func finalizeRecording(_ request: FinalizeRecordingRequest) async throws -> SuccessResponse
}

public extension NativeServiceServing {
    func transcriptionCatalogue(language: String) async throws -> TranscriptionCatalogueResponse {
        try await transcriptionCatalogue()
    }

    func prepareTranscription(
        provider: String,
        model: String,
        language: String
    ) async throws -> TranscriptionCatalogueResponse {
        try await prepareTranscription(provider: provider, model: model)
    }
}

package struct DocumentUploadResult: Equatable, Identifiable, Sendable {
    package enum Outcome: Equatable, Sendable {
        case uploaded(UploadResponse)
        case failed(String)
    }

    package let id: Int
    package let name: String
    package let outcome: Outcome

    package var succeeded: Bool {
        if case .uploaded = outcome { return true }
        return false
    }

    package var statusMessage: String {
        switch outcome {
        case .uploaded:
            "Uploaded \(name)."
        case let .failed(message):
            "\(name) failed: \(message)"
        }
    }
}

extension NativeServiceServing {
    package func uploadDocuments(meetingID: Int, urls: [URL]) async -> [DocumentUploadResult] {
        var results: [DocumentUploadResult] = []
        results.reserveCapacity(urls.count)

        for (index, url) in urls.enumerated() {
            let name = url.lastPathComponent
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                guard data.count <= 5 * 1_024 * 1_024 else {
                    throw DocumentUploadValidationError.fileTooLarge(name)
                }
                guard ["pdf", "md", "txt", "html", "csv"].contains(url.pathExtension.lowercased()) else {
                    throw DocumentUploadValidationError.unsupportedFile(name)
                }
                let response = try await uploadDocument(meetingID: meetingID, name: name, data: data)
                results.append(DocumentUploadResult(id: index, name: name, outcome: .uploaded(response)))
            } catch {
                results.append(DocumentUploadResult(
                    id: index,
                    name: name,
                    outcome: .failed(error.localizedDescription)
                ))
            }
        }

        return results
    }
}

private enum DocumentUploadValidationError: LocalizedError {
    case fileTooLarge(String)
    case unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(name):
            "\(name) is larger than the 5 MB upload limit."
        case let .unsupportedFile(name):
            "\(name) is not PDF, Markdown, TXT, HTML, or CSV."
        }
    }
}

public enum NativeServiceError: Error, Equatable, LocalizedError, Sendable {
    case server(status: Int, code: String?, message: String?)
    case encoding
    case decoding

    public var errorDescription: String? {
        switch self {
        case let .server(status, code, message):
            if let message, !message.isEmpty { return message }
            if let code { return "The native operation failed (\(code), status \(status))." }
            return "The native operation failed (status \(status))."
        case .encoding:
            return "The native service could not encode its data."
        case .decoding:
            return "Stored data does not match the native service contract."
        }
    }
}
