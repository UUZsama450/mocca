import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Runs the complete production resolver and thumbnail cache on macOS. This
/// verifies identity/decoding semantics, not SwiftUI or iPhone frame times.
@main
@MainActor
enum SearchResultAvatarHostTests {
    private static var assertions = 0

    static func main() async throws {
        identityCases()
        descriptorCases()
        try await imageCases()
        print("SEARCH_RESULT_AVATAR_HOST_TESTS=PASS assertions=\(assertions)")
        print("SCOPE=production identity resolver and ImageIO cache on macOS; no simulator, device, UI, or frame-time acceptance")
    }

    private static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        guard value() else { fatalError("SEARCH_RESULT_AVATAR_HOST_TESTS=FAIL \(label)") }
    }

    private static func identityCases() {
        let available: Set<String> = ["owner", "other", "group-author"]
        func resolve(_ author: String?, _ owner: String?, group: Bool = false) -> String? {
            SearchResultAuthorResolver.assistantID(
                messageAuthorID: author, messageID: "message-id", conversationAssistantID: owner,
                isGroupChat: group, availableAssistantIDs: available
            )
        }
        check(resolve("other", "owner") == "other", "exact message author precedes chat owner")
        check(resolve("message-id", "owner") == "owner", "legacy missing-author self-ID sentinel uses chat owner")
        check(resolve(nil, "owner") == "owner", "missing single author uses its own chat owner")
        check(resolve("", "owner") == "owner", "empty single author uses its own chat owner")
        check(resolve(" \t\n", "owner") == "owner", "whitespace-only single author uses its own chat owner")
        check(resolve("deleted-author", "owner") == nil, "explicit removed author never becomes current chat owner")
        check(resolve("different-message-id", "owner") == nil, "arbitrary unresolved non-self ID stays unknown")
        check(resolve("group-author", "owner", group: true) == "group-author", "group reply uses exact author")
        check(resolve("deleted", "owner", group: true) == nil, "missing group author never guesses chat owner")
        check(resolve(nil, "owner", group: true) == nil, "missing group author stays unknown")
        check(resolve("message-id", "owner", group: true) == nil, "group self-ID sentinel never guesses an author")
        check(resolve("deleted", "removed") == nil, "orphan single chat never uses current assistant")
        check(resolve(nil, nil) == nil, "fully missing ownership is neutral")
        check(SearchResultAuthorResolver.assistantID(
            messageAuthorID: "owner", messageID: "owner", conversationAssistantID: "other",
            isGroupChat: false, availableAssistantIDs: available
        ) == "owner", "known author takes precedence even if IDs equal")
    }

    private static func descriptorCases() {
        let user = SearchResultAvatarDescriptor.user(name: "用户名字", imageSource: nil)
        check(user.isUser && user.authorName == "用户名字", "user keeps user role and name")
        let unknown = SearchResultAvatarDescriptor.assistant(name: nil, avatar: nil)
        check(!unknown.isUser && unknown.authorName == "未知助手", "unknown assistant label and fallback")
        let emoji = SearchResultAvatarDescriptor.assistant(name: "Emoji", avatar: "  🐈  ")
        check(emoji.emoji == "🐈" && emoji.imageSource == nil, "emoji needs no image work")
        let asset = SearchResultAvatarDescriptor.assistant(name: "Asset", avatar: "asset:DefaultAssistantAvatar")
        check(asset.assetName == "DefaultAssistantAvatar" && asset.imageSource == nil, "bundled asset needs no custom decode")
        for path in ["file:", "file:..", "file:.", "file:../avatar.jpg", "file:sub/file.jpg", "file:sub\\file.jpg"] {
            let invalid = SearchResultAvatarDescriptor.assistant(name: "Invalid", avatar: path)
            check(invalid.imageSource == nil && invalid.emoji == nil, "reject invalid storage path \(path)")
        }
        let local = SearchResultAvatarDescriptor.assistant(name: "Local", avatar: "file:avatar-123.jpg")
        check(local.imageSource?.key == "file:avatar-123.jpg", "local reference has stable key")
        if case let .file(url) = local.imageSource?.storage {
            check(url.isFileURL && url.lastPathComponent == "avatar-123.jpg", "file references stay local")
            check(url.deletingLastPathComponent().lastPathComponent == "AssistantMedia", "file scope is AssistantMedia")
        } else {
            check(false, "local source exists")
        }
        check(SearchResultAvatarImageSource.userJPEG(nil) == nil, "absent user avatar has no task")
        let data = Data([1, 2, 3])
        check(SearchResultAvatarImageSource.userJPEG(data)?.key == SearchResultAvatarImageSource.userJPEG(data)?.key,
              "same user bytes reuse stable key")
        check(SearchResultAvatarImageSource.userJPEG(data)?.key != SearchResultAvatarImageSource.userJPEG(Data([1, 2, 4]))?.key,
              "changed user bytes invalidate image key")
    }

    private static func jpeg(orientation: Int = 1) -> Data {
        let context = CGContext(
            data: nil, width: 2048, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.35, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation
        ] as CFDictionary)
        check(CGImageDestinationFinalize(destination), "synthetic JPEG encodes")
        return data as Data
    }

    private static func imageCases() async throws {
        let data = jpeg()
        let request = SearchResultAvatarImageRequest(
            source: SearchResultAvatarImageSource.userJPEG(data)!, maximumPixelSize: 60
        )
        check(SearchResultAvatarImageCache.cachedEntry(for: request) == nil, "new source starts cold")
        let entries = await withTaskGroup(of: SearchResultAvatarImageCache.Entry?.self) { group in
            for _ in 0..<32 {
                group.addTask { await SearchResultAvatarImageCache.entry(for: request) }
            }
            var entries: [SearchResultAvatarImageCache.Entry] = []
            for await entry in group { if let entry { entries.append(entry) } }
            return entries
        }
        check(entries.count == 32, "all concurrent callers receive result")
        check(entries.allSatisfy { $0 === entries[0] }, "same-key requests share one cache entry")
        check(entries[0].image?.width == 60 && entries[0].image?.height == 30, "2048px user JPEG downsampled to display pixels")
        let warm = await SearchResultAvatarImageCache.entry(for: request)
        check(warm === entries[0], "warm lookup reuses decoded image")
        let smaller = await SearchResultAvatarImageCache.entry(for: SearchResultAvatarImageRequest(
            source: request.source, maximumPixelSize: 20
        ))
        check(smaller?.image?.width == 20 && smaller?.image?.height == 10, "size participates in cache key")

        let oriented = await SearchResultAvatarImageCache.entry(for: SearchResultAvatarImageRequest(
            source: SearchResultAvatarImageSource.userJPEG(jpeg(orientation: 6))!, maximumPixelSize: 60
        ))
        check(oriented?.image?.width == 30 && oriented?.image?.height == 60, "EXIF orientation applied during decode")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic-avatar.jpg")
        try data.write(to: url)
        let fileRequest = SearchResultAvatarImageRequest(
            source: .init(key: url.path, storage: .file(url)), maximumPixelSize: 60
        )
        let fileEntry = await SearchResultAvatarImageCache.entry(for: fileRequest)
        check(fileEntry?.image?.width == 60, "assistant file uses downsampled decode")
        try FileManager.default.removeItem(at: url)
        let fileWarm = await SearchResultAvatarImageCache.entry(for: fileRequest)
        check(fileWarm === fileEntry, "warm file lookup succeeds without disk file")

        let invalid = SearchResultAvatarImageRequest(
            source: .init(key: "invalid-data", storage: .data(Data("not an image".utf8))), maximumPixelSize: 60
        )
        let failed = await SearchResultAvatarImageCache.entry(for: invalid)
        let failedWarm = await SearchResultAvatarImageCache.entry(for: invalid)
        check(failed != nil && failed?.image == nil, "invalid bytes produce fallback entry")
        check(failed === failedWarm, "invalid bytes cached to avoid repeated decoding")
        let missing = await SearchResultAvatarImageCache.entry(for: SearchResultAvatarImageRequest(
            source: .init(key: "missing-file", storage: .file(url)), maximumPixelSize: 60
        ))
        check(missing != nil && missing?.image == nil, "missing file produces fallback")
        let cancelled = Task { @MainActor in
            await Task.yield()
            return await SearchResultAvatarImageCache.entry(for: request)
        }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        check(cancelledResult == nil, "cancelled row does not start a request")
    }
}
