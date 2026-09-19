import Foundation

/// Build settings are expanded into Info.plist by Xcode, independently of DEBUG.
enum AppBuildConfiguration {
    // Missing or unresolved values leave commerce disabled.
    static let sponsorshipEnabled =
        Bundle.main.object(forInfoDictionaryKey: "MoccaSponsorshipEnabled") as? String == "YES"

    // Must match BGTaskSchedulerPermittedIdentifiers in the built Info.plist.
    static let backgroundTaskIdentifierPrefix =
        (Bundle.main.bundleIdentifier ?? "org.example.mocca") + ".background-generation"
}
