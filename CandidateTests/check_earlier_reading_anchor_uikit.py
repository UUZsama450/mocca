"""Run the extracted paging host on a booted iOS simulator, never a phone.

First run check_earlier_reading_anchor.py candidate to generate current source.
Usage: /usr/bin/python3 CandidateTests/check_earlier_reading_anchor_uikit.py SIMULATOR_ID
The tiny test app uses synthetic rows and native offsets, not real touch physics.
"""
from pathlib import Path
import hashlib
import json
import platform
import plistlib
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'work/verification/history-reading-anchor/uikit-final'
OUT.mkdir(parents=True, exist_ok=True)
SIMULATOR = sys.argv[1]
BUNDLE = 'com.mocca.local.paging5072'


def block(source, token):
    start = source.index(token)
    cursor = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == '{') - (source[cursor] == '}')
        cursor += 1
    return source[start:cursor]


production = (ROOT / 'Mocca/RootView.swift').read_text().replace('private ', '')
s = (OUT.parent / 'final-viewport/candidate.swift').read_text()
for token in ['struct MessageWindowReadingAnchor {',
              'func captureEarlierWindowReadingAnchor(',
              'func resolveEarlierWindowReadingAnchor(',
              'func scheduleMessageWindowLoad(']:
    assert block(s, token) == block(production, token), 'Regenerate the extracted host first'
s = s.replace('import AppKit', 'import UIKit')
for old, new in [('NSViewRepresentable', 'UIViewRepresentable'), ('makeNSView', 'makeUIView'),
                 ('updateNSView', 'updateUIView'), ('NSView', 'UIView'),
                 ('NSScrollView', 'UIScrollView'), ('NSWindow', 'UIWindow'),
                 ('NSPoint', 'CGPoint'), ('NSRect', 'CGRect')]:
    s = s.replace(old, new)
s = s.replace('view.contentView.bounds.origin', 'view.contentOffset')
s = s.replace('view.documentView!.frame.size', 'view.contentSize')
s = s.replace('view.contentView.bounds.size', 'view.bounds.size')
s = s.replace('view.contentView.scroll(to: point); view.reflectScrolledClipView(view.contentView)',
              'view.setContentOffset(point, animated: false)')
s = s.replace('var isDragging = false', 'var isDragging: Bool { view.isDragging }')
s = s.replace('let adjustedContentInset = Insets()',
              'var adjustedContentInset: UIEdgeInsets { view.adjustedContentInset }')
s = s.replace('@MainActor enum Metrics {', '''@MainActor final class WeakRow {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}
@MainActor enum Metrics {
    static var nativeRows: [UUID: WeakRow] = [:]''')
s = s.replace('        return UIView()', '''        let view = UIView()
        Metrics.nativeRows[messageID] = WeakRow(view)
        return view''')
s = s.replace('                    let readingID =', '''                    func nativeFrame(_ id: UUID) -> CGRect? {
                        guard let view = Metrics.nativeRows[id]?.view, view.window != nil else { return nil }
                        let viewport = scroll.convert(scroll.bounds, to: host)
                        return view.convert(view.bounds, to: host).offsetBy(dx: -viewport.minX, dy: -viewport.minY)
                    }
                    let nativeBefore = visible.keys.reduce(into: [UUID: CGRect]()) { $0[$1] = nativeFrame($1) }
                    let readingID =''')
s = s.replace('[820, 820.001, 819.99, 1100, 80, 1750, 220, 100]',
              '[labViewportHeight, labViewportHeight + 0.001, labViewportHeight - 0.01, 1100, 80, 1750, 220, 100]')
s = s.replace('@MainActor struct Host: View {', '''
let labTopInset: CGFloat = CommandLine.arguments.contains("header") || CommandLine.arguments.contains("both") ? 48 : 0
let labBottomInset: CGFloat = CommandLine.arguments.contains("both") ? 34 : 0
let labViewportHeight: CGFloat = 820 - labTopInset - labBottomInset
struct LabHeader: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .safeAreaBar(edge: .top, spacing: 0) { Color.clear.frame(height: labTopInset) }
                .safeAreaBar(edge: .bottom, spacing: 0) { Color.clear.frame(height: labBottomInset) }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else { content }
    }
}
@MainActor struct Host: View {''')
s = s.replace('        .coordinateSpace(name: "chat-scroll")', '''        .modifier(LabHeader())
        .coordinateSpace(name: "chat-scroll")
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)''')
s = s.replace('@main struct Check {\n    @MainActor static func main() throws {',
              'struct Check {\n    @MainActor static func run() async throws {')
s = s.replace('_ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)', '')
a = s.index('            let host = NSHostingView')
b = s.index('            func settle', a)
s = s[:a] + '''            let controller = UIHostingController(rootView: Host(model: fixture).ignoresSafeArea())
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 820))
            window.rootViewController = controller; window.makeKeyAndVisible()
            let host = controller.view!
''' + s[b:]
s = s.replace('func settle(_ duration: TimeInterval = 0.12) {',
              'func settle(_ duration: TimeInterval = 0.12) async {')
s = s.replace('host.needsLayout = true; host.layoutSubtreeIfNeeded()', 'host.setNeedsLayout(); host.layoutIfNeeded()')
s = s.replace('RunLoop.main.run(until: Date().addingTimeInterval(0.002))',
              'try? await Task.sleep(for: .milliseconds(2))')
s = re.sub(r'(?m)^(\s*)settle\(', r'\1await settle(', s)
s = s.replace('scroll.contentView.bounds.minY', 'scroll.contentOffset.y')
s = s.replace('scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, offset)))',
              'scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, offset)), animated: false)')
