import Foundation

public struct TranscriptSnapshot: Equatable, Sendable {
    public let meetingID: Int?
    public let finalRows: [LiveTranscriptRow]
    public let partialRows: [LiveTranscriptRow]
    public let segments: [TranscriptSegment]

    public init(
        meetingID: Int? = nil,
        finalRows: [LiveTranscriptRow] = [],
        partialRows: [LiveTranscriptRow] = [],
        segments: [TranscriptSegment] = []
    ) {
        self.meetingID = meetingID
        self.finalRows = finalRows
        self.partialRows = partialRows
        self.segments = segments
    }
}

public enum VisibleTranscriptItem: Equatable, Identifiable, Sendable {
    case segment(TranscriptSegment)
    case transcript(LiveTranscriptRow)
    case partial(LiveTranscriptRow)

    public var id: String {
        switch self {
        case let .segment(segment): "segment:\(segment.id)"
        case let .transcript(row): "transcript:\(row.resultID)"
        case let .partial(row): "partial:\(row.channelID ?? ""):\(row.resultID)"
        }
    }
}

package struct TranscriptAutoFollowState: Equatable, Sendable {
    package private(set) var followsLatest = true

    package mutating func recordUserScroll(isNearBottom: Bool) {
        followsLatest = isNearBottom
    }

    package func shouldFollow(searchIsActive: Bool) -> Bool {
        followsLatest && !searchIsActive
    }
}

