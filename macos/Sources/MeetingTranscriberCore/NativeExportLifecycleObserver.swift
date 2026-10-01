import Foundation

struct NativeExportLifecycleObserver: Sendable {
    let afterDirectoryCreation: @Sendable (URL) async -> Void

    init(
        afterDirectoryCreation: @escaping @Sendable (URL) async -> Void = { _ in }
    ) {
        self.afterDirectoryCreation = afterDirectoryCreation
    }
}

extension NativeService {
    func setExportLifecycleObserver(_ observer: NativeExportLifecycleObserver) {
        exportLifecycleObserver = observer
    }
}
