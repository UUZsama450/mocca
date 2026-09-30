// Appended only to the copied RootView.swift in the disposable XCTest host.
@MainActor enum DrawerListProbe {
    static var counts: [String: Int] = [:]
    static var groups: [String: [(Date, [UUID])]] = [:]
    static var rows: [String: [UUID: Bool]] = [:]
    static func count(_ key: String) { counts[key, default: 0] += 1 }
    static func reset() { counts = [:]; rows = [:] }
}

struct DrawerListTestOptions {
    var query = ""
    var group = false
    var contentSearch = false
    var dateNow: Date?
    var calendar = Calendar.current
}

@MainActor enum DrawerListTestBridge {
    static func view(model: AppModel, baseline: Bool, options: DrawerListTestOptions = .init()) -> AnyView {
        if baseline {
            return AnyView(BaselineConversationDrawerContent.listTestView(options).equatable().environment(model))
        }
        return AnyView(ConversationDrawerContent.listTestView(options).equatable().environment(model))
    }

    static func sameDateContext(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Bool {
        DrawerDateContext(now: lhs, calendar: calendar) == DrawerDateContext(now: rhs, calendar: calendar)
    }

    static func differentCalendars(_ lhs: Calendar, _ rhs: Calendar, now: Date) -> Bool {
        DrawerDateContext(now: now, calendar: lhs) != DrawerDateContext(now: now, calendar: rhs)
    }
}
