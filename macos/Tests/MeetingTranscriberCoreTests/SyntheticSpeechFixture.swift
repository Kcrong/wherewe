import Foundation

/// Builds deterministic English speech for runtime and audio-path tests without
/// committing a recording whose speaker consent or redistribution rights are
/// unknown. Every invocation owns an isolated directory outside the repository.
struct SyntheticSpeechFixture {
    static let spokenText = "This is a test of the transcription system. Please confirm that you can hear me clearly. Thank you."

    let directory: URL
    let url: URL
    let wav: WAVFixture

    static func make() throws -> SyntheticSpeechFixture {
        let fileManager = FileManager.default
        let scratch = try externalScratchRoot()
        let directory = scratch.appendingPathComponent(
            "wherewe-synthetic-speech-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let aiff = directory.appendingPathComponent("speech.aiff")
            let wavURL = directory.appendingPathComponent("speech.wav")
            try run(
                "/usr/bin/say",
                arguments: ["-v", "Samantha", "-r", "130", "-o", aiff.path, spokenText]
            )
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aiff.path)
            try run(
                "/usr/bin/afconvert",
                arguments: ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wavURL.path]
            )
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wavURL.path)
            let values = try wavURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SyntheticSpeechFixtureError.invalidOutput
            }
            let wav = try WAVFixture(url: wavURL)
            guard wav.sampleRate == 16_000, !wav.pcm.isEmpty else {
                throw SyntheticSpeechFixtureError.invalidOutput
            }
            try fileManager.removeItem(at: aiff)
            return SyntheticSpeechFixture(directory: directory, url: wavURL, wav: wav)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func externalScratchRoot() throws -> URL {
        let fileManager = FileManager.default
        let candidate: URL
        if let raw = ProcessInfo.processInfo.environment["KIROCREW_SCRATCH"], !raw.isEmpty {
            guard raw.hasPrefix("/") else { throw SyntheticSpeechFixtureError.unsafeScratchRoot }
            candidate = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            candidate = fileManager.temporaryDirectory
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        let scratch = candidate.resolvingSymlinksInPath().standardizedFileURL
        let repository = repositoryRoot().resolvingSymlinksInPath().standardizedFileURL
        guard scratch.path != repository.path,
              !scratch.path.hasPrefix(repository.path + "/") else {
            throw SyntheticSpeechFixtureError.unsafeScratchRoot
        }
        return scratch
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func run(_ executable: String, arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw SyntheticSpeechFixtureError.commandUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SyntheticSpeechFixtureError.commandFailed
        }
    }
}

private enum SyntheticSpeechFixtureError: Error {
    case unsafeScratchRoot
    case commandUnavailable
    case commandFailed
    case invalidOutput
}
