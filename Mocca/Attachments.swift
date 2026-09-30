import CryptoKit
import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AttachmentStore {
    struct FileImportInspection: Sendable {
        let sourceURL: URL
        let fileName: String
        let kind: MessageAttachment.Kind
        let mimeType: String?
        let byteCount: Int64
        let contentSHA256: String
        let duplicate: MessageAttachment?
    }

    struct ReclaimResult {
        var removedFileCount = 0
        var removedByteCount: Int64 = 0
    }

    static let contentSHA256MetadataKey = "content_sha256"
    static let pastedTextMetadataKey = "mocca_pasted_text"
    private static let pastedTextMetadataVersion = "utf8_v1"
    private static let maxImageDimension: CGFloat = 2048
    private static let textPreviewCharacterLimit = 60_000
    private static let hashReadChunkSize = 1_048_576

    static func directory() throws -> URL {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ConversationStoreError.missingApplicationSupport
        }
        let directory = root.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func resolvePersistedLocalURL(_ reference: String?) -> URL? {
        guard let reference, !reference.isEmpty else { return nil }
        let parsedURL = URL(string: reference)
        let storageName: String
        if parsedURL?.scheme != nil {
            storageName = parsedURL?.lastPathComponent ?? ""
        } else {
            storageName = (reference as NSString).lastPathComponent
        }
        guard !storageName.isEmpty,
              storageName != ".",
              storageName != "/",
              let currentDirectory = try? directory() else {
            return parsedURL
        }
        return currentDirectory.appendingPathComponent(storageName)
    }

    static func persistedLocalReference(for url: URL?) -> String? {
        guard let storageName = url?.lastPathComponent,
              !storageName.isEmpty else { return nil }
        return storageName
    }

    static func saveImage(_ image: UIImage, quality: Int = 100) -> MessageAttachment? {
        let scaled = downscaled(image)
        let compressionQuality = CGFloat(min(max(quality, 1), 100)) / 100
        guard let data = scaled.jpegData(compressionQuality: compressionQuality),
              let directory = try? directory() else {
            return nil
        }
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).jpg")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return MessageAttachment(
            id: id,
            kind: .image,
            localURL: url,
            fileName: url.lastPathComponent,
            mimeType: "image/jpeg",
            byteCount: Int64(data.count)
        )
    }

    /// Persist an image returned by a provider without recompressing it.
    static func saveGeneratedImage(data: Data, mimeType: String) -> MessageAttachment? {
        guard !data.isEmpty,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let directory = try? directory() else {
            return nil
        }

        let type = UTType(mimeType: mimeType)
        let fileExtension = type?.preferredFilenameExtension ?? "png"
        let id = UUID()
        let destination = directory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
        guard (try? data.write(to: destination, options: .atomic)) != nil else { return nil }

        return MessageAttachment(
            id: id,
            kind: .image,
            localURL: destination,
            fileName: destination.lastPathComponent,
            mimeType: type?.preferredMIMEType ?? mimeType,
            byteCount: Int64(data.count),
            metadata: ["source": "openai_responses_image_generation"]
        )
    }

    static func savePastedText(_ text: String) async throws -> MessageAttachment {
        let saved = try await PastedTextAttachmentIO.save(text) {
            try directory()
        }
        return MessageAttachment(
            id: saved.id,
            kind: .file,
            localURL: saved.url,
            fileName: "粘贴文本.txt",
            mimeType: "text/plain",
            byteCount: saved.byteCount,
            metadata: [
                pastedTextMetadataKey: pastedTextMetadataVersion,
                contentSHA256MetadataKey: saved.sha256
            ]
        )
    }

    static func isPastedText(_ attachment: MessageAttachment) -> Bool {
        attachment.metadata[pastedTextMetadataKey] == pastedTextMetadataVersion
    }

    static func readPastedTextContent(of attachment: MessageAttachment) async throws -> String {
        guard isPastedText(attachment), attachment.kind == .file,
              attachment.mimeType == "text/plain",
              let url = attachment.localURL,
              let byteCount = attachment.byteCount,
              let hash = attachment.metadata[contentSHA256MetadataKey] else {
            throw PastedTextAttachmentError.invalidAttachment
        }
        return try await PastedTextAttachmentIO.read(
            from: url, expectedByteCount: byteCount, expectedSHA256: hash
        )
    }

    static func inspectFileForImport(
        from sourceURL: URL,
        existingAttachments: [MessageAttachment]
    ) async -> FileImportInspection? {
        await Task.detached(priority: .userInitiated) {
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            guard let byteCount = regularFileByteCount(at: sourceURL),
                  let contentSHA256 = try? sha256Hex(of: sourceURL) else {
                return nil
            }

            let type = UTType(filenameExtension: sourceURL.pathExtension)
            let kind: MessageAttachment.Kind = type?.conforms(to: .image) == true
                ? .image
                : .file
            var seenStorageReferences = Set<String>()
            let duplicate = existingAttachments.first { attachment in
                guard let localURL = attachment.localURL,
                      FileManager.default.fileExists(atPath: localURL.path),
                      let storageReference = persistedLocalReference(for: localURL),
                      seenStorageReferences.insert(storageReference).inserted,
                      (attachment.byteCount ?? regularFileByteCount(at: localURL)) == byteCount else {
                    return false
                }
                let existingHash = attachment.metadata[contentSHA256MetadataKey]
                    ?? (try? sha256Hex(of: localURL))
                return existingHash == contentSHA256
            }

            return FileImportInspection(
                sourceURL: sourceURL,
                fileName: sourceURL.lastPathComponent,
                kind: kind,
                mimeType: type?.preferredMIMEType,
                byteCount: byteCount,
                contentSHA256: contentSHA256,
                duplicate: duplicate
            )
        }.value
    }

    static func importFile(
        from sourceURL: URL,
        contentSHA256: String? = nil
    ) -> MessageAttachment? {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        guard let directory = try? directory() else { return nil }
        let id = UUID()
        let fileName = sourceURL.lastPathComponent
        let destination = directory.appendingPathComponent("\(id.uuidString)_\(fileName)")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            return nil
        }

        let type = UTType(filenameExtension: sourceURL.pathExtension)
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
        let isImage = type?.conforms(to: .image) ?? false
        return MessageAttachment(
            id: id,
            kind: isImage ? .image : .file,
            localURL: destination,
            fileName: fileName,
            mimeType: type?.preferredMIMEType,
            byteCount: byteCount,
            metadata: contentSHA256.map { [contentSHA256MetadataKey: $0] } ?? [:]
        )
    }

    static func reuseFile(
        from existing: MessageAttachment,
        inspection: FileImportInspection
    ) -> MessageAttachment? {
        guard let localURL = existing.localURL,
              FileManager.default.fileExists(atPath: localURL.path) else {
            return nil
        }
        return MessageAttachment(
            kind: inspection.kind,
            localURL: localURL,
            fileName: inspection.fileName,
            mimeType: inspection.mimeType ?? existing.mimeType,
            byteCount: inspection.byteCount,
            metadata: [contentSHA256MetadataKey: inspection.contentSHA256]
        )
    }

    /// Promote an image carried by an old Kelivo backup into the native
    /// attachment store. Both identifiers are deterministic so importing the
    /// same backup again refreshes the same records instead of creating
    /// another random copy.
    static func importLegacyImage(
        data: Data,
        originalFileName: String,
        storageID: UUID,
        attachmentID: UUID,
        archivePath: String
    ) -> MessageAttachment? {
        let validationOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8
        ] as CFDictionary
        guard !data.isEmpty,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0,
              CGImageSourceCreateThumbnailAtIndex(imageSource, 0, validationOptions) != nil,
              let directory = try? directory() else {
            return nil
        }

        let originalExtension = (originalFileName as NSString).pathExtension.lowercased()
        let isSafeExtension = !originalExtension.isEmpty
            && originalExtension.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
        let fileExtension = isSafeExtension ? originalExtension : "img"
        let storageName = "legacy-kelivo-\(storageID.uuidString.lowercased()).\(fileExtension)"
        let destination = directory.appendingPathComponent(storageName)

        let existingByteCount: Int64? = {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                  let number = attributes[.size] as? NSNumber else {
                return nil
            }
            return number.int64Value
        }()
        if existingByteCount != Int64(data.count) {
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                return nil
            }
        }

        let type = UTType(filenameExtension: originalExtension)
        return MessageAttachment(
            id: attachmentID,
            kind: .image,
            localURL: destination,
            fileName: originalFileName,
            mimeType: type?.conforms(to: .image) == true ? type?.preferredMIMEType : nil,
            byteCount: Int64(data.count),
            metadata: [
                "source": "old_kelivo",
                "archivePath": archivePath
            ]
        )
    }

    static func delete(_ attachment: MessageAttachment) {
        guard let url = attachment.localURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Remove only regular files that are no longer referenced by the
    /// authoritative conversation graph. Call this only after a successful
    /// primary-store load; a missing, unreadable, or backup-recovered store is
    /// not sufficient evidence that an attachment is orphaned.
    @discardableResult
    static func reclaimUnreferencedFiles(
        referencedBy messagesByConversation: [UUID: [ChatMessage]],
        retaining unsentAttachments: [MessageAttachment] = []
    ) -> ReclaimResult {
        let attachments = messagesByConversation.values
            .flatMap { $0 }.flatMap(\.attachments) + unsentAttachments
        let referencedStorageNames = Set(
            attachments.compactMap { persistedLocalReference(for: $0.localURL) }
        )
        guard let attachmentDirectory = try? directory(),
              let storedURLs = try? FileManager.default.contentsOfDirectory(
                at: attachmentDirectory,
                includingPropertiesForKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
              ) else {
            return ReclaimResult()
        }

        var result = ReclaimResult()
        for storedURL in storedURLs {
            let storageName = storedURL.lastPathComponent
            guard !referencedStorageNames.contains(storageName),
                  let values = try? storedURL.resourceValues(forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: storedURL)
                result.removedFileCount += 1
                result.removedByteCount += Int64(values.fileSize ?? 0)
            } catch {
                continue
            }
        }
        return result
    }

    /// 文本类文件读出内容随消息发送；读不了返回 nil。
    static func readTextContent(of attachment: MessageAttachment) -> String? {
        guard attachment.kind == .file,
              let url = attachment.localURL else {
            return nil
        }
        let type = attachment.mimeType.flatMap { UTType(mimeType: $0) }
            ?? attachment.fileName.flatMap {
                UTType(filenameExtension: ($0 as NSString).pathExtension)
            }
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type,
              type.conforms(to: .text) || type.conforms(to: .json) || type.conforms(to: .xml)
                || type.conforms(to: .propertyList) || type.conforms(to: .sourceCode) else {
            return nil
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if content.count > textPreviewCharacterLimit {
            return String(content.prefix(textPreviewCharacterLimit)) + "\n…（内容过长已截断）"
        }
        return content
    }

    private static func regularFileByteCount(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
        ]),
        values.isRegularFile == true,
        let fileSize = values.fileSize else {
            return nil
        }
        return Int64(fileSize)
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: hashReadChunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > maxImageDimension else { return image }
        let scale = maxImageDimension / longest
        let target = CGSize(
            width: max(1, (pixelSize.width * scale).rounded()),
            height: max(1, (pixelSize.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        // The target is expressed in pixels. Using the device's 2x/3x screen
        // scale here would silently turn a 2048 px limit into 4096/6144 px.
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onWillDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        onWillDismiss: @escaping () -> Void = {},
        onImage: @escaping (UIImage) -> Void
    ) {
        self.onWillDismiss = onWillDismiss
        self.onImage = onImage
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onImage: onImage,
            onWillDismiss: onWillDismiss,
            dismiss: { dismiss() }
        )
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let onWillDismiss: () -> Void
        let dismiss: () -> Void

        init(
            onImage: @escaping (UIImage) -> Void,
            onWillDismiss: @escaping () -> Void,
            dismiss: @escaping () -> Void
        ) {
            self.onImage = onImage
            self.onWillDismiss = onWillDismiss
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage {
                onImage(image)
            }
            onWillDismiss()
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onWillDismiss()
            dismiss()
        }
    }
}

