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
