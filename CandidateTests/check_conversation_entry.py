"""Execute production selection/window lifecycle and materializer admission.
Mocks model storage and frame availability; does not emulate SwiftUI or pixels.
"""
from pathlib import Path
import re, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
m=(root/'Mocca/AppModel.swift').read_text(); r=(root/'Mocca/RootView.swift').read_text()
old_m=subprocess.check_output(['git','show','f0971aa:Mocca/AppModel.swift'],cwd=root,text=True)
def block(text, token):
    start=text.index(token); opening=text.index('{',start); depth=1; i=opening+1
    while depth:
        depth += (text[i]=='{')-(text[i]=='}'); i+=1
    return text[start:i]
source='''import Foundation
struct Segment { var text: String }
struct Event { var name: String; var argumentsJSON: String?; var resultText: String? }
enum Role { case user, assistant }
struct ChatMessage {
 let id = UUID(); var text: String; var role: Role = .user
 var reasoningSegments: [Segment] = []; var toolEvents: [Event] = []
}
struct Conversation { let id: UUID }
struct Preferences { var keepSidebarOpenOnTopicTap = false }
'''+block(m,'private struct MessageWindowState')+'''
private final class Fixture {
 static var initialEvaluations = 0
 var selectedConversationID = UUID()
 var conversationBottomReturnRequest = 0
 var conversationBottomReturnTargetID: UUID?
 private var concreteConversationEntryWindow: (conversationID: UUID, request: Int)?
 var pendingMessageTargetNavigationRequest: UUID?
 var preferences = Preferences()
 var drawer = true
 var streaming: Set<UUID> = []
 var conversations: [Conversation] = []
 var records: [UUID: [ChatMessage]] = [:]
 var messageWindowsByConversation: [UUID: MessageWindowState] = [:]
 func selectedMessages(for id: UUID) -> [ChatMessage] { records[id] ?? [] }
 func isConversationStreaming(_ id: UUID) -> Bool { streaming.contains(id) }
 func setDrawerPresented(_ value: Bool) { drawer = value }
 func resetWindow(_ id: UUID) { _=resetMessageWindowToLatest(for: id) }
 var window: MessageWindowState { messageWindow(for: selectedConversationID, messages: selectedMessages(for: selectedConversationID)) }
 var messages: [ChatMessage] { Array(selectedMessages(for: selectedConversationID)[window.startIndex..<window.endIndex]) }
 var hasLaterMessages: Bool { window.endIndex < selectedMessages(for: selectedConversationID).count }
 func add(_ weights: [Int], role: Role = .user) -> UUID {
  let id=UUID(); conversations.append(Conversation(id: id))
  records[id]=weights.map { ChatMessage(text: String(repeating: "a", count: $0), role: role) }; return id
 }
 static func normalizeForTest(_ window: MessageWindowState, totalCount: Int,
                              fallback: () -> MessageWindowState) -> MessageWindowState {
  normalizedMessageWindow(window, totalCount: totalCount, fallback: fallback())
 }
'''
for c in ['messageWindowConcreteMax','messageWindowInitialTextBudget','messageWindowPageSize','messageWindowLoadedMax','messageWindowInitialMin','messageWindowInitialMax','messageWindowBottomNavigationMax']:
 source+=re.search(r'    private static let '+c+r' = [\d_]+',m).group()+'\n'
for t in ['    var usesConcreteConversationEntryWindow:', '    func releaseConcreteConversationEntryWindow()', '    private func prepareConcreteConversationEntryWindow()', '    private static func boundedConcreteMessageWindow(', '    private static func initialMessageWindow(', '    private static func normalizedMessageWindow(', '    private static func messageRenderWeight(', '    private func messageWindow(for', '    private func resetMessageWindowToLatest(', '    func loadEarlierMessages()', '    func loadLaterMessages()', '    func loadStartMessageWindow()', '    func loadLatestBottomNavigationWindow()', '    func selectConversation(_ id: UUID, closeDrawer:']:
 extracted=block(m,t)
 if t == '    private static func initialMessageWindow(':
  # Count entry to the actual extracted production function. Its branches and
  # returned window are unchanged; this is a host-only observation point.
  extracted=extracted.replace('{','{\n        Self.initialEvaluations += 1',1)
 source+=extracted+'\n'