/// composer 上方的待发附件条。
struct PendingAttachmentsStrip: View {
    @Environment(AppModel.self) private var model
    @State private var imagePreview: MessageImagePreviewPresentation?

    var body: some View {
        if !model.pendingAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.pendingAttachments) { attachment in
                        ZStack(alignment: .topTrailing) {
                            if attachment.kind == .image {
                                Button {
                                    let images = model.pendingAttachments.filter { $0.kind == .image }
                                    guard let index = images.firstIndex(where: { $0.id == attachment.id }) else { return }
                                    imagePreview = MessageImagePreviewPresentation(
                                        images: images,
                                        initialIndex: index
                                    )
                                } label: {
                                    AttachmentThumbnail(attachment: attachment, size: 58)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.lookup("预览图片"))
                                .accessibilityValue(attachment.fileName ?? L10n.lookup("图片"))
                            } else {
                                AttachmentThumbnail(attachment: attachment, size: 58)
                            }
                            Button {
                                model.removePendingAttachment(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.white, Color.black.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                            .accessibilityLabel(L10n.lookup("移除附件"))
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.horizontal, 2)
            }
            .fullScreenCover(item: $imagePreview) { presentation in
                MessageImageViewer(
                    images: presentation.images,
                    initialIndex: presentation.initialIndex
                )
                .presentationBackground(.clear)
            }
        }
    }
}

