import AppKit
import SwiftUI
import Foundation
import QuartzCore

enum AppFontStore {
    static func uiFont(postScriptName: String?, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard let name = postScriptName, let font = NSFont(name: name, size: size) else {
            return .systemFont(ofSize: size, weight: weight)
        }
        return weight.rawValue >= NSFont.Weight.semibold.rawValue
            ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }
    static func swiftUIFont(postScriptName: String?, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let name = postScriptName else { return .system(size: size, weight: weight) }
        return .custom(name, size: size).weight(weight)
    }
}

@MainActor enum MarkdownRenderCache {
    static var values: [String: AttributedString] = [:]
    static func attributedText(for source: String) -> AttributedString {
        if let value = values[source] { return value }
        let value = makeAttributedText(for: source)
        values[source] = value
        return value
    }
    static func makeAttributedText(for source: String) -> AttributedString {
        (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }
}
struct DrawerHorizontalScrollProbe: View { var body: some View { Color.clear } }
struct FramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
@MainActor enum Recorder {
    static var frames: [String: CGRect] = [:]
}
extension View {
    @ViewBuilder func tableCellActions(_ text: String, enabled: Bool) -> some View {
        if enabled {
            contextMenu {
                Button("复制这一格") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                ShareLink(item: text) { Label("分享这一格", systemImage: "square.and.arrow.up") }
            }
        } else { self }
    }
    @ViewBuilder func reportFrame(_ name: String) -> some View {
        #if GEOMETRY
        background(GeometryReader { proxy in
            Color.clear.preference(key: FramesKey.self, value: [name: proxy.frame(in: .named("root"))])
        })
        #else
        self
        #endif
    }
}
struct Scenario {
    var name = "initial"
    var rows = 8
    var columns = 3
    var width: CGFloat = 356
    var fontSize: CGFloat = 18
    var lineSpacing: CGFloat = 4
    var fontName: String?
    var changedText = false
    var rightToLeft = false
    var dark = false
    var dynamicType: DynamicTypeSize = .large
    var usesCache = true
    var actions = true
    var finite = false

    var table: MarkdownTableContent {
        let alignments: [MarkdownTableColumnAlignment] = [.leading, .center, .trailing]
        let values: [String] = ["短内容", "中文说明会自动换行，每一行高度都需要正确。", "**Bold** and `code` with [link](https://example.com)",
                                "第一行\n第二行 e\u{301} 🚲 👨‍👩‍👧‍👦", "العربية نص للاختبار", ""]
        let body = (0..<rows).map { row in
            (0..<columns).map { column in
                let text = values[(row + column) % values.count]
                if changedText && row == rows - 1 && column == 0 {
                    return String(repeating: "修改后很长的文字需要重新换行。", count: 12)
                }
                return text + ((row + column) % 7 == 0 ? String(repeating: "long wrapped text ", count: 5) : "")
            }
        }
        return MarkdownTableContent(header: (0..<columns).map { "表头 \($0)" },
                                    alignments: (0..<columns).map { alignments[$0 % 3] }, rows: body)
    }
}
struct FixtureView: View {
    let scenario: Scenario
    let candidate: Bool
    @ViewBuilder var table: some View {
        if candidate {
            CandidateTable(table: scenario.table, fontSize: scenario.fontSize, lineSpacing: scenario.lineSpacing,
                           allowsTextSelection: scenario.actions, fontName: scenario.fontName, usesCache: scenario.usesCache)
        } else {
            BaselineTable(table: scenario.table, fontSize: scenario.fontSize, lineSpacing: scenario.lineSpacing,
                          allowsTextSelection: scenario.actions, fontName: scenario.fontName, usesCache: scenario.usesCache)
        }
    }
    var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("表格前正文").font(.system(size: 18)).reportFrame("before")
            table.reportFrame("table")
            Text("表格后正文：应当完整处于表格下面。\n继续检查第二行。").font(.system(size: 18))
                .fixedSize(horizontal: false, vertical: true).reportFrame("after")
            HStack { Text("复制"); Text("重试"); Text("编辑") }.frame(height: 28).reportFrame("actions")
        }.frame(maxWidth: .infinity, alignment: .leading).reportFrame("stack")
    }
    #if GEOMETRY
    @ViewBuilder var snapshotTable: some View {
        if candidate {
            CandidateTableSnapshot(table: scenario.table, fontSize: scenario.fontSize, lineSpacing: scenario.lineSpacing,
                                   allowsTextSelection: scenario.actions, fontName: scenario.fontName, usesCache: scenario.usesCache)
        } else {
            BaselineTableSnapshot(table: scenario.table, fontSize: scenario.fontSize, lineSpacing: scenario.lineSpacing,
                                  allowsTextSelection: scenario.actions, fontName: scenario.fontName, usesCache: scenario.usesCache)
        }
    }
    #endif
    var body: some View {
        Group {
            if scenario.finite { content.frame(maxHeight: .infinity, alignment: .top) }
            else { ScrollView(.vertical) { content } }
        }
        .coordinateSpace(name: "root")
        .environment(\.layoutDirection, scenario.rightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.colorScheme, scenario.dark ? .dark : .light)
        .environment(\.dynamicTypeSize, scenario.dynamicType)
        .onPreferenceChange(FramesKey.self) { value in MainActor.assumeIsolated { Recorder.frames = value } }
    }
}

