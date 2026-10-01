import Darwin
import Foundation

final class NativeSpoolWorkspace: @unchecked Sendable {
    struct SpoolFile {
        let url: URL
        let handle: FileHandle
    }

    let directory: URL
    private let baseURL: URL
    private let fileManager: FileManager
    private let lockDescriptor: Int32
    private let stateLock = NSLock()
    private var closed = false

    init(
        baseURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wherewe-audio", isDirectory: true),
        fileManager: FileManager = .default
    ) throws {
        let normalizedBase = baseURL.standardizedFileURL
        let processDirectory = normalizedBase.appendingPathComponent(
            "process-\(getpid())-\(UUID().uuidString)",
            isDirectory: true
        )
        self.baseURL = normalizedBase
        self.fileManager = fileManager
        self.directory = processDirectory

        try Self.secureDirectory(normalizedBase, fileManager: fileManager)
        try fileManager.createDirectory(at: processDirectory, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: processDirectory.path)
        try Self.verifyMode(0o700, at: processDirectory, fileManager: fileManager)

        let lockURL = processDirectory.appendingPathComponent(".owner.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            try? fileManager.removeItem(at: processDirectory)
            throw Self.failure("A private PCM spool owner lock could not be created.")
        }
        do {
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw Self.failure("The PCM spool owner lock could not be acquired.")
            }
            guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw Self.failure("The PCM spool owner lock permissions could not be secured.")
            }
            try Self.verifyMode(0o600, at: lockURL, fileManager: fileManager)
        } catch {
            Darwin.close(descriptor)
            try? fileManager.removeItem(at: processDirectory)
            throw error
        }
        self.lockDescriptor = descriptor
        _ = Self.sweepStaleWorkspaces(in: normalizedBase, fileManager: fileManager)
    }

    deinit {
        close()
    }

    func makeSpoolFile() throws -> SpoolFile {
        let available = stateLock.withLock { !closed }
        guard available else {
            throw Self.failure("The PCM spool workspace is closed.")
        }
        let url = directory.appendingPathComponent("\(UUID().uuidString).pcm")
        let descriptor = open(
            url.path,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw Self.failure("A private PCM spool file could not be created.")
        }
        do {
            guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw Self.failure("PCM spool file permissions could not be secured.")
            }
            try Self.verifyMode(0o600, at: url, fileManager: fileManager)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw Self.failure("The PCM spool path is not a safe regular file.")
            }
            return SpoolFile(
                url: url,
                handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            )
        } catch {
            Darwin.close(descriptor)
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    func close() {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        _ = flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
        try? fileManager.removeItem(at: directory)
    }

    @discardableResult
    static func sweepStaleWorkspaces(
        in baseURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var removed: [URL] = []
        for entry in entries {
            let parts = entry.lastPathComponent.split(separator: "-", maxSplits: 2)
            guard parts.count == 3,
                  parts[0] == "process",
                  let pid = Int32(String(parts[1])),
                  pid > 0,
                  !processIsAlive(pid),
                  let values = try? entry.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            let lockURL = entry.appendingPathComponent(".owner.lock")
            let descriptor = open(lockURL.path, O_RDWR | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            let acquired = flock(descriptor, LOCK_EX | LOCK_NB) == 0
            if acquired,
               (try? verifyMode(0o600, at: lockURL, fileManager: fileManager)) != nil,
               (try? fileManager.removeItem(at: entry)) != nil {
                removed.append(entry)
            }
            if acquired { _ = flock(descriptor, LOCK_UN) }
            Darwin.close(descriptor)
        }
        return removed
    }

    private static func secureDirectory(_ url: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw failure("The PCM spool root is not a safe directory.")
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try verifyMode(0o700, at: url, fileManager: fileManager)
    }

    private static func verifyMode(
        _ expected: Int,
        at url: URL,
        fileManager: FileManager
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actual = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard actual == expected else {
            throw failure("PCM spool permissions are not private.")
        }
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        errno = 0
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func failure(_ message: String) -> NativeServiceError {
        NativeServiceError.server(status: 500, code: "AUDIO_SPOOL_SECURITY", message: message)
    }
}