struct AttachmentThumbnail: View {
    let attachment: MessageAttachment
    var size: CGFloat = 58

    var body: some View {
        if attachment.kind == .image {
            MessageImageThumbnail(url: attachment.localURL, size: size, cornerRadius: 12)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "doc.fill")
                    .font(.system(size: size * 0.32))
                    .foregroundStyle(Color.accentColor)
                Text(attachment.fileName ?? L10n.lookup("文件"))
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }
}

/// 消息气泡里的附件展示。
struct MessageAttachmentsView: View {
    let attachments: [MessageAttachment]
    let alignment: HorizontalAlignment
    private let collapsesImages: Bool
    private let collapsedImagesAreExcludedFromHistory: Bool
    private let scrollsMultipleImagesHorizontally: Bool
    @Binding private var imagesExpanded: Bool
    @State private var imagePreview: MessageImagePreviewPresentation?

    private let imageTileSize: CGFloat = 112
    private let searchImageTileSize: CGFloat = 144

    init(
        attachments: [MessageAttachment],
        alignment: HorizontalAlignment = .trailing,
        collapsesImages: Bool = false,
        collapsedImagesAreExcludedFromHistory: Bool = false,
        scrollsMultipleImagesHorizontally: Bool = false,
        imagesExpanded: Binding<Bool> = .constant(true)
    ) {
        self.attachments = attachments
        self.alignment = alignment
        self.collapsesImages = collapsesImages
        self.collapsedImagesAreExcludedFromHistory = collapsedImagesAreExcludedFromHistory
        self.scrollsMultipleImagesHorizontally = scrollsMultipleImagesHorizontally
        self._imagesExpanded = imagesExpanded
    }

