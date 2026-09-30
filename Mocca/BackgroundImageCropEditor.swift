import ImageIO
import SwiftUI
import UIKit

struct BackgroundCropRequest: Identifiable {
    let id = UUID()
    let image: UIImage
}

enum BackgroundCropDestination: Sendable {
    case sidebar
    case assistant(UUID)

    func aspectRatio(windowSize: CGSize) -> CGFloat {
        let width = max(windowSize.width, 1)
        let height = max(windowSize.height, 1)
        switch self {
        case .sidebar:
            // Match the fixed sidebar surface, including the panel corner.
            return (min(width * 0.78, 390) + 44) / height
        case .assistant:
            return width / height
        }
    }
}

/// Image work exists only during import/confirmation, outside the chat renderer.
enum BackgroundCropImageIO {
    nonisolated static func prepare(_ data: Data) async -> UIImage? {
        let worker = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary), !Task.isCancelled else { return nil }
            return UIImage(cgImage: image)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func crop(_ image: UIImage, rect: CGRect) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = image.cgImage else { return nil }
            let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let pixels = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                                width: rect.width * image.scale, height: rect.height * image.scale)
                .integral.intersection(bounds)
            guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1,
                  let cropped = source.cropping(to: pixels) else { return nil }
            let ratio = min(1, 2048 / max(pixels.width, pixels.height))
            let size = CGSize(width: max(1, (pixels.width * ratio).rounded()),
                              height: max(1, (pixels.height * ratio).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            // Materialize a bounded bitmap so the saved crop does not retain
            // the larger import buffer through a CGImage subimage.
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
            }
        }.value
    }

    nonisolated static func save(_ image: UIImage, destination: BackgroundCropDestination) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            switch destination {
            case .sidebar: return AssistantMediaStore.saveSidebarBackground(image)
            case .assistant(let id): return AssistantMediaStore.saveBackground(image, assistantID: id)
            }
        }.value
    }
}

@MainActor final class BackgroundCropControls {
    weak var canvas: BackgroundCropCanvas?
}

@MainActor struct BackgroundImageCropEditor: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let destination: BackgroundCropDestination
    let onSave: @MainActor (UIImage) async -> Bool
    @State private var controls = BackgroundCropControls()
    @State private var isSaving = false
    @State private var isActive = true
    @State private var showSaveError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(L10n.lookup("拖动图片调整位置，双指缩放"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                BackgroundCropCanvasHost(image: image, destination: destination, controls: controls)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .disabled(isSaving)
                Button(L10n.lookup("重置取景")) { controls.canvas?.resetCrop() }
                    .disabled(isSaving)
                    .padding(.bottom, 20)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(L10n.lookup("背景取景"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().accessibilityLabel(L10n.lookup("正在保存"))
                    } else {
                        Button(L10n.lookup("完成"), action: finish)
                    }
                }
            }
            .alert(L10n.lookup("背景保存失败"), isPresented: $showSaveError) {
                Button(L10n.lookup("好"), role: .cancel) {}
            } message: {
                Text(L10n.lookup("原背景保持不变，请重试。"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isSaving)
        .onDisappear { isActive = false }
    }

    private func finish() {
        guard !isSaving, let rect = controls.canvas?.captureSelection() else { return }
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            guard let cropped = await BackgroundCropImageIO.crop(image, rect: rect), isActive else {
                if isActive { showSaveError = true }
                return
            }
            let saved = await onSave(cropped)
            guard isActive else { return }
            if saved { dismiss() } else { showSaveError = true }
        }
    }
}

private struct BackgroundCropCanvasHost: UIViewRepresentable {
    let image: UIImage
    let destination: BackgroundCropDestination
    let controls: BackgroundCropControls

    func makeUIView(context: Context) -> BackgroundCropCanvas {
        let view = BackgroundCropCanvas(image: image, destination: destination)
        controls.canvas = view
        return view
    }
    func updateUIView(_ uiView: BackgroundCropCanvas, context: Context) {
        uiView.isUserInteractionEnabled = context.environment.isEnabled
    }
}

