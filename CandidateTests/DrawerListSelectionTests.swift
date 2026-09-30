import XCTest
import SwiftUI
@testable import Mocca

/// Actual product drawer, mounted by SwiftUI in an iOS simulator test app.
/// Synthetic chats only; measured counts are not real-device frame timings.
@MainActor final class DrawerListSelectionTests: XCTestCase {
    private struct Mount {
        let window: UIWindow
        let host: UIHostingController<AnyView>
    }
    private func fixture(_ count: Int, mixed: Bool = false) -> AppModel {
        let model = AppModel()
        let second = AssistantProfile(name: "Synthetic B")
        model.assistants.append(second)
        let owner = model.currentAssistantID.uuidString
        let date = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3600)
        model.conversations = (0..<count).map { index in
            let group = mixed && index % 3 == 2
            return Conversation(title: "Synthetic \(index) \(index % 2 == 0 ? "MATCH" : "plain")",
                createdAt: date.addingTimeInterval(-Double(index)),
                updatedAt: date.addingTimeInterval(-Double(index / 4) * 86400),
                assistantID: mixed && index % 3 == 1 ? second.id.uuidString : owner,
                groupAssistantIDs: group ? [owner, second.id.uuidString] : [])
        }
        model.selectedConversationID = model.conversations.first!.id
        model.preferences.showChatListDate = true
        model.preferences.keepSidebarOpenOnTopicTap = true
        model.isDrawerPresented = true
        return model
    }
    private func mount(_ model: AppModel, baseline: Bool, options: DrawerListTestOptions = .init()) async throws -> Mount {
        DrawerListProbe.reset(); DrawerListProbe.groups = [:]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: DrawerListTestBridge.view(model: model, baseline: baseline, options: options)
            .environment(\.colorScheme, .light).erased())
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        let mounted = Mount(window: window, host: host)
        await settle(mounted)
        addTeardownBlock { @MainActor in window.isHidden = true; window.rootViewController = nil }
        return mounted
    }
    private func settle(_ mounted: Mount) async {
        for _ in 0..<4 {
            mounted.host.view.setNeedsLayout(); mounted.host.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
    private func close(_ mounted: Mount) {
        mounted.window.isHidden = true; mounted.window.rootViewController = nil
    }
    private func pixels(_ mounted: Mount) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: mounted.host.view.bounds.size, format: format).image { _ in
            mounted.host.view.drawHierarchy(in: mounted.host.view.bounds, afterScreenUpdates: true)
        }.pngData()!
    }
    private func groupIDs(_ key: String) -> [UUID] { (DrawerListProbe.groups[key] ?? []).flatMap { $0.1 } }

    private func assertContentPixelsEqual(_ actual: Data, _ expected: Data, group: Bool) throws {
        if actual == expected { return }
        func decoded(_ data: Data) throws -> (CGSize, [UInt8]) {
            let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width,
                    height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return (CGSize(width: image.width, height: image.height), bytes)
        }
        let a = try decoded(actual), b = try decoded(expected)
        XCTAssertEqual(a.0, b.0)
        guard a.1.count == b.1.count else { XCTFail("Image sizes changed"); return }
        var changedPixels = 0, largestChannelDelta = 0
        for pixel in stride(from: 0, to: a.1.count, by: 4) {
            var changed = false
            for channel in 0..<4 {
                let delta = abs(Int(a.1[pixel + channel]) - Int(b.1[pixel + channel]))
                largestChannelDelta = max(largestChannelDelta, delta)
                changed = changed || delta != 0
            }
            if changed { changedPixels += 1 }
        }
        // Independent UIKit snapshots can round the floating chrome's very
        // faint shadow by one 8-bit level. Never tolerate a text/layout change.
        XCTAssertLessThanOrEqual(largestChannelDelta, 1)
        XCTAssertLessThanOrEqual(Double(changedPixels) / Double(a.1.count / 4), 0.001)
        print("DRAWER_CONTENT_PIXEL_ROUNDING group=\(group) pixels=\(changedPixels) maxChannelDelta=\(largestChannelDelta)")
    }

    func testSelectionSkipsWholeListWorkAt1001000And10000Conversations() async throws {
        for size in [100, 1000, 10000] {
            let model = fixture(size)
            for baseline in [true, false] {
                let key = baseline ? "baseline" : "candidate"
                model.selectedConversationID = model.conversations[0].id
                let mounted = try await mount(model, baseline: baseline)
                XCTAssertEqual(groupIDs(key).count, size)
                let initialRowCalls = DrawerListProbe.counts[key + ".rows", default: 0]
                XCTAssertLessThan(initialRowCalls, size, "The list must remain lazy")
                DrawerListProbe.reset()
                for index in 0..<20 {
                    let id = model.conversations[(index + 1) % 2].id
                    model.selectConversation(id, closeDrawer: false)
                    await settle(mounted)
                    XCTAssertEqual(DrawerListProbe.rows[key]?[id], true)
                    XCTAssertEqual(DrawerListProbe.rows[key]?[model.conversations[index % 2].id], false)
                }
                let counts = DrawerListProbe.counts
                if baseline {
                    XCTAssertEqual(counts[key + ".group", default: 0], 20)
                    XCTAssertEqual(counts[key + ".filter", default: 0], 20)
                } else {
                    XCTAssertEqual(counts[key + ".group", default: 0], 0)
                    XCTAssertEqual(counts[key + ".filter", default: 0], 0)
                    XCTAssertEqual(counts[key + ".source", default: 0], 0)
                    XCTAssertEqual(counts[key + ".body", default: 0], 0)
                }
                print("DRAWER_LIST_COUNTS \(size) \(key) \(counts)")
                close(mounted)
            }
        }
    }

    func testOrdinaryRowsKeepHighlightAndUnreadRenderingWithAndWithoutDates() async throws {
        let model = fixture(12)
        for dates in [false, true] {
            model.preferences.showChatListDate = dates
            model.drawerTestUnread(Set(model.conversations.prefix(3).map(\.id)))
            var previousSelectionPixels: Data?
            for selected in [0, 1] {
                model.selectedConversationID = model.conversations[selected].id
                let old = try await mount(model, baseline: true)
                let oldPixels = pixels(old)
                if let previousSelectionPixels { XCTAssertNotEqual(oldPixels, previousSelectionPixels) }
                previousSelectionPixels = oldPixels
                close(old)
                let new = try await mount(model, baseline: false)
                XCTAssertEqual(pixels(new), oldPixels, "dates=\(dates), selected=\(selected)")
                if dates && selected == 1 {
                    let attachment = XCTAttachment(image: UIImage(data: pixels(new))!)
                    attachment.name = "Candidate drawer selected second conversation"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                close(new)
            }
        }
    }

    func testRenameDeleteReorderAndUpdatedDateRefreshMountedList() async throws {
        let model = fixture(20)
        let mounted = try await mount(model, baseline: false)
        DrawerListProbe.reset()
        model.conversations[0].title = "Changed title"
        await settle(mounted)
        XCTAssertGreaterThan(DrawerListProbe.counts["candidate.group", default: 0], 0)
        let id = model.conversations[19].id
        model.conversations[19].updatedAt = .now.addingTimeInterval(86400)
        await settle(mounted)
        XCTAssertEqual(groupIDs("candidate").first, id)
        model.conversations.reverse()
        await settle(mounted)
        XCTAssertEqual(groupIDs("candidate").first, id)
        model.conversations.removeAll { $0.id == id }
        await settle(mounted)
        XCTAssertFalse(groupIDs("candidate").contains(id))
        XCTAssertEqual(groupIDs("candidate").count, 19)
        close(mounted)
    }

    func testTitleSearchAssistantAndGroupScopesMatchBaseline() async throws {
        let model = fixture(60, mixed: true)
        for group in [false, true] {
            for query in ["", "  match  ", "no result"] {
                let options = DrawerListTestOptions(query: query, group: group)
                let old = try await mount(model, baseline: true, options: options)
                let expected = groupIDs("baseline")
                let oldPixels = pixels(old)
                close(old)
                let new = try await mount(model, baseline: false, options: options)
                XCTAssertEqual(groupIDs("candidate"), expected)
                XCTAssertEqual(pixels(new), oldPixels, "group=\(group), query=\(query)")
                close(new)
            }
        }
        let mounted = try await mount(model, baseline: false)
        model.currentAssistantID = model.assistants.last!.id
        await settle(mounted)
        XCTAssertEqual(Set(groupIDs("candidate")), Set(model.visibleConversations.map(\.id)))
        close(mounted)
    }

    func testContentSearchSelectionUpdatesWithoutRebuildingDrawer() async throws {
        let model = fixture(12, mixed: true)
        model.messagesByConversation = Dictionary(uniqueKeysWithValues: model.conversations.map {
            ($0.id, [ChatMessage(conversationID: $0.id, role: .assistant, text: "Synthetic search NEEDLE result")])
        })
        for group in [false, true] {
            let options = DrawerListTestOptions(query: "needle", group: group, contentSearch: true)
            let old = try await mount(model, baseline: true, options: options)
            try await Task.sleep(for: .milliseconds(300)); await settle(old)
            let oldPixels = pixels(old)
            close(old)
            let new = try await mount(model, baseline: false, options: options)
            try await Task.sleep(for: .milliseconds(300)); await settle(new)
            let newPixels = pixels(new)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DrawerListPixels")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try oldPixels.write(to: directory.appendingPathComponent("content-baseline-\(group).png"))
            try newPixels.write(to: directory.appendingPathComponent("content-candidate-\(group).png"))
            try assertContentPixelsEqual(newPixels, oldPixels, group: group)
            let target = model.conversations.first { ($0.groupAssistantIDs.count >= 2) == group && $0.id != model.selectedConversationID }!
            DrawerListProbe.reset()
            model.selectedConversationID = target.id
            await settle(new)
            XCTAssertEqual(DrawerListProbe.rows["candidate"]?[target.id], true)
            XCTAssertEqual(DrawerListProbe.counts["candidate.body", default: 0], 0)
            close(new)
        }
    }

    func testSameDayForegroundDoesNoListWorkAndStaleDayRefreshes() async throws {
        let model = fixture(20)
        let stale = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        for notification in [UIApplication.significantTimeChangeNotification, UIApplication.didBecomeActiveNotification] {
            let mounted = try await mount(model, baseline: false, options: .init(dateNow: stale))
            DrawerListProbe.reset()
            NotificationCenter.default.post(name: notification, object: nil)
            await settle(mounted)
            XCTAssertGreaterThan(DrawerListProbe.counts["candidate.group", default: 0], 0)
            DrawerListProbe.reset()
            NotificationCenter.default.post(name: notification, object: nil)
            await settle(mounted)
            XCTAssertEqual(DrawerListProbe.counts["candidate.group", default: 0], 0)
            close(mounted)
        }
    }

    func testDateContextHandlesMidnightDSTAndTimeZoneChange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let early = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1))!
        let late = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        XCTAssertTrue(DrawerListTestBridge.sameDateContext(early, late, calendar: calendar))
        XCTAssertFalse(DrawerListTestBridge.sameDateContext(late, tomorrow, calendar: calendar))
        var other = calendar; other.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertTrue(DrawerListTestBridge.differentCalendars(calendar, other, now: early))
    }
}

private extension View { func erased() -> AnyView { AnyView(self) } }
