import SwiftUI

@main
struct MoccaApp: App {
    @UIApplicationDelegateAdaptor(MoccaAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.locale, AppLocalization.shared.locale)
                // Theme color is applied explicitly to selection surfaces and
                // controls. Keeping it out of the root environment prevents
                // SwiftUI from tinting whole button labels and reducing text
                // contrast in settings pages.
                .toggleStyle(SwitchToggleStyle(tint: Color(uiColor: model.themeSwitchUIColor)))
                .appFontEnvironment(model.preferences.appFontPostScriptName)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    AppLocalization.shared.refreshSystemLanguage()
                    model.retryConversationStoreLoadIfNeeded()
                    model.handleAppBecameActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    AppLocalization.shared.refreshSystemLanguage()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.protectedDataDidBecomeAvailableNotification
                    )
                ) { _ in
                    model.retryConversationStoreLoadIfNeeded()
                    model.handleAppBecameActive()
                }
                .task {
                    // `scenePhase` can already be active when the first view is
                    // installed, in which case onChange does not fire.
                    await Task.yield()
                    model.handleAppBecameActive()
                }
                .task {
                    await SponsorStore.shared.listenForTransactions()
                }
                #if DEBUG
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    guard arguments.contains("-previewTools")
                            || arguments.contains("-previewInstruction")
                            || arguments.contains("-previewKeyboardShortChat")
                            || arguments.contains("-previewNavigationStress")
                            || arguments.contains("-previewCalendar")
                            || arguments.contains("-diagnoseNavigationStress") else { return }
                    try? await Task.sleep(for: .milliseconds(450))
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
