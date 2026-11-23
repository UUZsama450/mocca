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

struct AvatarImageSource: Sendable {
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
    let imageSource: AvatarImageSource?
    let assetName: String?
    let emoji: String?

    static func user(name: String, imageSource: AvatarImageSource?) -> Self {
        Self(isUser: true, authorName: name, imageSource: imageSource, assetName: nil, emoji: nil)
    }

    static func assistant(name: String?, avatar: String?) -> Self {
        var imageSource: AvatarImageSource?
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
                    imageSource = AvatarImageSource(
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

struct AvatarImageRequest: Sendable {
    enum Sizing: Sendable { case fit, fillSquare }
    let source: AvatarImageSource
    let maximumPixelSize: Int
    var sizing: Sizing = .fit

    var key: String {
        "\(source.key)#\(maximumPixelSize)" + (sizing == .fillSquare ? "#square" : "")
    }
}

@MainActor
enum AvatarImageCache {
    @MainActor
    final class Entry: NSObject {
        let image: CGImage?
        #if canImport(UIKit)
        let uiImage: UIImage?
        #endif

        init(image: CGImage?) {
            self.image = image
            #if canImport(UIKit)
            self.uiImage = image.map { UIImage(cgImage: $0) }
            #endif
        }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()
    private static let decodingQueue = DispatchQueue(
        label: "com.mocca.avatar-decoding", qos: .userInitiated
    )
    private static var inFlight: [String: Task<Entry, Never>] = [:]

    static func cachedEntry(for request: AvatarImageRequest) -> Entry? {
        cache.object(forKey: request.key as NSString)
    }

    static func entry(for request: AvatarImageRequest) async -> Entry? {
        guard !Task.isCancelled else { return nil }
        if let cached = cachedEntry(for: request) { return cached }
        if let pending = inFlight[request.key] { return await pending.value }

        // Only mounted avatars request images. A shared decode may finish
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

    nonisolated private static func decode(_ request: AvatarImageRequest) -> CGImage? {
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
        var decodeSize = request.maximumPixelSize
        if request.sizing == .fillSquare,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            let shortest = min(width.doubleValue, height.doubleValue)
            let longest = max(width.doubleValue, height.doubleValue)
            guard shortest > 0, longest.isFinite else { return nil }
            // Aspect-fill needs enough pixels on the short edge. Bound the
            // intermediate decode for extremely wide imported images.
            decodeSize = Int(min(4096, longest, ceil(Double(decodeSize) * longest / shortest)))
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: decodeSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
        ) else { return nil }
        guard request.sizing == .fillSquare else { return image }
        let side = min(request.maximumPixelSize, image.width, image.height)
        guard side > 0,
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let scale = CGFloat(side) / CGFloat(min(image.width, image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2,
                                      y: (CGFloat(side) - height) / 2,
                                      width: width, height: height))
        return context.makeImage()
    }
}

#if canImport(UIKit)
/// Shares warm images immediately and keeps asynchronous results tied to their
/// source and size, including when an editor replaces or removes its draft.
struct CachedAvatarImage<Placeholder: View>: View {
    let request: AvatarImageRequest?
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var result: Result?

    private struct Result {
        let key: String
        let entry: AvatarImageCache.Entry
    }

    var body: some View {
        let currentResult = result?.key == request?.key ? result : nil
        let entry = request.flatMap { AvatarImageCache.cachedEntry(for: $0) }
            ?? currentResult?.entry
        Group {
            if let image = entry?.uiImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: request?.key) {
            guard let request,
                  let entry = await AvatarImageCache.entry(for: request),
                  !Task.isCancelled else { return }
            result = Result(key: request.key, entry: entry)
        }
    }
}

struct SearchResultAvatar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let descriptor: SearchResultAvatarDescriptor
    var size: CGFloat = 20

    var body: some View {
        let request = descriptor.imageSource.map {
            AvatarImageRequest(
                source: $0, maximumPixelSize: max(1, Int((size * displayScale).rounded(.down)))
            )
        }
        CachedAvatarImage(request: request) {
            if let assetName = descriptor.assetName {
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
    }

    private var themeAccent: Color {
        Color(uiColor: model.themeAccentUIColor)
    }
}
#endif
