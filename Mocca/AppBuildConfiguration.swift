import Foundation

/// Build settings are expanded into Info.plist by Xcode, independently of DEBUG.
enum AppBuildConfiguration {
    // Missing or unresolved values leave commerce disabled.
    static let sponsorshipEnabled =
        Bundle.main.object(forInfoDictionaryKey: "MoccaSponsorshipEnabled") as? String == "YES"

    static let qqGroupInvitationURL: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MoccaQQGroupInvitationURL") as? String,
              let url = URL(string: value),
              url.scheme == "https",
              let host = url.host,
              ["qun.qq.com", "qm.qq.com"].contains(host) else { return nil }
        return url
    }()

    // Must match BGTaskSchedulerPermittedIdentifiers in the built Info.plist.
    static let backgroundTaskIdentifierPrefix =
        (Bundle.main.bundleIdentifier ?? "org.example.mocca") + ".background-generation"
}
