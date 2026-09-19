"""Compare extracted 4996/4997 production chat presentation calculations.

The macOS Foundation host checks data/labels, not SwiftUI pixels, animation,
device frame time or persistence. No simulator or application process is used.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = "6650f29"
OUT = ROOT / "work/verification/chat-render-work-reuse-host"


def before(path):
    return subprocess.check_output(
        ["git", "show", f"{BASE}:{path}"], cwd=ROOT, text=True
    )


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private ", "")


def renamed(source, label):
    for name in ["isWebSearchToolEvent", "toolEventResultObject",
                 "toolEventHasErrorResult", "ToolEventDetailFormatter",
                 "ToolEventPresentationGroup", "ToolEventParsedResult",
                 "ToolEventResultPresentation", "WebSearchToolEventGroupSummary"]:
        source = re.sub(r"\b" + name + r"\b", label + name, source)
    return source


def production_helpers(source, label):
    start = source.index("private func isWebSearchToolEvent(")
    end = source.index("private struct ToolEventsCard:", start)
    return renamed(source[start:end].replace("private ", ""), label)


def old_row(source):
    source = block(source, "private struct ToolEventRow:")
    members = ["private var normalizedName:", "private var arguments:",
               "private func argumentText(", "private var activityText:",
               "private var isWebSearch:", "private var semanticIcon:",
               "private var hasDetails:", "private var detailPreview:",
               "private var statusColor:", "private var accessibilityStatus:"]
    return "struct BeforeRow {\nlet event: ToolEvent\nvar usesGroupedWebSearchLabel = false\n" + "\n".join(
        renamed(block(source, m.replace("private ", "")), "Before") for m in members
    ) + "\n}\n"


def old_group(source):
    source = block(source, "private struct WebSearchToolEventGroupRow:")
    members = ["var runningCount:", "var failureCount:", "var webResultCount:",
               "var expandedSummary:", "var headerColor:", "var accessibilityStatus:"]
    return "struct BeforeGroup {\nlet events: [ToolEvent]\n" + "\n".join(
        renamed(block(source, m), "Before") for m in members
    ) + "\n}\n"


def row_snapshot_method(source, label):
    row = block(source, "private struct ToolEventRow:")
    body = block(row, "var body:")
    prefix = body[body.index("{") + 1:body.index("VStack(")]
    hint = re.search(r"\.accessibilityHint\((.*)\)", body).group(1)
    a11y = re.search(r"\.accessibilityLabel\((.*)\)", body).group(1)
    return renamed("func snapshot(_ isExpanded: Bool) -> RowSnapshot {\n" + prefix +
        "return RowSnapshot(activity: activityText, icon: semanticIcon, detail: detailPreview, hasDetails: hasDetails, color: statusColor.rawValue, status: accessibilityStatus, label: " + a11y + ", hint: " + hint + ", visibleDetail: isExpanded ? detailPreview : nil)\n}\n", label)


def after_row(source):
    row = block(source, "private struct ToolEventRow:")
    members = ["var normalizedName:", "var arguments:", "func argumentText(",
               "var activityText:", "var isWebSearch:", "var semanticIcon:",
               "func accessibilityStatus(hasError:"]
    return "struct AfterRow {\nlet event: ToolEvent\nvar usesGroupedWebSearchLabel = false\nvar parsedResult: AfterToolEventParsedResult? = nil\n" + "\n".join(
        renamed(block(row, m), "After") for m in members
    ) + "\n" + row_snapshot_method(source, "After") + "}\n"


def group_snapshot_method(source, label):
    row = block(source, "private struct WebSearchToolEventGroupRow:")
    body = block(row, "var body:")
    prefix = body[body.index("{") + 1:body.index("VStack(")]
    summary = "summary." if label == "After" else ""
    hint = re.search(r"\.accessibilityHint\((.*)\)", body).group(1)
    a11y = re.search(r"\.accessibilityLabel\((.*)\)", body).group(1)
    return renamed("func snapshot(_ isExpanded: Bool) -> GroupSnapshot {\n" + prefix +
        f"return GroupSnapshot(running: {summary}runningCount, failures: {summary}failureCount, webResults: {summary}webResultCount, expanded: {summary}expandedSummary, color: headerColor.rawValue, status: {summary}accessibilityStatus, label: " + a11y + ", hint: " + hint + f", visibleSummary: isExpanded ? {summary}expandedSummary : nil)\n}}\n", label)


def version_model(source, label):
    markers = ["private func sortedVersions("]
    if label == "Before":
        markers += ["func versions(for messageID: UUID) ->", "private func messageLocation("]
    else:
        markers += ["func versions(for messageID: UUID, in conversationID: UUID)"]
    return f"final class {label}Model {{\nvar messagesByConversation: [UUID: [ChatMessage]] = [:]\n" + "\n".join(
        block(source, marker) for marker in markers
    ) + "\n}\n"


def version_control(source, label):
    src = block(source, "private struct MessageInlineActionsBar:")
    result = f"final class {label}Control {{\nlet model: {label}Model; let message: ChatMessage; var target: UUID?\n"
    result += f"init(model: {label}Model, message: ChatMessage) {{ self.model=model; self.message=message }}\n"
    result += "func onSelectVersion(_ message: ChatMessage, _ selected: ChatMessage) { target = selected.id }\n"
    result += block(src, "var responseVersions:") + "\n"
    selector = block(src, "func responseVersionSelector(")
    for direction, text in [("Previous", "上一版回答"), ("Next", "下一版回答")]:
        offset = selector.index('label: "' + text + '"')
        action = selector[selector.index(") {", offset) + 2:]
        action = block(action, "{")
        result += f"func tap{direction}(_ selectedIndex: Int) " + action + "\n"
    result += "}\n"
    result += f"func {label.lower()}Click(_ model: {label}Model, _ id: UUID, _ index: Int, _ delta: Int) -> UUID? {{\n"
    result += f"let control = {label}Control(model: model, message: ChatMessage(id: id, conversationID: c1, versionGroupID: \"g\", version: 1, createdAt: Date(timeIntervalSince1970: 10)))\n"
    result += "if delta < 0 { control.tapPrevious(index) } else { control.tapNext(index) }; return control.target\n}\n"
    return result


TOOL_CASES = r'''
let payloads: [String?] = [nil, "", " \n\t", "{", "null", "true", "42", "\"文本 🐈 é\"", "[]", "[1, null]", "{}",
    "success", "DELETED", " completed ", "plain\ntext",
    #"{"error":null}"#, #"{"error":false,"message":"失败正文"}"#,
    #"{"error":"bad","message":"  "}"#, #"{"error":{"detail":"bad"}}"#,
    #"{"summary":"第一","message":"第二","result":3,"text":"第四","title":"第五"}"#,
    #"{"summary":" ","message":false,"result":"第三"}"#,
    #"{"items":[{}, {"url":"https://example.com"}, {"url":""}, {"url":"relative"}, {"url":42}, {"url":"http://["}]}"#,
    #"{"items":[{"url":"https://example.com"},null,42]}"#,
    #"{"success":true}"#, #"{"success":false}"#,
    #"{"current":{"weather_code":95,"temperature_c":21.25,"relative_humidity_percent":0},"forecast":[{"temperature_min_c":-3,"temperature_max_c":4.4,"precipitation_probability_max_percent":80}]}"#,
    #"{"current":{"weather_code":999,"condition":"自定义天气","wind_speed_kmh":8}}"#,
    #"{"date":"2026-09-10","time":"12:34","timezone":"UTC+8"}"#,
    #"{"action":"created","reminder":{"title":"示例abc"}}"#,
    #"{"action":"deleted","title":"旧提醒"}"#,
    String(repeating: "🧑🏽‍💻é\n", count: 90),
    "\u{a0}{\"error\":\"bad\",\"message\":\"NBSP\"}\u{a0}",
    "\u{2028}{\"items\":[{\"url\":\"https://example.com\"}]}\u{2028}",
    "\u{feff}{\"message\":\"BOM\"}"]
let names = ["search_web", " WEB_SEARCH ", "web_search_preview", "web_search_other", "builtin_search",
    "get_local_weather", "get_time_info", "calculate", "manage_reminders", "search_conversations",
    "create_memory", "生成图片", "unknown_TOOL"]
let arguments: [String?] = [nil, " ", "null", "[]", "{",
    #"{"query":"优先","q":"次选","search_query":"三","prompt":"四"}"#,
    #"{"query":"  ","q":42,"search_query":" 三 ","prompt":"四"}"#,
    #"{"query":null,"q":false,"text":"中文🧑🏽‍💻","city":" 杭州 ","action":" UPDATE "}"#,
    #"{"location":" ","city":" 杭州 ","action":"create"}"#]
let statuses: [ToolEvent.Status] = [.pending, .running, .complete, .failed]
var cases: [ToolEvent] = []
for (i, payload) in payloads.enumerated() {
    for name in names {
        for status in statuses {
            cases.append(ToolEvent(name: name, argumentsJSON: arguments[i % arguments.count], resultText: payload, status: status))
        }
    }
}
for argument in arguments {
    for name in ["search_web", "search_conversations", "get_local_weather", "manage_reminders"] {
        cases.append(ToolEvent(name: name, argumentsJSON: argument, resultText: #"{"message":"完成"}"#, status: .complete))
    }
}
'''


VERSION_CASES = r'''
let c1 = uid(1000), c2 = uid(2000), absent = uid(9999)
func message(_ id: Int, _ conversation: UUID, _ group: String?, _ version: Int, _ date: Double = 0) -> ChatMessage {
    ChatMessage(id: uid(id), conversationID: conversation, versionGroupID: group, version: version, createdAt: Date(timeIntervalSince1970: date))
}
let originals = [message(3,c1,"g",2,20), message(1,c1,"g",1,10), message(2,c1,"g",1,10),
                 message(4,c1,"g",1,5), message(5,c1,"other",0), message(6,c1,nil,0),
                 message(7,c1,"",0), message(8,c1,"",1)]
var beforeModel = BeforeModel(), afterModel = AfterModel()
beforeModel.messagesByConversation = [c1: originals, c2: [message(9,c2,"g",-1), message(10,c2,"g",3)]]
afterModel.messagesByConversation = beforeModel.messagesByConversation
for id in originals.map(\.id) + [uid(9), uid(10), absent] {
    let old = beforeModel.versions(for: id)
    let owner = old.first?.conversationID ?? c1
    check(old == afterModel.versions(for: id, in: owner), "scoped versions ordering/absent/cross-conversation")
}
check(afterModel.versions(for: uid(1), in: c1).map(\.id) == [4,1,2,3].map(uid), "version,date,UUID ordering")
check(afterModel.versions(for: uid(9), in: c2).map(\.id) == [9,10].map(uid), "same group in another conversation remains isolated")
check(afterModel.versions(for: uid(6), in: c1).map(\.id) == [uid(6)], "nil version group uses own id")
for (label, changed) in [
    ("append version", originals + [message(11,c1,"g",4)]),
    ("remove earlier version", originals.filter { $0.id != uid(4) }),
    ("remove visible message", originals.filter { $0.id != uid(1) }),
    ("change grouping", [message(1,c1,"changed",1)] + originals.filter { $0.id != uid(1) }),
    ("empty conversation", [])
] {
    beforeModel.messagesByConversation[c1] = changed
    afterModel.messagesByConversation[c1] = changed
    check(beforeModel.versions(for: uid(1)) == afterModel.versions(for: uid(1), in: c1), label)
    for delta in [-1,1] {
        let capturedIndex = 1 // Original row for id 1 was rendered at index 1.
        let beforeTarget = beforeClick(beforeModel, uid(1), capturedIndex, delta)
        let afterTarget = afterClick(afterModel, uid(1), capturedIndex, delta)
        check(beforeTarget == afterTarget, "click re-reads current data: \(label) delta=\(delta)")
    }
}
'''


def main():
    old_r, old_m = before("Mocca/RootView.swift"), before("Mocca/AppModel.swift")
    r = (ROOT / "Mocca/RootView.swift").read_text()
    m = (ROOT / "Mocca/AppModel.swift").read_text()
    storage = (ROOT / "Mocca/ConversationStore.swift").read_text()
    hashes = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
              for path in ["Mocca/RootView.swift", "Mocca/AppModel.swift"]}
    # View modifiers remain source-reviewed; this binds host extraction to
    # production's one prepared-result handoff for an expanded grouped row.
    group_body = block(r, "private struct WebSearchToolEventGroupRow:")
    assert "parsedResult: presentation.result" in group_body
    assert "ForEach(presentations)" in group_body
    swift = r'''import Foundation
enum Color: String { case red, secondary }
struct RowSnapshot: Equatable {
    var activity: String; var icon: String; var detail: String?; var hasDetails: Bool
    var color: String; var status: String; var label: String; var hint: String; var visibleDetail: String?
}
struct GroupSnapshot: Equatable {
    var running: Int; var failures: Int; var webResults: Int; var expanded: String?
    var color: String; var status: String; var label: String; var hint: String; var visibleSummary: String?
}
struct ChatMessage: Equatable {
    enum Role { case assistant, user }
    let id: UUID; let conversationID: UUID; var versionGroupID: String?; var version: Int; var createdAt: Date
    var role: Role = .assistant
'''
    swift += block(storage, "var versionGroupKey:") + "\n}\n"
    swift += block(storage, "struct ToolEvent:") + "\n"
    swift += production_helpers(old_r, "Before") + production_helpers(r, "After")
    swift += old_row(old_r).removesuffix("}\n") + row_snapshot_method(old_r, "Before") + "}\n"
    swift += after_row(r)
    swift += old_group(old_r).removesuffix("}\n") + group_snapshot_method(old_r, "Before") + "}\n"
    swift += renamed(block(r, "private struct WebSearchToolEventGroupSummary"), "After") + "\n"
    swift += "struct AfterGroup { let events: [ToolEvent]\n" + group_snapshot_method(r, "After") + "}\n"
    swift += version_model(old_m, "Before") + version_model(m, "After")
    swift += version_control(old_r, "Before") + version_control(r, "After")
    # Count real JSON parser calls in the extracted functions; the wrapper
    # delegates unchanged to Foundation and is not an alternative parser.
    swift = swift.replace("JSONSerialization.jsonObject(", "countedJSON(")
    swift += r'''
var jsonParses = 0
func countedJSON(with data: Data, options: JSONSerialization.ReadingOptions = []) throws -> Any {
    jsonParses += 1
    return try JSONSerialization.jsonObject(with: data, options: options)
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label); checks += 1
}
func uid(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))! }
'''
    swift += TOOL_CASES
    swift += r'''
var beforeCalls = 0, afterCalls = 0
for (index, event) in cases.enumerated() {
    for grouped in [false, true] {
        for expanded in [false, true] {
            jsonParses = 0
            let old = BeforeRow(event: event, usesGroupedWebSearchLabel: grouped).snapshot(expanded)
            beforeCalls += jsonParses
            jsonParses = 0
            let new = AfterRow(event: event, usesGroupedWebSearchLabel: grouped).snapshot(expanded)
            afterCalls += jsonParses
            check(old == new, "row \(index) \(event.name) state=\(event.status) grouped=\(grouped) expanded=\(expanded) old=\(old) new=\(new)")
            let prepared = AfterToolEventParsedResult(event: event)
            check(new == AfterRow(event: event, usesGroupedWebSearchLabel: grouped, parsedResult: prepared).snapshot(expanded), "preparsed expanded child reuses equivalent result")
        }
    }
}
check(afterCalls < beforeCalls, "real parser calls reduced across bounded row matrix")
var groupCases: [[ToolEvent]] = [[], [cases[0]], [cases[0], cases[1]]]
for offset in stride(from: 0, to: cases.count - 7, by: 17) {
    groupCases.append(Array(cases[offset..<(offset + 7)]))
}
for events in groupCases {
    for expanded in [false, true] {
        check(BeforeGroup(events: events).snapshot(expanded) == AfterGroup(events: events).snapshot(expanded), "group status/URL count/header/expanded/a11y")
    }
    let oldGroups = BeforeToolEventPresentationGroup.make(from: events)
    let newGroups = AfterToolEventPresentationGroup.make(from: events)
    check(oldGroups.map { $0.events.map(\.id) } == newGroups.map { $0.events.map(\.id) }, "adjacent search grouping and stable IDs")
    check(oldGroups.map(\.isGroupedWebSearch) == newGroups.map(\.isGroupedWebSearch), "search group classification")
}
let example = ToolEvent(name: "search_web", argumentsJSON: #"{"query":" ","q":"优先","search_query":"次选","prompt":"末选"}"#, resultText: #"{"error":null,"message":"正文"}"#, status: .complete)
let exampleRow = AfterRow(event: example).snapshot(false)
check(exampleRow.activity == "浏览多个网站查找 优先", "blank query falls through in original key order")
check(exampleRow.status == "失败" && exampleRow.detail == "失败：正文", "JSON null error key still means error")
var mutable = ToolEvent(name: "calculate", resultText: nil, status: .running)
for (status, text) in [(ToolEvent.Status.running, Optional("{broken")), (.complete, Optional(#"{"result":42}"#)), (.failed, nil)] {
    mutable.status = status; mutable.resultText = text
    check(BeforeRow(event: mutable).snapshot(true) == AfterRow(event: mutable).snapshot(true), "same event identity changing live status/result invalidates computed presentation")
}
let shared = AfterToolEventResultPresentation(event: example)
jsonParses = 0
_ = AfterWebSearchToolEventGroupSummary(presentations: [shared])
_ = AfterRow(event: shared.event, usesGroupedWebSearchLabel: true, parsedResult: shared.result).snapshot(true)
check(jsonParses == 1, "shared group result is not reparsed; one argument parse remains")
'''
    swift += VERSION_CASES
    swift += r'''
afterModel.messagesByConversation = [c1: originals, c2: [message(9,c2,"g",-1)]]
beforeModel.messagesByConversation = afterModel.messagesByConversation
for conversationID in [c1,c2,absent] {
    for id in originals.map(\.id) + [uid(9),absent] {
        if let old = beforeModel.versions(for: id).first, old.conversationID == conversationID {
            check(beforeModel.versions(for: id) == afterModel.versions(for: id, in: conversationID), "scoped query matches global query for owning conversation")
        } else {
            check(afterModel.versions(for: id, in: conversationID).isEmpty, "scoped query never borrows another conversation or deleted row")
        }
    }
}
let report: [String: Any] = ["checks":checks,"rowCases":cases.count,"groupCases":groupCases.count,"beforeJSONCalls":beforeCalls,"afterJSONCalls":afterCalls,"result":"PASS"]
let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
'''
    OUT.mkdir(parents=True, exist_ok=True)
    host = OUT / "ChatRenderWorkReuseHost.swift"
    binary = OUT / "ChatRenderWorkReuseHost"
    host.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-O", str(host), "-o", str(binary)], check=True, cwd=ROOT)
    output = subprocess.check_output([str(binary)], text=True, cwd=ROOT)
    assert hashes == {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
                      for path in hashes}, "Product source changed while host ran"
    report = json.loads(output)
    report.update(base=BASE, sourceSHA256=hashes,
                  limitations="macOS Foundation semantic comparison; no SwiftUI pixels, iPhone frame-time or device interaction validation")
    (OUT / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
