"""Exercise actual approval admission, identity and cancellation methods under Swift 6."""
from pathlib import Path
import subprocess, hashlib,json
root=Path(__file__).resolve().parents[1];out=root/'work/review-tests';out.mkdir(parents=True,exist_ok=True)
app=(root/'Mocca/AppModel.swift').read_text();mcp=(root/'Mocca/MCP.swift').read_text()
def block(s, marker):
    start=s.index(marker);end=s.index('{',start)+1;depth=1
    while depth:
        depth+=(s[end]=='{')-(s[end]=='}');end+=1
    return s[start:end]
markers=['    func isToolInvocationCurrent(', '    func requestToolApproval(', '    func resolveToolApproval(']
source='import Foundation\n'+mcp[mcp.index('struct ToolInvocationContext:'):mcp.index('/// Every closure captures')]+'''
struct Conversation { let id:UUID; var title = "synthetic" }
@MainActor final class Model {
 var pendingToolApproval: MCPApprovalRequest?
 var pendingToolApprovalContinuation: CheckedContinuation<ToolApprovalDecision,Never>?
 var conversationPersistenceEpoch: UInt64 = 0
 var runs: [UUID:UUID] = [:]
 var activeStreamingMessageIDsByConversation: [UUID:UUID] = [:]
 var conversations: [Conversation] = []
 func isCurrentStreamingRun(_ id:UUID,runID:UUID) -> Bool { runs[id] == runID }
 func context() -> ToolInvocationContext {
  let c=ToolInvocationContext(conversationID:UUID(),runID:UUID(),messageID:UUID(),persistenceEpoch:0)
  runs[c.conversationID]=c.runID;activeStreamingMessageIDsByConversation[c.conversationID]=c.messageID
  conversations.append(Conversation(id:c.conversationID));return c
 }
'''+ '\n'.join(block(app,x) for x in markers)+'''
}
@MainActor func spin(_ condition: () -> Bool) async {
 for _ in 0..<10000 { if condition() { return }; await Task.yield() }
 fatalError("scheduler condition failed")
}
@main struct Runner {
 @MainActor static func main() async {
  for kind in [MCPApprovalRequest.Kind.mcp, .calendar] {
   let m=Model(), c=m.context(), other=m.context()
   let first=Task { await m.requestToolApproval(kind:kind,toolName:"A",preview:"A",context:c) }
   await spin { m.pendingToolApproval != nil }; let id=m.pendingToolApproval!.id
   let same = await m.requestToolApproval(kind:kind,toolName:"B",preview:"B",context:other)
   let cross = await m.requestToolApproval(kind:kind == .mcp ? .calendar : .mcp,toolName:"C",preview:"C",context:other)
   precondition(same == .busy && cross == .busy && m.pendingToolApproval?.id == id)
   m.resolveToolApproval(id:UUID(),decision:.approved);precondition(m.pendingToolApproval?.id == id)
   m.resolveToolApproval(id:id,decision:.approved);precondition(await first.value == .approved)
   m.resolveToolApproval(id:id,decision:.denied)
   let second=Task { await m.requestToolApproval(kind:kind,toolName:"D",preview:"D",context:other) }
   await spin { m.pendingToolApproval != nil };let next=m.pendingToolApproval!.id
   m.resolveToolApproval(id:id,decision:.approved);precondition(m.pendingToolApproval?.id == next)
   second.cancel();let cancelled=await second.value;precondition(cancelled == .expired && m.pendingToolApproval == nil)
   print("PASS A2 contention / cross-kind / stale callback / exactly once / cancellation \\(kind)")
  }
  for mode in ["run", "message", "epoch", "delete"] {
   let m=Model(),c=m.context()
   let t=Task { await m.requestToolApproval(kind:.calendar,toolName:"A",preview:"A",context:c) }
   await spin { m.pendingToolApproval != nil };let id=m.pendingToolApproval!.id
   switch mode {
   case "run":m.runs[c.conversationID]=UUID()
   case "message":m.activeStreamingMessageIDsByConversation[c.conversationID]=UUID()
   case "epoch":m.conversationPersistenceEpoch=1
   default:m.conversations=[]
   }
   m.resolveToolApproval(id:id,decision:.approved);let result=await t.value;precondition(result == .expired)
   print("PASS A2 invalidation "+mode)
  }
  let m=Model(),c=m.context()
  let t=Task { await m.requestToolApproval(kind:.mcp,toolName:"A",preview:"A",context:c) };t.cancel()
  let result=await t.value;precondition(result == .expired && m.pendingToolApproval == nil)
  print("PASS A2 cancelled before admission")
 }
}
'''
# Await outside precondition's synchronous autoclosure.
source=source.replace('precondition(await first.value == .approved)','let approved=await first.value;precondition(approved == .approved)')
(out/'Approvals.swift').write_text(source)
(out/'approval-extraction.json').write_text(json.dumps({m:hashlib.sha256(block(app,m).encode()).hexdigest() for m in markers},indent=2))
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(out/'Approvals.swift'),'-o',str(out/'approvals')],check=True)
subprocess.run([str(out/'approvals')],check=True,timeout=30)