s = s.replace('                    scroll.reflectScrolledClipView(scroll.contentView)\n', '')
a = s.index('                    if let wheel =')
b = s.index('                    await settle()', a)
s = s[:a] + s[b:]
s = s.replace('window.contentView = nil; Metrics.paging = nil',
              'window.isHidden = true; window.rootViewController = nil; Metrics.paging = nil')
s = s.replace('"deltas": deltas,', '"insets": [scroll.adjustedContentInset.top, scroll.adjustedContentInset.bottom], "deltas": deltas,')
s = s.replace('"deltas": deltas,', '''"readingIndex": readingID.flatMap { id in fixture.allMessages.firstIndex { $0.id == id } } ?? -1,
                        "readingBefore": readingID.flatMap { visible[$0] }.map { [$0.minY, $0.height] } ?? [],
                        "readingAfter": readingID.flatMap { Metrics.frames[$0] }.map { [$0.minY, $0.height] } ?? [],
                        "nativeReadingBefore": readingID.flatMap { nativeBefore[$0] }.map { [$0.minY, $0.height] } ?? [],
                        "nativeReadingAfter": readingID.flatMap(nativeFrame).map { [$0.minY, $0.height] } ?? [],
                        "nativeDeltas": nativeBefore.compactMap { id, frame in nativeFrame(id).map { $0.minY - frame.minY } },
                        "deltas": deltas,''')
a = s.index('        print(String(data: try JSONSerialization.data(withJSONObject: events')
b = s.index('\n    }', a)
s = s[:a] + '''        let data = try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys])
        try data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results.json"), options: .atomic)
''' + s[b:]
s += '''
@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in do { try await Check.run() } catch { print(error) } }
        return true
    }
}
'''
(OUT / 'UIKitHost.swift').write_text(s)
app = OUT / 'PagingHost.app'
app.mkdir(exist_ok=True)
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': BUNDLE, 'CFBundleName': 'PagingHost', 'CFBundleExecutable': 'PagingHost',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
    'MinimumOSVersion': '18.0', 'UIDeviceFamily': [1], 'UILaunchScreen': {}}))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-sdk', sdk, '-target',
                platform.machine() + '-apple-ios18.0-simulator', '-swift-version', '6',
                '-parse-as-library', str(OUT / 'UIKitHost.swift'), '-o', str(app / 'PagingHost')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['xcrun', 'simctl', 'install', SIMULATOR, str(app)], check=True)
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', SIMULATOR, BUNDLE, 'data'], text=True).strip())
result_file = container / 'Documents/results.json'
summaries = {}
try:
    for insets, expected_insets in [('header', [48, 0]), ('both', [48, 34]), ('none', [0, 0])]:
        if len(sys.argv) > 2 and insets not in sys.argv[2:]:
            continue
        for pattern in ['mixed', 'equal']:
            subprocess.run(['xcrun', 'simctl', 'terminate', SIMULATOR, BUNDLE], capture_output=True)
            result_file.unlink(missing_ok=True)
            subprocess.run(['xcrun', 'simctl', 'launch', SIMULATOR, BUNDLE, 'wheel', pattern, insets], check=True, capture_output=True)
            deadline = time.monotonic() + 70
            while not result_file.exists() and time.monotonic() < deadline:
                time.sleep(0.5)
            events = json.loads(result_file.read_text())
            label = insets + '-' + pattern
            (OUT / (label + '.json')).write_text(json.dumps(events, indent=2) + '\n')
            eligible = [e for e in events if e['earlier'] and e['readingEligible']]
            summary = {
                'pages': len(events), 'eligibleEarlier': len(eligible),
                'fallbackEarlier': sum(e['earlier'] and not e['readingEligible'] for e in events),
                'eligibleMaxDelta': max(abs(d) for e in eligible for d in e['deltas']),
                'eligibleMissing': sum(not e['readingRetained'] or e['retained'] != e['beforeVisible'] for e in eligible),
                'eligibleNativeMaxDelta': max(abs(d) for e in eligible for d in e['nativeDeltas']),
                'eligibleNativeMissing': sum(len(e['nativeReadingBefore']) != 2 or len(e['nativeReadingAfter']) != 2
                                            or len(e['nativeDeltas']) != e['beforeVisible'] for e in eligible),
                'maxCommands': max(e['commands'] for e in events),
                'maxNativeWrites': max(e['nativeWrites'] for e in events),
                'allTasksFinished': all(e['taskFinished'] for e in events),
                'actualInsets': sorted({tuple(e['insets']) for e in events})}
            summaries[label] = summary
            print(json.dumps({label: summary}), flush=True)
            assert all(e['insets'] == expected_insets for e in events), summary
            assert summary['eligibleMaxDelta'] < 0.5 and summary['eligibleMissing'] == 0, summary
            assert summary['eligibleNativeMaxDelta'] < 0.5 and summary['eligibleNativeMissing'] == 0, summary
            assert all(e['commands'] == 1 and e['nativeWrites'] == 0 and e['taskFinished'] for e in events), summary
finally:
    subprocess.run(['xcrun', 'simctl', 'terminate', SIMULATOR, BUNDLE], capture_output=True)
    (OUT / 'summary.json').write_text(json.dumps(summaries, indent=2) + '\n')
    (OUT / 'source.json').write_text(json.dumps({'root_sha256': hashlib.sha256((ROOT / 'Mocca/RootView.swift').read_bytes()).hexdigest(), 'simulator': SIMULATOR}, indent=2) + '\n')
