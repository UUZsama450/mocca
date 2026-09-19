import CoreText
import CryptoKit
import Foundation
import SwiftUI
import UIKit

struct AppFontSelection: Hashable, Sendable {
    let fileName: String
    let postScriptName: String
    let displayName: String
}

enum AppFontStore {
    enum FontError: LocalizedError {
        case unsupportedFormat
        case unreadableFile
        case registrationFailed
        case missingStoredFont
        case googleFontDownloadFailed
        case googleFontIntegrityFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                ErrorLocalization.lookup("请选择 TTF、OTF 或 TTC 字体文件。")
            case .unreadableFile:
                ErrorLocalization.lookup("无法读取这个字体文件。")
            case .registrationFailed:
                ErrorLocalization.lookup("这个文件不是 iOS 可以使用的字体，或字体已损坏。")
            case .missingStoredFont:
                ErrorLocalization.lookup("已保存的字体文件不存在，请重新导入。")
            case .googleFontDownloadFailed:
                ErrorLocalization.lookup("无法从 Google Fonts 下载这个字体，请检查网络后重试。")
            case .googleFontIntegrityFailed:
                ErrorLocalization.lookup("下载到的字体文件未通过完整性校验，请稍后重试。")
            }
        }
    }

    static let allowedExtensions = Set(["ttf", "otf", "ttc"])

    static func importFont(from sourceURL: URL) throws -> AppFontSelection {
        let ext = sourceURL.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { throw FontError.unsupportedFormat }

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let directory = try fontsDirectory()
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw FontError.unreadableFile
        }

        do {
            return try registerFont(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func registerStoredFont(fileName: String) throws -> AppFontSelection {
        let url = try fontsDirectory().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FontError.missingStoredFont
        }
        return try registerFont(at: url)
    }

    static func previewGoogleFont(_ entry: GoogleFontCatalogEntry) async throws -> AppFontSelection {
        let cachedURL = try await cachedGoogleFontURL(for: entry)
        try Task.checkCancellation()
        let registered = try registerFont(at: cachedURL)
        return AppFontSelection(
            fileName: cachedURL.lastPathComponent,
            postScriptName: registered.postScriptName,
            displayName: entry.family
        )
    }

    static func installGoogleFont(_ entry: GoogleFontCatalogEntry) async throws -> AppFontSelection {
        let cachedURL = try await cachedGoogleFontURL(for: entry)
        try Task.checkCancellation()

        let directory = try fontsDirectory()
        let destination = directory.appendingPathComponent("google-\(entry.fileHash).ttf")
        if !hasExpectedLength(at: destination, expectedLength: entry.expectedLength) {
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: cachedURL, to: destination)
            } catch {
                throw FontError.unreadableFile
            }
        }

        do {
            let registered = try registerFont(at: destination)
            return AppFontSelection(
                fileName: destination.lastPathComponent,
                postScriptName: registered.postScriptName,
                displayName: entry.family
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func deleteStoredFont(fileName: String?) {
        guard let fileName, !fileName.isEmpty,
              let directory = try? fontsDirectory() else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    static func uiFont(
        postScriptName: String?,
        size: CGFloat,
        weight: UIFont.Weight = .regular
    ) -> UIFont {
        guard let postScriptName,
              !postScriptName.isEmpty,
              let font = UIFont(name: postScriptName, size: size) else {
            return UIFont.systemFont(ofSize: size, weight: weight)
        }
        guard weight.rawValue >= UIFont.Weight.semibold.rawValue,
              let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func swiftUIFont(
        postScriptName: String?,
        size: CGFloat,
        weight: Font.Weight = .regular,
        fixedCustomSize: Bool = false
    ) -> Font {
        guard let postScriptName, !postScriptName.isEmpty else {
            return .system(size: size, weight: weight)
        }
        let font: Font = fixedCustomSize
            ? .custom(postScriptName, fixedSize: size)
            : .custom(postScriptName, size: size)
        return font.weight(weight)
    }

    /// Imported and catalog fonts commonly expose only a Regular face. When
    /// that face also lacks CJK glyphs, TextKit falls back to regular PingFang
    /// even if Markdown requested a bold heading. A small filled stroke keeps
    /// the selected font while restoring the requested visual hierarchy.
    static func syntheticStrokeWidth(
        postScriptName: String?,
        resolvedFont: UIFont,
        weight: UIFont.Weight
    ) -> CGFloat? {
        guard let postScriptName,
              !postScriptName.isEmpty,
              weight.rawValue >= UIFont.Weight.medium.rawValue,
              let sourceFont = UIFont(name: postScriptName, size: resolvedFont.pointSize) else {
            return nil
        }

        if sourceFont.fontDescriptor.symbolicTraits.contains(.traitBold) {
            return nil
        }

        // A different PostScript face means UIKit resolved a real registered
        // weight. Matching names indicate a single-face font (or a synthetic
        // descriptor whose fallback glyphs still lose the requested weight).
        let registeredFamilyFaces = UIFont.fontNames(forFamilyName: sourceFont.familyName)
        if resolvedFont.fontName != sourceFont.fontName,
           registeredFamilyFaces.contains(resolvedFont.fontName) {
            return nil
        }

        if weight.rawValue >= UIFont.Weight.bold.rawValue {
            return -3.0
        }
        if weight.rawValue >= UIFont.Weight.semibold.rawValue {
            return -2.15
        }
        return -1.15
    }

    private static func fontsDirectory() throws -> URL {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw FontError.unreadableFile
        }
        let directory = root.appendingPathComponent("AppFonts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func cachedGoogleFontURL(for entry: GoogleFontCatalogEntry) async throws -> URL {
        guard let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw FontError.unreadableFile
        }
        let directory = cacheRoot.appendingPathComponent("GoogleFonts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw FontError.unreadableFile
        }

        let destination = directory.appendingPathComponent("\(entry.fileHash).ttf")
        if hasExpectedLength(at: destination, expectedLength: entry.expectedLength) {
            return destination
        }
        try? FileManager.default.removeItem(at: destination)

        do {
            var request = URLRequest(url: entry.downloadURL)
            request.timeoutInterval = 45
            request.setValue("Mocca/4829", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw FontError.googleFontDownloadFailed
            }
            guard data.count == entry.expectedLength,
                  SHA256.hash(data: data).hexString == entry.fileHash else {
                throw FontError.googleFontIntegrityFailed
            }
            try data.write(to: destination, options: .atomic)
            return destination
        } catch let error as FontError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FontError.googleFontDownloadFailed
        }
    }

    private static func hasExpectedLength(at url: URL, expectedLength: Int) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              values.fileSize == expectedLength else {
            return false
        }
        return true
    }

    private static func registerFont(at url: URL) throws -> AppFontSelection {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let postScriptName = CTFontDescriptorCopyAttribute(
                descriptor,
                kCTFontNameAttribute
              ) as? String,
              !postScriptName.isEmpty else {
            throw FontError.registrationFailed
        }

        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard UIFont(name: postScriptName, size: 17) != nil else {
            throw FontError.registrationFailed
        }

        let displayName = (CTFontDescriptorCopyAttribute(
            descriptor,
            kCTFontDisplayNameAttribute
        ) as? String) ?? postScriptName
        return AppFontSelection(
            fileName: url.lastPathComponent,
            postScriptName: postScriptName,
            displayName: displayName
        )
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private struct OptionalAppFontModifier: ViewModifier {
    let postScriptName: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let postScriptName, !postScriptName.isEmpty {
            content.font(.custom(postScriptName, size: 17, relativeTo: .body))
        } else {
            content
        }
    }
}

extension View {
    func appFontEnvironment(_ postScriptName: String?) -> some View {
        modifier(OptionalAppFontModifier(postScriptName: postScriptName))
    }
}
