import SwiftUI

@main
struct MoccaApp: App {
    @UIApplicationDelegateAdaptor(MoccaAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    private var shouldRunStartupServices: Bool {
        #if DEBUG
        if AppModel.nativeReadingFixtureRequested { return false }
        #endif
        return true
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .background {
                    AppWindowBridge(
                        replyBanners: model.replyBanners,
                        usesDefaultTheme: model.preferences.themePaletteID == .defaultPalette
                    )
                    .frame(width: 0, height: 0)
                }
                .environment(model)
                .environment(\.locale, AppLocalization.shared.locale)
                // Theme color is applied explicitly to selection surfaces and
                // controls. Keeping it out of the root environment prevents
                // SwiftUI from tinting whole button labels and reducing text
                // contrast in settings pages.
                .toggleStyle(SwitchToggleStyle(tint: Color(uiColor: model.themeSwitchUIColor)))
                .appFontEnvironment(model.preferences.appFontPostScriptName)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { model.replyBanners.clear() }
                    if phase == .background {
                        model.pauseAllUserBatches()
                        model.flushStreamingProgress()
                    }
                    guard phase == .active else { return }
                    AppLocalization.shared.refreshSystemLanguage()
                    model.retryConversationStoreLoadIfNeeded()
                    model.flushStreamingProgress()
                    if shouldRunStartupServices { model.handleAppBecameActive() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    AppLocalization.shared.refreshSystemLanguage()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.protectedDataWillBecomeUnavailableNotification
                    )
                ) { _ in
                    model.flushStreamingProgress()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.protectedDataDidBecomeAvailableNotification
                    )
                ) { _ in
                    model.retryConversationStoreLoadIfNeeded()
                    model.flushStreamingProgress()
                    if shouldRunStartupServices { model.handleAppBecameActive() }
                }
                .task {
                    // `scenePhase` can already be active when the first view is
                    // installed, in which case onChange does not fire.
                    await Task.yield()
                    // Reclaim only our abandoned temporary ZIP files. If a full
                    // disk blocked the initial chat load, retry after space is freed.
                    if await ZIPAttachmentReader.shared.discardAbandonedFiles() {
                        model.retryConversationStoreLoadIfNeeded()
                    }
                    if shouldRunStartupServices { model.handleAppBecameActive() }
                }
                .task {
                    guard shouldRunStartupServices else { return }
                    await SponsorStore.shared.listenForTransactions()
                }
                #if DEBUG
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    guard arguments.contains("-previewTools")
                            || arguments.contains("-previewInstruction")
                            || arguments.contains("-previewKeyboardShortChat")
                            || arguments.contains("-previewNavigationStress")
                            || AppModel.nativeReadingFixtureRequested
                            || arguments.contains("-previewCalendar")
                            || arguments.contains("-diagnoseNavigationStress") else { return }
                    try? await Task.sleep(for: .milliseconds(450))
                    if AppModel.nativeReadingFixtureRequested {
                        model.prepareNativeReadingFixture()
                        return
                    }
                    if arguments.contains("-previewCalendar") {
                        model.prepareCalendarPreview()
                        return
                    }
                    if arguments.contains("-diagnoseNavigationStress") {
                        // Keep cold-loaded transcript data untouched. This flag
                        // only exposes the controls and logging used by simulator
                        // acceptance after the fixture has been persisted once.
                        model.updatePreferences {
                            $0.mobileMessageNavButtonsMode = .always
                            $0.showChatListDate = true
                        }
                        return
                    }
                    if arguments.contains("-previewNavigationStress") {
                        model.prepareNavigationStressPreview()
                        return
                    }
                    if arguments.contains("-previewKeyboardShortChat") {
                        model.prepareKeyboardShortChatPreview()
                        return
                    }
                    model.presentBottomTools()
                    if arguments.contains("-previewInstruction") {
                        try? await Task.sleep(for: .milliseconds(450))
                        model.bottomTools.open(.instruction)
                    }
                }
                #endif
        }
    }
}

/// Uses the chat's own window for transient reply banners and native field tint.
private struct AppWindowBridge: UIViewRepresentable {
    let replyBanners: ReplyBannerPresenter
    let usesDefaultTheme: Bool

    func makeUIView(context: Context) -> WindowTintView {
        let view = WindowTintView()
        view.replyBanners = replyBanners
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: WindowTintView, context: Context) {
        view.configure(usesDefaultTheme: usesDefaultTheme)
    }

    static func dismantleUIView(_ view: WindowTintView, coordinator: ()) {
        view.restoreTint()
    }

    final class WindowTintView: UIView {
        weak var replyBanners: ReplyBannerPresenter?
        private var usesDefaultTheme = false
        private weak var tintedWindow: UIWindow?

        func configure(usesDefaultTheme: Bool) {
            guard self.usesDefaultTheme != usesDefaultTheme else { return }
            self.usesDefaultTheme = usesDefaultTheme
            applyTint()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { replyBanners?.window = window }
            applyTint()
        }

        private func applyTint() {
            guard usesDefaultTheme, let window else {
                restoreTint()
                return
            }
            guard tintedWindow !== window else { return }
            restoreTint()
            tintedWindow = window
            window.tintColor = .systemBlue
        }

        func restoreTint() {
            // nil restores UIKit's inherited tint. Saving the getter's resolved
            // color would turn an inherited color into a permanent override.
            tintedWindow?.tintColor = nil
            tintedWindow = nil
        }
    }
}