/// Native zoom/pan is confined to the temporary editor. No geometry observer
/// or gesture handler is added to a saved background.
@MainActor final class BackgroundCropCanvas: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    private let imageView: UIImageView
    private let imageSize: CGSize
    private let destination: BackgroundCropDestination
    private var configuredViewport = CGSize.zero
    private var minimumScale: CGFloat = 1

    init(image: UIImage, destination: BackgroundCropDestination) {
        self.imageSize = image.size
        self.imageView = UIImageView(image: image)
        self.destination = destination
        super.init(frame: .zero)
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.clipsToBounds = true
        scrollView.layer.borderWidth = 1
        scrollView.layer.borderColor = UIColor.secondaryLabel.cgColor
        scrollView.accessibilityLabel = L10n.lookup("背景取景区域")
        imageView.frame = CGRect(origin: .zero, size: imageSize)
        scrollView.addSubview(imageView)
        addSubview(scrollView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, imageSize.width > 0, imageSize.height > 0 else { return }
        let windowSize = window?.bounds.size ?? bounds.size
        let aspect = destination.aspectRatio(windowSize: windowSize)
        let width = min(bounds.width, bounds.height * aspect)
        let viewport = CGSize(width: width, height: width / aspect)
        let oldViewport = configuredViewport
        let oldZoom = max(scrollView.zoomScale, 0.0001)
        let oldOffset = scrollView.contentOffset
        scrollView.frame = CGRect(x: (bounds.width - viewport.width) / 2,
                                  y: (bounds.height - viewport.height) / 2,
                                  width: viewport.width, height: viewport.height)
        guard viewport != configuredViewport else { return }
        let center = oldViewport == .zero ? CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
            : CGPoint(x: (oldOffset.x + oldViewport.width / 2) / oldZoom,
                      y: (oldOffset.y + oldViewport.height / 2) / oldZoom)
        let relativeZoom = oldViewport == .zero ? 1 : oldZoom / minimumScale
        configuredViewport = viewport
        minimumScale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
        // Temporarily permit either old or new range before restoring the new
        // limits; shrinking a viewport must not retain the previous minimum.
        scrollView.minimumZoomScale = min(scrollView.minimumZoomScale, minimumScale)
        scrollView.maximumZoomScale = max(scrollView.maximumZoomScale, minimumScale * 6)
        scrollView.setZoomScale(minimumScale * min(max(relativeZoom, 1), 6), animated: false)
        scrollView.minimumZoomScale = minimumScale
        scrollView.maximumZoomScale = minimumScale * 6
        setCenter(center)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func resetCrop() {
        guard configuredViewport != .zero else { return }
        scrollView.setZoomScale(minimumScale, animated: false)
        setCenter(CGPoint(x: imageSize.width / 2, y: imageSize.height / 2))
    }

    private func setCenter(_ center: CGPoint) {
        let zoom = scrollView.zoomScale
        scrollView.contentSize = CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)
        scrollView.contentOffset = CGPoint(
            x: min(max(center.x * zoom - configuredViewport.width / 2, 0), max(0, scrollView.contentSize.width - configuredViewport.width)),
            y: min(max(center.y * zoom - configuredViewport.height / 2, 0), max(0, scrollView.contentSize.height - configuredViewport.height))
        )
    }

    func captureSelection() -> CGRect? {
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        return selectedImageRect
    }

    var selectedImageRect: CGRect? {
        guard configuredViewport != .zero, scrollView.zoomScale > 0 else { return nil }
        let zoom = scrollView.zoomScale
        return CGRect(x: max(0, scrollView.contentOffset.x / zoom),
                      y: max(0, scrollView.contentOffset.y / zoom),
                      width: configuredViewport.width / zoom, height: configuredViewport.height / zoom)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }
}