    private var images: [MessageAttachment] {
        attachments.filter { $0.kind == .image }
    }

    private var files: [MessageAttachment] {
        attachments.filter { $0.kind != .image }
    }

    private var searchImages: [MessageAttachment] {
        images.filter { $0.metadata["source"] == "web_search_image" }
    }

    private var gridImages: [MessageAttachment] {
        images.filter { $0.metadata["source"] != "web_search_image" }
    }

    private var imageRows: [[MessageAttachment]] {
        stride(from: 0, to: gridImages.count, by: 2).map { start in
            Array(gridImages[start..<min(start + 2, gridImages.count)])
        }
    }

    private var imageIDs: [UUID] {
        gridImages.map(\.id)
    }

    private var imageCollectionTitle: String {
        let generatedSources = ["openai_responses_image_generation", "openrouter_images", "native_image_generation"]
        let containsOnlyGeneratedImages = gridImages.allSatisfy {
            guard let source = $0.metadata["source"] else { return false }
            return generatedSources.contains(source)
        }
        let title = containsOnlyGeneratedImages
            ? L10n.lookup("生成图片")
            : L10n.lookup("图片附件")
        return "\(title)（\(gridImages.count)）"
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            if !searchImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(searchImages.enumerated()), id: \.element.id) { index, attachment in
                            Button {
                                guard DrawerInlineActionTapGate.allowsAction else { return }
                                imagePreview = MessageImagePreviewPresentation(
                                    images: searchImages,
                                    initialIndex: index
                                )
                            } label: {
                                messageImageThumbnail(
                                    attachment,
                                    size: searchImageTileSize,
                                    cornerRadius: 14
                                )
                            }
                            .buttonStyle(MessageImageThumbnailButtonStyle())
                            .accessibilityLabel(L10n.format("打开第 %@ 张搜索图片，共 %@ 张", [String(describing: index + 1), String(describing: searchImages.count)]))
                        }
                    }
                    .background(DrawerHorizontalScrollProbe())
                }
                .frame(height: searchImageTileSize)
            }

            if !gridImages.isEmpty {
                if collapsesImages {
                    Button {
                        guard DrawerInlineActionTapGate.allowsAction else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            imagesExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            messageImageThumbnail(gridImages[0], size: 38, cornerRadius: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(imageCollectionTitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if collapsedImagesAreExcludedFromHistory && !imagesExpanded {
                                    Text(L10n.lookup("不随历史发送"))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(imagesExpanded ? 180 : 0))
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color.primary.opacity(0.07), lineWidth: 0.7)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(
                        .interaction,
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .zIndex(1)
                    .accessibilityLabel(imagesExpanded ? L10n.format("收起%@", [String(describing: imageCollectionTitle)]) : L10n.format("展开%@", [String(describing: imageCollectionTitle)]))
                    .accessibilityValue(
                        collapsedImagesAreExcludedFromHistory && !imagesExpanded
                            ? L10n.lookup("已折叠，不随历史发送")
                            : (imagesExpanded ? L10n.lookup("已展开") : L10n.lookup("已折叠"))
                    )
                }

                if !collapsesImages || imagesExpanded {
                    if scrollsMultipleImagesHorizontally && gridImages.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(Array(gridImages.enumerated()), id: \.element.id) { index, attachment in
                                    Button {
                                        guard DrawerInlineActionTapGate.allowsAction else { return }
                                        imagePreview = MessageImagePreviewPresentation(
                                            images: gridImages,
                                            initialIndex: index
                                        )
                                    } label: {
                                        messageImageThumbnail(
                                            attachment,
                                            size: imageTileSize,
                                            cornerRadius: 10
                                        )
                                    }
                                    .buttonStyle(MessageImageThumbnailButtonStyle())
                                    .contentShape(
                                        .interaction,
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .accessibilityLabel(L10n.format("打开第 %@ 张图片，共 %@ 张", [String(describing: index + 1), String(describing: gridImages.count)]))
                                }
                            }
                            .background(DrawerHorizontalScrollProbe())
                        }
                        .frame(
                            width: imageTileSize * 2 + 8,
                            height: imageTileSize,
                            alignment: .trailing
                        )
                        .allowsHitTesting(!collapsesImages || imagesExpanded)
                        .transition(.opacity)
                    } else {
                        ForEach(Array(imageRows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                ForEach(row) { attachment in
                                    if let index = gridImages.firstIndex(where: { $0.id == attachment.id }) {
                                        Button {
                                            guard DrawerInlineActionTapGate.allowsAction else { return }
                                            imagePreview = MessageImagePreviewPresentation(
                                                images: gridImages,
                                                initialIndex: index
                                            )
                                        } label: {
                                            messageImageThumbnail(
                                                attachment,
                                                size: imageTileSize,
                                                cornerRadius: 10
                                            )
                                        }
                                        .buttonStyle(MessageImageThumbnailButtonStyle())
                                        .contentShape(
                                            .interaction,
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        )
                                        .accessibilityLabel(L10n.format("打开第 %@ 张图片，共 %@ 张", [String(describing: index + 1), String(describing: gridImages.count)]))
                                    }
                                }
                            }
                        }
                        .allowsHitTesting(!collapsesImages || imagesExpanded)
                        .transition(.opacity)
                    }
                }
            }
            ForEach(files) { attachment in
                HStack(spacing: 7) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                    Text(attachment.fileName ?? L10n.lookup("文件"))
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
        }
        .fullScreenCover(item: $imagePreview) { presentation in
            MessageImageViewer(
                images: presentation.images,
                initialIndex: presentation.initialIndex
            )
            .presentationBackground(.clear)
        }
        .onChange(of: imageIDs) { oldIDs, newIDs in
            guard collapsesImages, oldIDs != newIDs else { return }
            imagesExpanded = false
        }
    }

    private func messageImageThumbnail(
        _ attachment: MessageAttachment,
        size: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        MessageImageThumbnail(
            url: attachment.localURL,
            size: size,
            cornerRadius: cornerRadius
        )
    }
}

