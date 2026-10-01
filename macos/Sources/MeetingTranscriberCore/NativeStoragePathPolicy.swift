import Foundation

enum NativeStoragePathPolicy {
    static func canonicalize(_ paths: PathSettings) throws -> PathSettings {
        PathSettings(
            database: try canonicalURL(paths.database, isDirectory: false).path,
            files: try canonicalURL(paths.files, isDirectory: true).path
        )
    }

    static func secureDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws -> URL {
        let canonical = url.standardizedFileURL
        try rejectTerminalSymlink(canonical, fileManager: fileManager)
        if fileManager.fileExists(atPath: canonical.path) {
            let values = try canonical.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw invalidPath("Configured storage root must be a non-symlink directory.")
            }
        } else {
            try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: canonical.path)
        try verifyMode(0o700, at: canonical, fileManager: fileManager)
        return canonical
    }

    static func validateDatabaseURL(
        _ url: URL,
        fileManager: FileManager
    ) throws -> URL {
        let canonical = url.standardizedFileURL
        guard (canonical.path as NSString).isAbsolutePath else {
            throw invalidPath("Database path must be absolute.")
        }
        _ = try secureDirectory(canonical.deletingLastPathComponent(), fileManager: fileManager)
        for candidate in [
            canonical,
            URL(fileURLWithPath: canonical.path + "-wal"),
            URL(fileURLWithPath: canonical.path + "-shm"),
        ] {
            try rejectTerminalSymlink(candidate, fileManager: fileManager)
            if fileManager.fileExists(atPath: candidate.path) {
                let values = try candidate.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw invalidPath("Database paths must be non-symlink regular files.")
                }
            }
        }
        return canonical
    }

    static func securePrivateFile(
        _ url: URL,
        maximumBytes: Int? = nil,
        fileManager: FileManager
    ) throws {
        let canonical = url.standardizedFileURL
        try rejectTerminalSymlink(canonical, fileManager: fileManager)
        let values = try canonical.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw invalidPath("Sensitive storage must be a non-symlink regular file.")
        }
        if let maximumBytes,
           (values.fileSize ?? maximumBytes + 1) > maximumBytes {
            throw invalidPath("Sensitive storage exceeds its maximum size.")
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: canonical.path)
        try verifyMode(0o600, at: canonical, fileManager: fileManager)
    }

    static func resolveContainedDirectory(
        path: String,
        within configuredRoot: URL,
        fileManager: FileManager
    ) throws -> URL {
        let root = configuredRoot.standardizedFileURL
        try rejectTerminalSymlink(root, fileManager: fileManager)
        let rootValues = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw invalidPath("Containment root must be a non-symlink directory.")
        }

        let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw invalidPath("Directory is outside the configured containment root.")
        }
        try rejectTerminalSymlink(candidate, fileManager: fileManager)
        let candidateValues = try candidate.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard candidateValues.isDirectory == true,
              candidateValues.isSymbolicLink != true else {
            throw invalidPath("Contained path must be a non-symlink directory.")
        }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw invalidPath("Directory resolves outside the configured containment root.")
        }
        return resolvedCandidate
    }

    private static func canonicalURL(
        _ value: String,
        isDirectory: Bool
    ) throws -> URL {
        guard !value.isEmpty,
              !value.contains("\0"),
              (value as NSString).isAbsolutePath else {
            throw invalidPath("Settings paths must be absolute.")
        }
        return URL(fileURLWithPath: value, isDirectory: isDirectory).standardizedFileURL
    }

    private static func rejectTerminalSymlink(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw invalidPath("Configured storage paths must not be symbolic links.")
        }
    }

    private static func verifyMode(
        _ expected: Int,
        at url: URL,
        fileManager: FileManager
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actual = (attributes[.posixPermissions] as? NSNumber)?.intValue
        guard actual == expected else {
            throw NativeServiceError.server(
                status: 500,
                code: "STORAGE_PERMISSIONS",
                message: "Sensitive storage permissions could not be secured."
            )
        }
    }

    private static func invalidPath(_ message: String) -> NativeServiceError {
        NativeServiceError.server(status: 400, code: "STORAGE_PATH_INVALID", message: message)
    }
}
