import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif

/// Search spans assistants, so resolving against the selected chat would show
/// the wrong owner. A group reply without a known author stays unidentified.
enum SearchResultAuthorResolver {
    static func assistantID(
        messageAuthorID: String?,
        messageID: String,
        conversationAssistantID: String?,
        isGroupChat: Bool,
        availableAssistantIDs: Set<String>
    ) -> String? {
        if let messageAuthorID, availableAssistantIDs.contains(messageAuthorID) {
            return messageAuthorID
        }
        // Older native initializers and legacy imports put the message's own
        // ID here when its author is absent. Other unknown IDs may identify a
        // deleted author and must not be attributed to a different chat owner.
        let lacksAuthor = messageAuthorID == nil
            || messageAuthorID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            || messageAuthorID == messageID
        guard lacksAuthor, !isGroupChat,
              let conversationAssistantID,
              availableAssistantIDs.contains(conversationAssistantID) else { return nil }
        return conversationAssistantID
    }
}

struct SearchResultAvatarImageSource: Sendable {
    enum Storage: Sendable {
        case file(URL)
        case data(Data)
    }

    let key: String
    let storage: Storage

    /// Called once per search request, before building any rows. Rows reuse the
    /// key and data storage, rather than hashing or decoding the user's JPEG.
    static func userJPEG(_ data: Data?) -> Self? {
        guard let data else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Self(key: "user:\(digest)", storage: .data(data))
    }
}

struct SearchResultAvatarDescriptor: Sendable {
    let isUser: Bool
    let authorName: String
    let imageSource: SearchResultAvatarImageSource?
    let assetName: String?
    let emoji: String?

    static func user(name: String, imageSource: SearchResultAvatarImageSource?) -> Self {
        Self(isUser: true, authorName: name, imageSource: imageSource, assetName: nil, emoji: nil)
    }

    static func assistant(name: String?, avatar: String?) -> Self {
        var imageSource: SearchResultAvatarImageSource?
        var assetName: String?
        var emoji: String?
        if let avatar {
            if avatar.hasPrefix("file:") {
                let name = String(avatar.dropFirst("file:".count))
                if !name.isEmpty, name != ".", name != "..",
                   !name.contains("/"), !name.contains("\\"),
                   let root = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                   ).first {
                    imageSource = SearchResultAvatarImageSource(
                        key: avatar,
                        storage: .file(root.appendingPathComponent("AssistantMedia", isDirectory: true)
                            .appendingPathComponent(name))
                    )
                }
            } else if avatar.hasPrefix("asset:") {
                let name = String(avatar.dropFirst("asset:".count))
                assetName = name.isEmpty ? nil : name
            } else {
                let cleaned = avatar.trimmingCharacters(in: .whitespacesAndNewlines)
                emoji = cleaned.isEmpty ? nil : cleaned
            }
        }
        return Self(
            isUser: false,
            authorName: name ?? "未知助手",
            imageSource: imageSource,
            assetName: assetName,
            emoji: emoji
        )
    }
}

struct SearchResultAvatarImageRequest: Sendable {
    let source: SearchResultAvatarImageSource
    let maximumPixelSize: Int

    var key: String { "\(source.key)#\(maximumPixelSize)" }
}

@MainActor
enum SearchResultAvatarImageCache {
    @MainActor
    final class Entry: NSObject {
        let image: CGImage?

        init(image: CGImage?) {
            self.image = image
        }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()
    private static let decodingQueue = DispatchQueue(
        label: "com.mocca.search-avatar-decoding", qos: .userInitiated
    )
    private static var inFlight: [String: Task<Entry, Never>] = [:]

    static func cachedEntry(for request: SearchResultAvatarImageRequest) -> Entry? {
        cache.object(forKey: request.key as NSString)
    }

    static func entry(for request: SearchResultAvatarImageRequest) async -> Entry? {
        guard !Task.isCancelled else { return nil }
        if let cached = cachedEntry(for: request) { return cached }
        if let pending = inFlight[request.key] { return await pending.value }

        // Only mounted search rows request images. A shared decode may finish
        // after a row disappears; the cancelled row cannot publish that result.
        let pending = Task { @MainActor in
            let image = await withCheckedContinuation { continuation in
                decodingQueue.async {
                    let image = autoreleasepool { decode(request) }
                    continuation.resume(returning: image)
                }
            }
            let entry = Entry(image: image)
            cache.setObject(
                entry,
                forKey: request.key as NSString,
                cost: image.map { $0.bytesPerRow * $0.height } ?? 1
            )
            inFlight[request.key] = nil
            return entry
        }
        inFlight[request.key] = pending
        return await pending.value
    }

    nonisolated private static func decode(_ request: SearchResultAvatarImageRequest) -> CGImage? {
        guard request.maximumPixelSize > 0 else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource?
        switch request.source.storage {
        case let .file(url):
            source = CGImageSourceCreateWithURL(url as CFURL, options)
        case let .data(data):
            source = CGImageSourceCreateWithData(data as CFData, options)
        }
        guard let source else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: request.maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
        )
    }
}

#if canImport(UIKit)
struct SearchResultAvatar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let descriptor: SearchResultAvatarDescriptor
    var size: CGFloat = 20

    @State private var result: Result?

    private struct Result {
        let key: String
        let entry: SearchResultAvatarImageCache.Entry
    }

    var body: some View {
        let request = descriptor.imageSource.map {
            SearchResultAvatarImageRequest(
                source: $0, maximumPixelSize: max(1, Int((size * displayScale).rounded(.down)))
            )
        }
        let currentResult = result?.key == request?.key ? result : nil
        let image = request.flatMap { SearchResultAvatarImageCache.cachedEntry(for: $0)?.image }
            ?? currentResult?.entry.image

        Group {
            if let image {
                Image(uiImage: UIImage(cgImage: image))
                    .resizable()
                    .scaledToFill()
            } else if let assetName = descriptor.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
            } else if let emoji = descriptor.emoji {
                Circle().fill(themeAccent.opacity(0.11))
                    .overlay {
                        Text(emoji).font(.system(size: size * 0.5))
                    }
            } else {
                Circle().fill(themeAccent.opacity(0.12))
                    .overlay {
                        Image(descriptor.isUser ? "DefaultUserAvatar" : "DefaultAssistantAvatar")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(themeAccent)
                            .padding(size * 0.16)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(L10n.format("%@的消息", [descriptor.authorName]))
        .task(id: request?.key) {
            guard let request,
                  let entry = await SearchResultAvatarImageCache.entry(for: request),
                  !Task.isCancelled else { return }
            result = Result(key: request.key, entry: entry)
        }
    }

    private var themeAccent: Color {
        Color(uiColor: model.themeAccentUIColor)
    }
}
#endif