private struct MessageImagePreviewPresentation: Identifiable {
    let id = UUID()
    let images: [MessageAttachment]
    let initialIndex: Int
}

private struct MessageImageThumbnailRequest: Sendable {
    let url: URL
    let maximumPixelSize: CGFloat
    let scale: CGFloat

    var key: String {
        "\(url.path)#\(Int(maximumPixelSize.rounded()))"
    }
}

private struct MessageImageThumbnail: View {
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    @State private var result: Result?

    private struct Result {
        let key: String
        let image: UIImage?
    }

    var body: some View {
        let scale = UIScreen.main.scale
        let request = url.map {
            MessageImageThumbnailRequest(
                url: $0,
                maximumPixelSize: max(size * scale, size),
                scale: scale
            )
        }
        let currentResult = result?.key == request?.key ? result : nil
        let image = request.flatMap { MessageImageThumbnailCache.cachedImage(for: $0) }
            ?? currentResult?.image

        thumbnail(image: image, failed: request == nil || (currentResult != nil && image == nil))
            .task(id: request?.key) {
                guard let request else { return }
                let image = await MessageImageThumbnailCache.image(for: request)
                guard !Task.isCancelled else { return }
                // A reused thumbnail may now represent another URL or size.
                // Keep the result associated with the request that produced it.
                result = Result(key: request.key, image: image)
            }
    }

