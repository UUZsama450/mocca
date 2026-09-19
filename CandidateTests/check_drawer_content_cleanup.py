"""Compare extracted 4990 functions with 4989 using Foundation and small UI mocks.

Exercises ordering, attachment references and cache-hit correction. This does
not measure TextKit height, SwiftUI identity, iPhone pixels or frame time.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
base = '0425a289c37a9d4a9d3e36d75ed8e9ec04f21f03'

def old(path):
    return subprocess.check_output(['git', 'show', f'{base}:{path}'], cwd=root, text=True)

def member(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '')

r = (root/'Mocca/RootView.swift').read_text()
b = old('Mocca/RootView.swift')
m = (root/'Mocca/MessageMarkdownView.swift').read_text()
mb = old('Mocca/MessageMarkdownView.swift')
# Bind extracted helpers to the real call sites; check guarded computation and
# retain the same conditional view tree, row IDs and view modifiers.
assert 'let filteredConversations = isContentSearchActive ? [] : self.filteredConversations' in r
assert 'ForEach(conversationDateGroups(for: filteredConversations))' in r
assert r.count('let attachments = assistantAttachments') == 1
assert r.count('if !attachments.other.isEmpty') == 2
assert r.count('if !attachments.searchImages.isEmpty') == 2
assert m.count('coordinator.horizontalRuleAttachments = horizontalRuleAttachments(in: textView)') == 1
apply = member(m, 'private func apply(to textView: GlyphSelectableTextView')
assert apply.index('guard let attributedText') < apply.index('textView.attributedText =') < apply.index('coordinator.horizontalRuleAttachments =')
measured = member(m, 'private func measuredLayoutSize(')
assert measured.index('updateHorizontalRuleAttachments(') < measured.index('if let localSize') < measured.index('let sharedSize')
assert '!coordinator.horizontalRuleAttachments.isEmpty' in member(m, 'private func fittedWidth(')

swift = r'''import Foundation
import CoreGraphics
struct Conversation: Equatable {
    var id: Int; var title: String; var updatedAt: Date; var createdAt: Date
    var groupAssistantIDs: [Int] = []
}
struct AssistantProfile: Equatable { var id: Int; var name: String }
struct ConversationDateGroup: Equatable { var day: Date; var conversations: [Conversation] }
enum DrawerSearchScope { case title, content }
final class Model {
    var conversations: [Conversation] = []
    var visibleConversations: [Conversation] = []
    var assistants: [AssistantProfile] = []
}
enum Kind { case image, file, audio }
struct MessageAttachment: Equatable { var id: Int; var kind: Kind; var metadata: [String:String] }
struct Message { var attachments: [MessageAttachment] }
'''
for name, src in [('Before', b), ('After', r)]:
    swift += f'final class {name} {{\n'
    swift += 'var model = Model(); var groupChatMode = false; var query = ""; var searchScope = DrawerSearchScope.title; var assistantsExpanded = false; var message = Message(attachments: [])\n'
    for marker in ['private var sourceConversations:', 'private var normalizedQuery:', 'private var filteredConversations:', 'private var filteredAssistants:']:
        swift += member(src, marker) + '\n'
    if name == 'Before':
        swift += member(src, 'private var conversationDateGroups:') + '\n'
        swift += member(src, 'private var assistantSearchImageAttachments:') + '\n'
        swift += member(src, 'private var assistantOtherAttachments:') + '\n'
    else:
        swift += member(src, 'private func conversationDateGroups(') + '\n'
        swift += member(src, 'private var assistantAttachments:') + '\n'
    swift += '}\n'

swift += r'''
final class HorizontalRuleTextAttachment: NSObject { var bounds = CGRect(x: 0, y: 4, width: 1, height: 1) }
extension NSAttributedString.Key { static let attachment = Self("attachment") }
final class LayoutManager {
    var layouts: [NSRange] = []; var displays: [NSRange] = []
    func invalidateLayout(forCharacterRange range: NSRange, actualCharacterRange: UnsafeMutablePointer<NSRange>?) { layouts.append(range) }
    func invalidateDisplay(forCharacterRange range: NSRange) { displays.append(range) }
}
struct Traits { var displayScale: CGFloat = 3 }
final class UITextView {
    var textStorage = NSMutableAttributedString(string: "")
    let layoutManager = LayoutManager(); var traitCollection = Traits(); var redraws = 0
    func setNeedsDisplay() { redraws += 1 }
}
typealias GlyphSelectableTextView = UITextView
final class Coordinator {
    var horizontalRuleAttachments: [HorizontalRuleTextAttachment] = []
    var measuredLayoutSizes: [String: CGSize] = [:]
}
final class UnifiedTextMeasurementCache {
    static let shared = UnifiedTextMeasurementCache(); var sizes: [String: CGSize] = [:]
    func value(for key: String) -> CGSize? { sizes[key] }
}
'''
swift += 'struct OldText {\n' + member(mb, 'private func updateHorizontalRuleAttachments(') + '\n}\n'
swift += 'struct NewText {\nvar renderSignature = "test"; var usesSharedMeasurementCache = true\n'
swift += member(m, 'private func horizontalRuleAttachments(') + '\n'
swift += member(m, 'private func updateHorizontalRuleAttachments(') + '\n'
# Execute the exact size-cache prefix with fake measured dimensions. No claim
# is made about the unexecuted detached TextKit measurement.
swift += measured[:measured.index('// Measure on a detached TextKit stack.')]
swift += 'return CGSize(width: -1, height: -1)\n}\n}\n'
swift += r'''
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label); checks += 1
}
let before = Before(), after = After()
let names = ["Alpha", "ALPHA", "示例聊天", "Beta", "café", "", "alpha 🐱"]
let start = Date(timeIntervalSince1970: 1788970000)
for i in 0..<140 {
    let c = Conversation(id: i, title: names[i % names.count],
        updatedAt: start.addingTimeInterval(Double(i % 7) * 86400 + Double(i % 3)),
        createdAt: start.addingTimeInterval(Double(i % 11)),
        groupAssistantIDs: i % 3 == 0 ? [1,2] : [])
    before.model.conversations.append(c)
    if i % 5 == 0 { before.model.visibleConversations.append(c) }
}
before.model.assistants = names.enumerated().map { AssistantProfile(id: $0.offset, name: $0.element) }
after.model = before.model
for empty in [false, true] {
    for query in ["", " \n ", "ALpHa", " 示例\n", "🦊", "CAFÉ", "🐱"] {
        for group in [false, true] {
            for scope in [DrawerSearchScope.title, .content] {
                for expanded in [false, true] {
                    before.query = query; after.query = query
                    before.groupChatMode = group; after.groupChatMode = group
                    before.searchScope = scope; after.searchScope = scope
                    before.assistantsExpanded = expanded; after.assistantsExpanded = expanded
                    check(before.filteredConversations == after.filteredConversations, "conversation source, membership and order")
                    check(before.filteredAssistants == after.filteredAssistants, "assistant order")
                    check(before.conversationDateGroups == after.conversationDateGroups(for: after.filteredConversations), "day and tie sorting")
                }
            }
        }
    }
    if !empty { before.model.conversations = []; before.model.visibleConversations = []; before.model.assistants = [] }
}
let kinds: [Kind] = [.image, .file, .audio]
let metadata: [[String:String]] = [[:], ["source":"web_search_image"], ["source":"other"], ["source":"WEB_SEARCH_IMAGE"]]
for length in 0...150 {
    let items = (0..<length).map { MessageAttachment(id: $0, kind: kinds[$0 % 3], metadata: metadata[($0 / 3) % 4]) }
    before.message.attachments = items; after.message.attachments = items
    let actual = after.assistantAttachments
    check(actual.searchImages == before.assistantSearchImageAttachments, "search image order")
    check(actual.other == before.assistantOtherAttachments, "other attachment order")
    check(actual.searchImages.count + actual.other.count == length, "partition conservation")
}
func install(_ count: Int, on view: UITextView) -> [HorizontalRuleTextAttachment] {
    let text = NSMutableAttributedString(string: "plain text 🐱")
    var rules: [HorizontalRuleTextAttachment] = []
    for i in 0..<count {
        let rule = HorizontalRuleTextAttachment(); rules.append(rule)
        text.append(NSAttributedString(string: "\u{fffc}", attributes: [.attachment: rule]))
        // Interleave unrelated attachment objects and differing attribute runs.
        text.append(NSAttributedString(string: "\u{fffc}more", attributes: [.attachment: NSNumber(value: i)]))
    }
    view.textStorage = text
    return rules
}
let oldText = OldText(), newText = NewText()
let oldView = UITextView(), newView = UITextView()
let coordinator = Coordinator()
for count in [0, 1, 5, 2, 0, 8] {
    let oldRules = install(count, on: oldView), newRules = install(count, on: newView)
    coordinator.horizontalRuleAttachments = newText.horizontalRuleAttachments(in: newView)
    check(coordinator.horizontalRuleAttachments.map(ObjectIdentifier.init) == newRules.map(ObjectIdentifier.init), "actual installed object references")
    for scale: CGFloat in [1, 2, 3, 0, 3] {
        oldView.traitCollection.displayScale = scale; newView.traitCollection.displayScale = scale
        for width: CGFloat in [320, 180, 320, 320.1, 1, 0, 390.25, 320] {
            oldText.updateHorizontalRuleAttachments(in: oldView, width: width)
            newText.updateHorizontalRuleAttachments(in: newView, attachments: coordinator.horizontalRuleAttachments, width: width)
            check(oldRules.map(\.bounds) == newRules.map(\.bounds), "width/scale A-B-A equivalence")
            check(oldView.layoutManager.layouts == newView.layoutManager.layouts, "layout invalidations")
            check(oldView.layoutManager.displays == newView.layoutManager.displays && oldView.redraws == newView.redraws, "display invalidations")
        }
    }
}
// Shared cache hit on a fresh view, followed by width B and local-cache A.
for shared in [false, true] {
    let view = UITextView(), c = Coordinator()
    let rules = install(3, on: view)
    c.horizontalRuleAttachments = newText.horizontalRuleAttachments(in: view)
    let key = "test|width:960|scale:3.0", expected = CGSize(width: 320, height: 42)
    UnifiedTextMeasurementCache.shared.sizes = [:]
    if shared { UnifiedTextMeasurementCache.shared.sizes[key] = expected } else { c.measuredLayoutSizes[key] = expected }
    check(newText.measuredLayoutSize(for: view, width: 320, coordinator: c) == expected, "correct cached dimensions")
    check(rules.allSatisfy { abs($0.bounds.width - (320 - 1.0/3.0)) < 0.001 }, "cached size still corrects fresh attachment width")
    _ = newText.measuredLayoutSize(for: view, width: 180, coordinator: c)
    check(newText.measuredLayoutSize(for: view, width: 320, coordinator: c) == expected, "return to cached width A")
    check(rules.allSatisfy { abs($0.bounds.width - (320 - 1.0/3.0)) < 0.001 }, "cached A restores attachments after B")
}
let emptyView = UITextView()
check(newText.horizontalRuleAttachments(in: emptyView).isEmpty, "empty attributed storage")
print("PASS \(checks) production-extracted equivalence checks; UIKit/SwiftUI pixels and performance not simulated")
'''
with tempfile.TemporaryDirectory(prefix='mocca-drawer-cleanup-') as tmp:
    source = Path(tmp)/'main.swift'; source.write_text(swift)
    binary = Path(tmp)/'check'
    subprocess.run(['xcrun','swiftc',str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
print('PASS call-site/cache-order source checks')
