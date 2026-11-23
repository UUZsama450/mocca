import Foundation

/// Upgrade cleanup for retired, app-owned diagnostic artifacts only.
/// This does not observe UI events or produce new files or preferences.
enum RetiredDiagnosticCleanup {
    nonisolated static let relativePaths = [
        "Library/Application Support/TouchFlight-v1",
        "tmp/TouchFlightExports",
        "tmp/MoccaTouchDiagnostics",
        "tmp/mocca-touch-recurrence-5335.json",
        "tmp/Mocca-lift-timing.txt"
    ]

    /// Returns failed paths so callers/tests can check retryable cleanup errors.
    /// Missing paths are already clean; no directory-wide or prefix deletion.
    nonisolated static func run(container: URL, defaults: UserDefaults) -> [String] {
        var failures: [String] = []
        for path in relativePaths {
            do {
                try FileManager.default.removeItem(at: container.appendingPathComponent(path))
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                continue
            } catch {
                failures.append(path)
            }
        }
        defaults.removeObject(forKey: "mocca.touchFlight.enabled.v1")
        return failures
    }
}