    @ViewBuilder
    private func thumbnail(image: UIImage?, failed: Bool) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
                }
        } else {
            ZStack {
                Color.primary.opacity(0.06)
                if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

@MainActor
private enum MessageImageThumbnailCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        return cache
    }()

    // Only visible thumbnail tasks enqueue work. Serial decoding bounds peak
    // image-processing work; views sharing a key also share the pending request.
    private static let decodingQueue = DispatchQueue(
        label: "com.mocca.message-thumbnail-decoding",
        qos: .userInitiated
    )
    private static var inFlight: [String: Task<UIImage?, Never>] = [:]

    static func cachedImage(for request: MessageImageThumbnailRequest) -> UIImage? {
        cache.object(forKey: request.key as NSString)
    }

    static func image(for request: MessageImageThumbnailRequest) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cachedImage(for: request) { return cached }
        if let pending = inFlight[request.key] { return await pending.value }

        let pending = Task { @MainActor in
            let cgImage = await withCheckedContinuation { continuation in
                decodingQueue.async {
                    let image = autoreleasepool { decode(request) }
                    continuation.resume(returning: image)
                }
            }
            let image = cgImage.map {
                UIImage(cgImage: $0, scale: request.scale, orientation: .up)
            }
            if let image, let cgImage {
                cache.setObject(
                    image,
                    forKey: request.key as NSString,
                    cost: cgImage.bytesPerRow * cgImage.height
                )
            }
            inFlight[request.key] = nil
            return image
        }
        inFlight[request.key] = pending
        // A disappearing view cancels its own result publication, not another
        // view's shared decode. The completed thumbnail remains reusable.
        return await pending.value
    }

    nonisolated private static func decode(_ request: MessageImageThumbnailRequest) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: request.maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
              ) else {
            return nil
        }

        return cgImage
    }
}

private struct MessageImageThumbnailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MessageImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let images: [MessageAttachment]
    @State private var selectedIndex: Int
    @State private var showsControls = true
    @State private var notice: String?
    @State private var noticeGeneration = 0
    @State private var shareItem: MessageImageShareItem?
    @State private var saveAlert: MessageImageSaveAlert?
    @State private var interactiveDismissOffset: CGFloat = 0
    @State private var isCompletingInteractiveDismissal = false

    init(images: [MessageAttachment], initialIndex: Int) {
        self.images = images
        _selectedIndex = State(
            initialValue: min(max(initialIndex, 0), max(images.count - 1, 0))
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - Double(interactiveDismissProgress) * 0.88)
                .ignoresSafeArea()

            TabView(selection: $selectedIndex) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, attachment in
                    imagePage(attachment)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: interactiveDismissOffset)
            .scaleEffect(1 - interactiveDismissProgress * 0.055)
            .allowsHitTesting(!isCompletingInteractiveDismissal)

            if showsControls {
                VStack(spacing: 0) {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.black.opacity(0.52), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.lookup("关闭图片"))

                        Spacer()

                        if images.count > 1 {
                            Text("\(selectedIndex + 1) / \(images.count)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(Color.black.opacity(0.52), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer()
                }
                .opacity(max(0, 1 - Double(interactiveDismissProgress) * 1.45))
                .transition(.opacity)
            }

            if let notice {
                VStack {
                    Spacer()
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .frame(height: 40)
                        .background(Color.black.opacity(0.68), in: Capsule())
                        .padding(.bottom, 42)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showsControls)
        .animation(.easeOut(duration: 0.18), value: notice)
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(items: [item.url])
                .ignoresSafeArea()
        }
        .alert(item: $saveAlert) { alert in
            if alert.offersSettings {
                Alert(
                    title: Text(L10n.lookup("无法存储图片")),
                    message: Text(alert.message),
                    primaryButton: .default(Text(L10n.lookup("打开设置"))) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    },
                    secondaryButton: .cancel(Text(L10n.lookup("取消")))
                )
            } else {
                Alert(
                    title: Text(L10n.lookup("无法存储图片")),
                    message: Text(alert.message),
                    dismissButton: .default(Text(L10n.lookup("好")))
                )
            }
        }
        .statusBarHidden(true)
    }

    private var interactiveDismissProgress: CGFloat {
        min(max(interactiveDismissOffset / 260, 0), 1)
    }

    @ViewBuilder
    private func imagePage(_ attachment: MessageAttachment) -> some View {
        MessageImagePage(url: attachment.localURL) { image, url in
            ZoomableMessageImageView(
                image: image,
                accessibilityLabel: attachment.fileName ?? L10n.lookup("图片"),
                onSingleTap: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        showsControls.toggle()
                    }
                },
                onSave: {
                    saveImage(at: url)
                },
                onCopy: {
                    UIPasteboard.general.image = image
                    showNotice(L10n.lookup("已复制图片"))
                },
                onShare: {
                    shareItem = MessageImageShareItem(url: url)
                },
                onDismissChanged: { translation in
                    guard !isCompletingInteractiveDismissal else { return }
                    interactiveDismissOffset = max(translation, 0)
                },
                onDismissEnded: { translation, velocity in
                    finishInteractiveDismissal(translation: translation, velocity: velocity)
                }
            )
            .ignoresSafeArea()
        }
    }

    private func finishInteractiveDismissal(translation: CGFloat, velocity: CGFloat) {
        guard !isCompletingInteractiveDismissal else { return }
        let shouldDismiss = translation >= 110 || (translation >= 32 && velocity >= 700)
        guard shouldDismiss else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                interactiveDismissOffset = 0
            }
            return
        }

        isCompletingInteractiveDismissal = true
        // The cover already owns the final dismissal animation. Moving the image
        // fully off-screen first left the cover's dim background behind for a
        // second, full-screen slide. Hand off immediately so a swipe and the X
        // button share one clean exit transition.
        dismiss()
    }

    private func saveImage(at url: URL) {
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveAlert = MessageImageSaveAlert(
                    message: L10n.lookup("请在系统设置中允许 Mocca 将图片添加到照片。"),
                    offersSettings: true
                )
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges { @Sendable in
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
                showNotice(L10n.lookup("已存储到照片"))
            } catch {
                saveAlert = MessageImageSaveAlert(
                    message: L10n.lookup("图片没有成功写入照片，请稍后再试。"),
                    offersSettings: false
                )
            }
        }
    }

    private func showNotice(_ text: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        withAnimation(.easeOut(duration: 0.18)) {
            notice = text
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard generation == noticeGeneration else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                notice = nil
            }
        }
    }
}

