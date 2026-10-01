import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Native preferences")
struct NativePreferencesTests {
    @Test("imports recording and language preferences without obsolete panel state")
    func importsValidBrowserPreferences() {
        let preferences = NativePreferences.importingWebStorage(
            [
                "theme": "dark",
                "transcriptView": "raw",
                "home.eventsCollapsed": "1",
                "mic.muted": "1",
                "sel.mic": "external-microphone",
                "sel.sys": "blackhole-2ch",
                "sel.lang": "ko-KR",
                "sel.translate": "ja",
                "sel.glossaryLang": "zh",
                "obsolete.panel": "ignored",
            ],
            availableAudioDeviceIDs: ["external-microphone", "blackhole-2ch"]
        )

        #expect(preferences.theme == .dark)
        #expect(preferences.transcriptView == .raw)
        #expect(preferences.homeEventsCollapsed)
        #expect(preferences.microphoneMuted)
        #expect(preferences.microphoneDeviceID == "external-microphone")
        #expect(preferences.systemAudioDeviceID == "blackhole-2ch")
        #expect(preferences.recognitionLanguage == "ko-KR")
        #expect(preferences.translationLanguage == "ja")
        #expect(preferences.glossaryLanguage == "zh")
    }

    @Test("invalid and disconnected values fall back without touching durable data")
    func invalidValuesFallBack() {
        let preferences = NativePreferences.importingWebStorage([
            "theme": "unknown",
            "transcriptView": "future-view",
            "home.eventsCollapsed": "true",
            "mic.muted": "yes",
            "sel.mic": "disconnected-device",
            "sel.lang": "invalid",
            "sel.translate": "invalid",
            "sel.glossaryLang": "invalid",
        ])

        #expect(preferences == NativePreferences())
    }

    @Test("legacy transcript view values decode as edited")
    func legacyTranscriptViewNormalizes() throws {
        let data = Data(#"{"theme":"system","transcriptView":"legacy","homeEventsCollapsed":false,"microphoneMuted":false,"microphoneDeviceID":null,"systemAudioDeviceID":null,"recognitionLanguage":"en-US","translationLanguage":"ko","glossaryLanguage":"en"}"#.utf8)
        let preferences = try JSONDecoder().decode(NativePreferences.self, from: data)
        #expect(preferences.transcriptView == .edited)
    }
}
