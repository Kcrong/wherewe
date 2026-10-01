import Foundation

enum NativeDocumentPathPolicy {
    enum Operation: Equatable {
        case read
        case delete
    }

    private static let maximumReadableBytes = 5 * 1_024 * 1_024

    static func resolveStoredFile(
        path: String,
        within configuredRoot: URL,
        operation: Operation,
        fileManager: FileManager
    ) throws -> URL {
        let root = configuredRoot.standardizedFileURL
        let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues?.isDirectory == true, rootValues?.isSymbolicLink != true else {
            throw invalidPath()
        }

        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw invalidPath()
        }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw invalidPath()
        }

        let candidateValues = try? candidate.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard candidateValues?.isSymbolicLink != true else {
            throw invalidPath()
        }
        guard let values = try? resolvedCandidate.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ) else {
            if operation == .delete { return resolvedCandidate }
            throw invalidPath()
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw invalidPath()
        }
        if operation == .read,
           (values.fileSize ?? maximumReadableBytes + 1) > maximumReadableBytes {
            throw invalidPath()
        }
        return resolvedCandidate
    }

    private static func invalidPath() -> NativeServiceError {
        NativeServiceError.server(
            status: 410,
            code: "DOCUMENT_PATH_INVALID",
            message: "Stored attachment path is outside the configured files directory or is not a safe regular file."
        )
    }
}