source+='''}
private enum LegacyWindowPolicy {
 static func normalizeForTest(_ window: MessageWindowState, totalCount: Int,
                              fallback: MessageWindowState) -> MessageWindowState {
  normalizedMessageWindow(window, totalCount: totalCount, fallback: fallback)
 }
 static func initialForTest(_ messages: [ChatMessage]) -> MessageWindowState {
  initialMessageWindow(for: messages)
 }
'''
for c in ['messageWindowInitialMin','messageWindowInitialMax','messageWindowLoadedMax','messageWindowInitialTextBudget']:
 source+=re.search(r'    private static let '+c+r' = [\d_]+',old_m).group()+'\n'
for t in ['    private static func initialMessageWindow(', '    private static func normalizedMessageWindow(', '    private static func messageRenderWeight(']:
 source+=block(old_m,t)+'\n'
source+='''}
struct ConversationBottomAnchorID {}
struct ScrollViewProxy {}
private final class ViewFixture {
 let model: Fixture; var tailFrame = false; var legacyCalls = 0
 init(_ model: Fixture) { self.model = model }
 func hasConcreteTailFrame(for anchor: ConversationBottomAnchorID) -> Bool { tailFrame }
'''
f=block(r,'    private func scheduleBottomRowMaterializationIfNeeded(')
prefix=f[:f.index('        guard shouldKeepNativeBottomPosition')]
source+=prefix.replace('private func','func')+'''        legacyCalls += 1
        return false
    }
}
@main struct Tests {
 static func main() {
  var count=0
  func check(_ value: Bool, _ name: String) { precondition(value,name); count += 1; print("PASS \\(name)") }
  let f=Fixture(); let users=f.add(Array(repeating: 100,count: 100)); let assistants=f.add(Array(repeating: 100,count: 16),role: .assistant)
  let original=f.records[users]!.map(\\.id)
  f.selectConversation(users,closeDrawer: false)
  check(f.usesConcreteConversationEntryWindow && f.window.count == 12 && f.window.endIndex == 100,"user-tail entry prepared synchronously")
  check(f.drawer && f.conversationBottomReturnTargetID == users,"existing covered drawer selection preserved")
  check(f.records[users]!.map(\\.id) == original,"entry does not change canonical messages")
  let view=ViewFixture(f)
  check(view.scheduleBottomRowMaterializationIfNeeded(for: .init(),using: .init()) && view.legacyCalls == 0,"entry missing frame waits without legacy top seed")
  view.tailFrame=true
  check(!view.scheduleBottomRowMaterializationIfNeeded(for: .init(),using: .init()) && view.legacyCalls == 0,"entry frame lets existing readiness continue without top seed")
  f.selectConversation(assistants)
  check(f.usesConcreteConversationEntryWindow && f.window.count == 12 && !f.drawer,"assistant-tail follows same bounded route")
  f.selectConversation(users)
  check(f.usesConcreteConversationEntryWindow && f.conversationBottomReturnRequest == 3,"rapid A B A prepares current request")
  f.resetWindow(assistants)
  check(f.usesConcreteConversationEntryWindow,"background window reset preserves current entry")
  let request=f.conversationBottomReturnRequest
  f.selectConversation(UUID())
  check(f.conversationBottomReturnRequest == request && f.selectedConversationID == users,"invalid selection leaves current request unchanged")
  f.conversationBottomReturnRequest += 1
  check(!f.usesConcreteConversationEntryWindow,"different request cannot reuse entry lease")
  f.selectConversation(users)
  f.selectedConversationID=assistants
  check(!f.usesConcreteConversationEntryWindow,"different conversation cannot reuse entry lease")
  f.selectConversation(users)
  check(f.loadEarlierMessages() && !f.usesConcreteConversationEntryWindow,"history paging releases concrete entry")
  while f.loadEarlierMessages() {}
  check(f.window.startIndex == 0,"full earlier history remains reachable")
  while f.loadLaterMessages() {}
  check(!f.hasLaterMessages && f.records[users]!.map(\\.id)==original,"full later history remains reachable")
  f.selectConversation(users); _=f.loadStartMessageWindow()
  check(!f.usesConcreteConversationEntryWindow,"top navigation owns its window")
  f.selectConversation(users); _=f.loadLatestBottomNavigationWindow()
  check(!f.usesConcreteConversationEntryWindow,"bottom navigation owns its window")
  f.streaming.insert(users); f.selectConversation(users)
  check(!f.usesConcreteConversationEntryWindow,"already-streaming entry retains established path")
  check(!view.scheduleBottomRowMaterializationIfNeeded(for: .init(),using: .init()) && view.legacyCalls == 1,"non-entry materialization remains eligible for legacy path")
  let empty=f.add([]); f.selectConversation(empty)
  check(!f.usesConcreteConversationEntryWindow && f.messages.isEmpty,"empty chat retains empty lifecycle")
  let short=f.add([2]); f.selectConversation(short)
  check(f.usesConcreteConversationEntryWindow && f.window.count == 1,"short chat remains concrete")
  let giant=f.add([9000,9000,30000]); f.selectConversation(giant)
  check(f.usesConcreteConversationEntryWindow && f.window.count == 1 && f.window.startIndex == 2,"oversized tail laid out alone")
  let weighted=f.add(Array(repeating: 6000,count: 16)); f.selectConversation(weighted)
  check(f.window.count == 3,"text budget excludes oversized neighbours")
  f.selectConversation(assistants)
  f.records[assistants]! += Array(repeating: ChatMessage(text: "a"), count: 20)
  f.messageWindowsByConversation[assistants] = MessageWindowState(startIndex: 0,count: f.records[assistants]!.count)
  check(!f.usesConcreteConversationEntryWindow,"eager mode cannot grow beyond 24 canonical rows")
  f.releaseConcreteConversationEntryWindow()
  check(!f.usesConcreteConversationEntryWindow,"explicit release remains inert")
  var normalizationCases=0
  for total in [0,1,2,3,12,20,100,500] {
   for start in [-4,0,1,max(0,total-1),total,total+5] {
    for amount in [-3,0,1,2,12,360,500] {
     for fallback in [MessageWindowState(startIndex: 0,count: 0),
                      MessageWindowState(startIndex: max(0,total-2),count: 2),
                      MessageWindowState(startIndex: -9,count: 500)] {
      let stored=MessageWindowState(startIndex: start,count: amount)
      var calls=0
      let actual=Fixture.normalizeForTest(stored,totalCount: total) { calls += 1; return fallback }
      let expected=LegacyWindowPolicy.normalizeForTest(stored,totalCount: total,fallback: fallback)
      precondition(actual == expected,"normalization differs from production 4995")
      let needsFallback=total > 0 && (start >= total || amount <= 0)
      precondition(calls == (needsFallback ? 1 : 0),"fallback is evaluated only for an unusable stored window, once")
      normalizationCases += 1
     }
    }
   }
  }
  check(normalizationCases == 1008,"1008 stored/total/fallback boundary combinations match 4995")
  for weights in [[],[1],[500,500],[9000,9000,30000],Array(repeating: 100,count: 260)] {
   let probe=Fixture(); let id=probe.add(weights); probe.selectedConversationID=id
   Fixture.initialEvaluations=0
   let missing=probe.window
   check(Fixture.initialEvaluations == 1 && missing == LegacyWindowPolicy.initialForTest(probe.records[id]!),
         "missing stored window still computes the original initial policy once")
   probe.messageWindowsByConversation[id]=missing
   Fixture.initialEvaluations=0
   let existing=probe.window
   check(Fixture.initialEvaluations == 0 && existing == missing,
         "valid stored or empty total avoids initial text-weight scans")
   if !weights.isEmpty {
    probe.messageWindowsByConversation[id]=MessageWindowState(startIndex: weights.count+5,count: -1)
    Fixture.initialEvaluations=0
    let repaired=probe.window
    check(Fixture.initialEvaluations == 1 && repaired == missing,
          "invalid stored window evaluates initial policy once and preserves original repair")
   }
  }
  print("PASS \\(count) entry lifecycle checks")
 }
}
'''
with tempfile.TemporaryDirectory() as td:
 p=Path(td)/'entry.swift'; p.write_text(source); exe=Path(td)/'entry'
 subprocess.run(['swiftc','-parse-as-library',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