@main struct Main {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        var results: [[String: Any]] = []
        if mode == "geometry" {
            var scenarios: [Scenario] = []
            var next = Scenario()
            scenarios.append(next)
            next.name = "text-update"; next.changedText = true; scenarios.append(next)
            next.name = "append-rows"; next.rows = 17; scenarios.append(next)
            next.name = "remove-rows"; next.rows = 2; scenarios.append(next)
            next.name = "font-size"; next.fontSize = 25; scenarios.append(next)
            next.name = "line-spacing"; next.lineSpacing = 9; scenarios.append(next)
            next.name = "custom-font"; next.fontName = "Menlo"; scenarios.append(next)
            next.name = "dynamic-type"; next.dynamicType = .accessibility2; scenarios.append(next)
            next.name = "rtl"; next.rightToLeft = true; scenarios.append(next)
            next.name = "dark"; next.dark = true; scenarios.append(next)
            next.name = "wide"; next.width = 500; scenarios.append(next)
            next.name = "narrow"; next.width = 260; scenarios.append(next)
            next.name = "streaming"; next.usesCache = false; next.actions = false; scenarios.append(next)
            next.name = "header-only"; next.rows = 0; scenarios.append(next)
            next.name = "one-column"; next.rows = 4; next.columns = 1; scenarios.append(next)
            next = Scenario(); next.name = "long-table"; next.rows = 32; next.columns = 5; scenarios.append(next)
            next.name = "finite-parent"; next.finite = true; scenarios.append(next)
            for candidate in [false, true] {
                Recorder.frames = [:]
                let host = NSHostingView(rootView: FixtureView(scenario: scenarios[0], candidate: candidate))
                let window = makeWindow(host: host, width: scenarios[0].width)
                for scenario in scenarios {
                    // A color/cache-policy change can preserve every frame, so
                    // onPreferenceChange correctly emits nothing. Keep the last
                    // snapshot for this same host until SwiftUI publishes a change.
                    host.rootView = FixtureView(scenario: scenario, candidate: candidate)
                    window.setContentSize(NSSize(width: scenario.width, height: 620))
                    host.frame = NSRect(x: 0, y: 0, width: scenario.width, height: 620)
                    for _ in 0..<4 {
                        host.layoutSubtreeIfNeeded()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.012))
                    }
                    results.append(["case": scenario.name, "variant": candidate ? "candidate" : "baseline",
                                    "expectedCells": (scenario.rows + 1) * scenario.columns,
                                    "frames": Recorder.frames.mapValues { frame in
                                        ["x": frame.minX, "y": frame.minY, "width": frame.width,
                                         "height": frame.height, "maxY": frame.maxY]
                                    }])
                    if ["initial", "text-update", "rtl"].contains(scenario.name) {
                        #if GEOMETRY
                        // Render the Grid/cells directly; ImageRenderer omits
                        // platform-backed scroll views on this macOS host.
                        let renderer = ImageRenderer(content:
                            FixtureView(scenario: scenario, candidate: candidate).snapshotTable
                                .fixedSize(horizontal: true, vertical: true)
                                .frame(width: scenario.width, height: 620, alignment: .topLeading)
                                .clipped().background(Color.white)
                                .environment(\.layoutDirection, scenario.rightToLeft ? .rightToLeft : .leftToRight)
                                .environment(\.colorScheme, scenario.dark ? .dark : .light)
                                .environment(\.dynamicTypeSize, scenario.dynamicType)
                        )
                        renderer.scale = 2
                        if let cgImage = renderer.cgImage,
                           let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                            try data.write(to: output.appendingPathComponent("\(scenario.name)-\(candidate ? "candidate" : "baseline").png"))
                        }
                        #endif
                    }
                }
                window.contentView = nil
                window.close()
            }
        } else {
            for rows in [16, 64, 160] {
                for iteration in 0..<6 {
                    for candidate in (iteration.isMultiple(of: 2) ? [false, true] : [true, false]) {
                        var scenario = Scenario()
                        scenario.rows = rows; scenario.columns = 5
                        MarkdownRenderCache.values.removeAll()
                        let start = ProcessInfo.processInfo.systemUptime
                        let host = NSHostingView(rootView: FixtureView(scenario: scenario, candidate: candidate))
                        let window = makeWindow(host: host, width: scenario.width)
                        host.layoutSubtreeIfNeeded()
                        let end = ProcessInfo.processInfo.systemUptime
                        results.append(["rows": rows, "iteration": iteration, "candidate": candidate,
                                        "mount_ms": (end - start) * 1_000])
                        window.contentView = nil
                        window.close()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("\(mode).json"))
        print("HOST_COMPLETE \(mode) records=\(results.count)")
    }

    @MainActor static func makeWindow(host: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 620),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 620)
        return window
    }
}
