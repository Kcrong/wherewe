import Foundation

public struct NativeServiceConfiguration: Sendable {
    public let configURL: URL
    public let defaultDataRoot: URL
    public let applicationVersion: String
    public let environment: [String: String]

    public init(
        configURL: URL,
        defaultDataRoot: URL,
        applicationVersion: String = "1.0.0",
        environment: [String: String] = [:]
    ) {
        self.configURL = configURL.standardizedFileURL
        self.defaultDataRoot = defaultDataRoot.standardizedFileURL
        self.applicationVersion = applicationVersion
        self.environment = Self.normalizedEnvironment(environment)
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) -> NativeServiceConfiguration {
        let normalizedEnvironment = Self.normalizedEnvironment(environment)
        let supportBase = applicationSupportDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let supportRoot = supportBase.appendingPathComponent("Wherewe", isDirectory: true)
        let dataRoot = normalizedEnvironment["WHEREWE_DEFAULT_DATA_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? supportRoot
        let configURL = normalizedEnvironment["WHEREWE_CONFIG_PATH"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? supportRoot.appendingPathComponent(".wherewe-config.json")
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.0"
        return NativeServiceConfiguration(
            configURL: configURL,
            defaultDataRoot: dataRoot,
            applicationVersion: version,
            environment: normalizedEnvironment
        )
    }

    private static func normalizedEnvironment(_ environment: [String: String]) -> [String: String] {
        let canonicalPrefix = "WHEREWE_"
        let legacyPrefix = "TRANSCRIBER_"
        let compatibleSuffixes = ["DEFAULT_DATA_ROOT", "CONFIG_PATH"]
        var normalized = environment
        for suffix in compatibleSuffixes {
            let canonicalKey = "\(canonicalPrefix)\(suffix)"
            let legacyKey = "\(legacyPrefix)\(suffix)"
            guard let value = environment[canonicalKey] ?? environment[legacyKey] else { continue }
            normalized[canonicalKey] = value
            normalized[legacyKey] = value
        }
        return normalized
    }
}
