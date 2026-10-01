import Foundation
import Testing
@testable import MeetingTranscriberCore

@Suite("Wherewe runtime configuration")
struct NativeServiceConfigurationTests {
    private let applicationSupport = URL(
        fileURLWithPath: "/test-user/Library/Application Support",
        isDirectory: true
    )

    @Test("new installation uses Wherewe support and config paths")
    func whereweDefaults() {
        let configuration = NativeServiceConfiguration.live(
            environment: [:],
            applicationSupportDirectory: applicationSupport
        )

        let expectedRoot = applicationSupport.appendingPathComponent("Wherewe", isDirectory: true)
        #expect(configuration.defaultDataRoot == expectedRoot.standardizedFileURL)
        #expect(configuration.configURL == expectedRoot.appendingPathComponent(".wherewe-config.json").standardizedFileURL)
    }

    @Test("Wherewe environment variables take precedence over legacy aliases")
    func canonicalEnvironmentPrecedence() {
        let configuration = NativeServiceConfiguration.live(
            environment: [
                "WHEREWE_DEFAULT_DATA_ROOT": "/canonical/data",
                "TRANSCRIBER_DEFAULT_DATA_ROOT": "/legacy/data",
                "WHEREWE_CONFIG_PATH": "/canonical/config.json",
                "TRANSCRIBER_CONFIG_PATH": "/legacy/config.json",
            ],
            applicationSupportDirectory: applicationSupport
        )

        #expect(configuration.defaultDataRoot.path == "/canonical/data")
        #expect(configuration.configURL.path == "/canonical/config.json")
        #expect(configuration.environment["WHEREWE_DEFAULT_DATA_ROOT"] == "/canonical/data")
        #expect(configuration.environment["TRANSCRIBER_DEFAULT_DATA_ROOT"] == "/canonical/data")
        #expect(configuration.environment["WHEREWE_CONFIG_PATH"] == "/canonical/config.json")
        #expect(configuration.environment["TRANSCRIBER_CONFIG_PATH"] == "/canonical/config.json")
    }

    @Test("legacy storage variables remain read-only compatibility aliases")
    func legacyEnvironmentFallback() {
        let configuration = NativeServiceConfiguration.live(
            environment: [
                "TRANSCRIBER_DEFAULT_DATA_ROOT": "/legacy/data",
                "TRANSCRIBER_CONFIG_PATH": "/legacy/config.json",
                "TRANSCRIBER_OBSOLETE_KEY": "/legacy/ignored",
            ],
            applicationSupportDirectory: applicationSupport
        )

        #expect(configuration.defaultDataRoot.path == "/legacy/data")
        #expect(configuration.configURL.path == "/legacy/config.json")
        #expect(configuration.environment["WHEREWE_DEFAULT_DATA_ROOT"] == "/legacy/data")
        #expect(configuration.environment["WHEREWE_CONFIG_PATH"] == "/legacy/config.json")
        #expect(configuration.environment["WHEREWE_OBSOLETE_KEY"] == nil)
    }
}
