import Foundation

public struct NativePreferences: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, Sendable {
        case system
        case light
        case dark
    }

    public enum TranscriptView: String, Codable, Sendable {
        case edited
        case raw

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = value == Self.raw.rawValue ? .raw : .edited
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var theme: Theme
    public var transcriptView: TranscriptView
    public var homeEventsCollapsed: Bool
    public var microphoneMuted: Bool
    public var microphoneDeviceID: String?
    public var systemAudioDeviceID: String?
    public var recognitionLanguage: String
    public var translationLanguage: String
    public var glossaryLanguage: String

    public init(
        theme: Theme = .system,
        transcriptView: TranscriptView = .edited,
        homeEventsCollapsed: Bool = false,
        microphoneMuted: Bool = false,
        microphoneDeviceID: String? = nil,
        systemAudioDeviceID: String? = nil,
        recognitionLanguage: String = "en-US",
        translationLanguage: String = "ko",
        glossaryLanguage: String = "en"
    ) {
        self.theme = theme
        self.transcriptView = transcriptView
        self.homeEventsCollapsed = homeEventsCollapsed
        self.microphoneMuted = microphoneMuted
        self.microphoneDeviceID = microphoneDeviceID
        self.systemAudioDeviceID = systemAudioDeviceID
        self.recognitionLanguage = recognitionLanguage
        self.translationLanguage = translationLanguage
        self.glossaryLanguage = glossaryLanguage
    }

    public static func importingWebStorage(
        _ values: [String: String],
        availableAudioDeviceIDs: Set<String> = []
    ) -> NativePreferences {
        let theme: Theme = switch values["theme"] {
        case "light": .light
        case "dark": .dark
        default: .system
        }
        let transcriptView: TranscriptView = values["transcriptView"] == "raw" ? .raw : .edited

        return NativePreferences(
            theme: theme,
            transcriptView: transcriptView,
            homeEventsCollapsed: values["home.eventsCollapsed"] == "1",
            microphoneMuted: values["mic.muted"] == "1",
            microphoneDeviceID: availableDevice(values["sel.mic"], in: availableAudioDeviceIDs),
            systemAudioDeviceID: availableDevice(values["sel.sys"], in: availableAudioDeviceIDs),
            recognitionLanguage: allowed(
                values["sel.lang"],
                values: ["en-US", "ko-KR", "ja-JP", "zh-CN"],
                fallback: "en-US"
            ),
            translationLanguage: allowed(
                values["sel.translate"],
                values: ["en", "ko", "ja", "zh"],
                fallback: "ko"
            ),
            glossaryLanguage: allowed(
                values["sel.glossaryLang"],
                values: ["en", "ko", "ja", "zh"],
                fallback: "en"
            )
        )
    }

    private static func availableDevice(_ value: String?, in available: Set<String>) -> String? {
        guard let value, !value.isEmpty, available.contains(value) else { return nil }
        return value
    }

    private static func allowed(_ value: String?, values: Set<String>, fallback: String) -> String {
        guard let value, values.contains(value) else { return fallback }
        return value
    }
}
