import Foundation

/// Gives opt-in tests an actual Swift Testing skip when disabled and emits a
/// stable marker only after a requested runtime check reaches its success path.
enum NativeRuntimeEvidence {
    static func isRequested(_ environmentKey: String, allowAuto: Bool = false) -> Bool {
        switch ProcessInfo.processInfo.environment[environmentKey] {
        case "1": true
        case "auto": allowAuto
        default: false
        }
    }

    static func record(_ marker: String) {
        precondition(
            !marker.isEmpty && marker.utf8.allSatisfy {
                ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
            },
            "Runtime evidence markers must use lowercase ASCII identifiers."
        )
        print("WHEREWE_RUNTIME_EVIDENCE \(marker)")
    }
}