public actor TranscriptStore {
    public private(set) var snapshot = TranscriptSnapshot()

    private var activeMeetingID: Int?
    private var recordingMeetingID: Int?
    private var recordingGeneration: Int64?
    private var finalRows: [LiveTranscriptRow] = []
    private var partialsByChannel: [String: LiveTranscriptRow] = [:]
    private var segments: [TranscriptSegment] = []

    public init() {}

    @discardableResult
    public func activate(_ meeting: MeetingDetail) -> TranscriptSnapshot {
        activeMeetingID = meeting.id
        finalRows = meeting.transcripts.map(Self.liveRow)
        partialsByChannel = [:]
        segments = Self.sortedSegments(meeting.segments)
        return publish()
    }

    @discardableResult
    public func applyState(_ state: TranscriptStateResponse) -> TranscriptSnapshot? {
        guard state.meetingID == activeMeetingID else { return nil }
        finalRows = state.transcripts.map(Self.liveRow)
        segments = Self.sortedSegments(state.segments)
        return publish()
    }

    public func beginRecording(meetingID: Int, generation: Int64) {
        recordingMeetingID = meetingID
        recordingGeneration = generation
    }

    @discardableResult
    public func endRecording(meetingID: Int, generation: Int64) -> TranscriptSnapshot? {
        guard recordingMeetingID == meetingID, recordingGeneration == generation else { return nil }
        recordingMeetingID = nil
        recordingGeneration = nil
        partialsByChannel = [:]
        return publish()
    }

    @discardableResult
    public func apply(_ event: TranscriptionEvent) -> TranscriptSnapshot? {
        guard let meetingID = event.meetingID,
              meetingID == activeMeetingID,
              meetingID == recordingMeetingID,
              event.generation == recordingGeneration else {
            return nil
        }
        let text = event.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let row = Self.liveRow(event, text: text)
        let channelKey = event.channelID ?? ""

        if event.isPartial {
            partialsByChannel[channelKey] = row
        } else {
            if partialsByChannel[channelKey]?.resultID == event.resultID {
                partialsByChannel.removeValue(forKey: channelKey)
            }
            if let index = finalRows.firstIndex(where: { $0.resultID == event.resultID }) {
                finalRows[index] = row
            } else {
                finalRows.append(row)
            }
        }
        return publish()
    }

    @discardableResult
    public func replaceSegments(
        meetingID: Int,
        channelID: String?,
        incoming: [TranscriptSegment]
    ) -> TranscriptSnapshot? {
        guard meetingID == activeMeetingID else { return nil }
        segments.removeAll { $0.channelID == channelID }
        segments.append(contentsOf: incoming)
        segments = Self.sortedSegments(segments)
        return publish()
    }

    public func visibleItems(view: NativePreferences.TranscriptView) -> [VisibleTranscriptItem] {
        var items: [VisibleTranscriptItem] = []
        if view == .edited, !segments.isEmpty {
            let covered = Set(segments.flatMap(\.sourceIDs))
            items.append(contentsOf: segments.map(VisibleTranscriptItem.segment))
            items.append(contentsOf: finalRows.filter { !covered.contains($0.resultID) }.map(VisibleTranscriptItem.transcript))
        } else {
            items.append(contentsOf: finalRows.map(VisibleTranscriptItem.transcript))
        }
        items.append(contentsOf: partialsByChannel.values.sorted {
            ($0.channelID ?? "") < ($1.channelID ?? "")
        }.map(VisibleTranscriptItem.partial))
        return items
    }

    private func publish() -> TranscriptSnapshot {
        snapshot = TranscriptSnapshot(
            meetingID: activeMeetingID,
            finalRows: finalRows,
            partialRows: partialsByChannel.values.sorted {
                ($0.channelID ?? "") < ($1.channelID ?? "")
            },
            segments: segments
        )
        return snapshot
    }

    private static func liveRow(_ row: TranscriptRow) -> LiveTranscriptRow {
        LiveTranscriptRow(
            databaseID: row.id,
            resultID: row.resultID ?? "db:\(row.id)",
            text: row.text,
            isPartial: false,
            speaker: row.speaker,
            languageCode: row.languageCode,
            channelID: row.channelID,
            alternatives: normalizedAlternatives(row.alternatives, transcript: row.text),
            confidence: normalizedConfidence(row.confidence),
            transcriptionEngine: row.transcriptionEngine,
            transcriptionProvider: row.transcriptionProvider,
            transcriptionModel: row.transcriptionModel,
            transcriptionMode: row.transcriptionMode,
            resultStage: row.resultStage,
            translation: row.translation,
            translationTarget: row.translationTarget,
            translationProvider: row.translationProvider,
            translationSourceHash: row.translationSourceHash,
            translationSourceVersion: row.translationSourceVersion,
            translationStatus: row.translationStatus,
            translationError: row.translationError,
            translationAttempts: row.translationAttempts,
            translationUpdatedAt: row.translationUpdatedAt
        )
    }

    private static func liveRow(_ event: TranscriptionEvent, text: String) -> LiveTranscriptRow {
        LiveTranscriptRow(
            databaseID: event.databaseID,
            resultID: event.resultID,
            text: text,
            isPartial: event.isPartial,
            speaker: event.speaker,
            languageCode: event.languageCode,
            channelID: event.channelID,
            alternatives: normalizedAlternatives(event.alternatives ?? [], transcript: text),
            confidence: normalizedConfidence(event.confidence),
            transcriptionEngine: event.transcriptionEngine,
            transcriptionProvider: event.transcriptionProvider,
            transcriptionModel: event.transcriptionModel,
            transcriptionMode: event.transcriptionMode,
            resultStage: event.resultStage,
            translation: event.translation,
            translationTarget: event.translationTarget,
            translationProvider: event.translationProvider,
            translationSourceHash: event.translationSourceHash,
            translationSourceVersion: event.translationSourceVersion ?? 1,
            translationStatus: event.translationStatus ?? (event.isPartial ? .pending : .idle),
            translationError: event.translationError,
            translationAttempts: event.translationAttempts ?? 0,
            translationUpdatedAt: event.translationUpdatedAt
        )
    }

    private static func normalizedAlternatives(_ alternatives: [String], transcript: String) -> [String] {
        var seen = Set([transcript.trimmingCharacters(in: .whitespacesAndNewlines)])
        var values: [String] = []
        for candidate in alternatives {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            values.append(String(value.prefix(1_000)))
            if values.count == 3 { break }
        }
        return values
    }

    private static func normalizedConfidence(_ confidence: Double?) -> Double? {
        guard let confidence, confidence.isFinite, (0...1).contains(confidence) else { return nil }
        return confidence
    }

    private static func sortedSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.sorted {
            let left = $0.channelID ?? ""
            let right = $1.channelID ?? ""
            if left != right { return left < right }
            if $0.orderIndex != $1.orderIndex { return $0.orderIndex < $1.orderIndex }
            return $0.id < $1.id
        }
    }
}