/// The loaded image belongs to this page and URL, not to a control animation.
/// Retaining its identity also preserves UIKit's zoom when controls or notices change.
private struct MessageImagePage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (UIImage, URL) -> Content
    @State private var result: LoadResult?

    private struct LoadResult {
        let url: URL
        let image: UIImage?
    }

    var body: some View {
        Group {
            if let url, let result, result.url == url {
                if let image = result.image {
                    content(image, url)
                } else {
                    unavailableImage
                }
            } else if url != nil {
                ProgressView(L10n.lookup("正在读取图片…"))
                    .tint(.white)
                    .foregroundStyle(.white)
            } else {
                unavailableImage
            }
        }
        .task(id: url) {
            guard let url else { return }
            let image = await MessageImageLoader.image(at: url)
            guard !Task.isCancelled else { return }
            result = LoadResult(url: url, image: image)
        }
    }

    private var unavailableImage: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 38, weight: .medium))
            Text(L10n.lookup("图片无法读取"))
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.72))
    }
}

private enum MessageImageLoader {
    private static let queue = DispatchQueue(
        label: "com.mocca.image-viewer-decoding",
        qos: .userInitiated
    )

    static func image(at url: URL) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let image = autoreleasepool {
                    guard let original = UIImage(contentsOfFile: url.path) else { return nil as UIImage? }
                    return original.preparingForDisplay() ?? original
                }
                continuation.resume(returning: image)
            }
        }
    }
}

private struct MessageImageShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MessageImageSaveAlert: Identifiable {
    let id = UUID()
    let message: String
    let offersSettings: Bool
}

@MainActor
private final class MessageImageScrollView: UIScrollView {
    let hostedImageView: UIImageView

    init(imageView: UIImageView) {
        hostedImageView = imageView
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutImageAtMinimumScaleIfNeeded()
        centerImage()
    }

    func imageDidChange() {
        if zoomScale != minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: false)
        }
        setNeedsLayout()
    }

    func centerImage() {
        let horizontalInset = max((bounds.width - contentSize.width) / 2, 0)
        let verticalInset = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    private func layoutImageAtMinimumScaleIfNeeded() {
        guard bounds.width > 0,
              bounds.height > 0,
              zoomScale <= minimumZoomScale + 0.001,
              !isZooming,
              !isZoomBouncing,
              let imageSize = hostedImageView.image?.size,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return
        }

        let fitScale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let fittedSize = CGSize(
            width: max(imageSize.width * fitScale, 1),
            height: max(imageSize.height * fitScale, 1)
        )
        guard abs(hostedImageView.bounds.width - fittedSize.width) > 0.5
                || abs(hostedImageView.bounds.height - fittedSize.height) > 0.5 else {
            return
        }

        hostedImageView.transform = .identity
        hostedImageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
    }
}

private struct ZoomableMessageImageView: UIViewRepresentable {
    let image: UIImage
    let accessibilityLabel: String
    let onSingleTap: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void
    let onShare: () -> Void
    let onDismissChanged: (CGFloat) -> Void
    let onDismissEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            image: image,
            onSingleTap: onSingleTap,
            onSave: onSave,
            onCopy: onCopy,
            onShare: onShare,
            onDismissChanged: onDismissChanged,
            onDismissEnded: onDismissEnded
        )
    }

    func makeUIView(context: Context) -> UIScrollView {
        let imageView = context.coordinator.imageView
        let scrollView = MessageImageScrollView(imageView: imageView)
        scrollView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.isEnabled = false

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = accessibilityLabel
        imageView.accessibilityHint = L10n.lookup("捏合或双击缩放，长按显示图片操作")
        scrollView.addSubview(imageView)

        let dismissPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDismissPan(_:))
        )
        dismissPan.delegate = context.coordinator
        dismissPan.maximumNumberOfTouches = 1
        scrollView.addGestureRecognizer(dismissPan)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        imageView.addGestureRecognizer(singleTap)
        imageView.addGestureRecognizer(doubleTap)
        imageView.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))

        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.update(
            image: image,
            onSingleTap: onSingleTap,
            onSave: onSave,
            onCopy: onCopy,
            onShare: onShare,
            onDismissChanged: onDismissChanged,
            onDismissEnded: onDismissEnded
        )
        context.coordinator.imageView.accessibilityLabel = accessibilityLabel
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?
        private var image: UIImage
        private var onSingleTap: () -> Void
        private var onSave: () -> Void
        private var onCopy: () -> Void
        private var onShare: () -> Void
        private var onDismissChanged: (CGFloat) -> Void
        private var onDismissEnded: (CGFloat, CGFloat) -> Void

        init(
            image: UIImage,
            onSingleTap: @escaping () -> Void,
            onSave: @escaping () -> Void,
            onCopy: @escaping () -> Void,
            onShare: @escaping () -> Void,
            onDismissChanged: @escaping (CGFloat) -> Void,
            onDismissEnded: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.image = image
            self.onSingleTap = onSingleTap
            self.onSave = onSave
            self.onCopy = onCopy
            self.onShare = onShare
            self.onDismissChanged = onDismissChanged
            self.onDismissEnded = onDismissEnded
        }

        func update(
            image: UIImage,
            onSingleTap: @escaping () -> Void,
            onSave: @escaping () -> Void,
            onCopy: @escaping () -> Void,
            onShare: @escaping () -> Void,
            onDismissChanged: @escaping (CGFloat) -> Void,
            onDismissEnded: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.image = image
            self.onSingleTap = onSingleTap
            self.onSave = onSave
            self.onCopy = onCopy
            self.onShare = onShare
            self.onDismissChanged = onDismissChanged
            self.onDismissEnded = onDismissEnded
            if imageView.image !== image {
                imageView.image = image
                (scrollView as? MessageImageScrollView)?.imageDidChange()
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            updatePanAvailability(in: scrollView)
            centerZoomedImage(in: scrollView)
        }

        func scrollViewDidEndZooming(
            _ scrollView: UIScrollView,
            with view: UIView?,
            atScale scale: CGFloat
        ) {
            updatePanAvailability(in: scrollView)
            centerZoomedImage(in: scrollView)
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onSingleTap()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.02 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let targetScale = min(3, scrollView.maximumZoomScale)
            let point = recognizer.location(in: imageView)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            let rect = CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height
            )
            scrollView.zoom(to: rect, animated: true)
        }

        @objc func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            let translation = max(recognizer.translation(in: scrollView).y, 0)
            switch recognizer.state {
            case .began, .changed:
                onDismissChanged(translation)
            case .ended:
                onDismissEnded(translation, recognizer.velocity(in: scrollView).y)
            case .cancelled, .failed:
                onDismissEnded(0, 0)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let scrollView,
                  scrollView.zoomScale <= scrollView.minimumZoomScale + 0.02 else {
                return false
            }
            let velocity = pan.velocity(in: scrollView)
            return velocity.y > 0 && abs(velocity.y) > abs(velocity.x) * 1.15
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let save = UIAction(
                    title: L10n.lookup("存储到照片"),
                    image: UIImage(systemName: "square.and.arrow.down")
                ) { [weak self] _ in
                    self?.onSave()
                }
                let copy = UIAction(
                    title: L10n.lookup("复制图片"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { [weak self] _ in
                    self?.onCopy()
                }
                let share = UIAction(
                    title: L10n.lookup("分享"),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in
                    self?.onShare()
                }
                return UIMenu(children: [save, copy, share])
            }
        }

        private func updatePanAvailability(in scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.02
        }

        private func centerZoomedImage(in scrollView: UIScrollView) {
            (scrollView as? MessageImageScrollView)?.centerImage()
        }
    }
}
