"""Compile unchanged product methods with deterministic network/storage substitutes."""
from pathlib import Path
import subprocess, hashlib, json
root=Path(__file__).resolve().parents[1]
out=root/'work/review-tests';out.mkdir(parents=True,exist_ok=True)
app=(root/'Mocca/AppModel.swift').read_text();mcp=(root/'Mocca/MCP.swift').read_text()
def block(s, marker):
    start=s.index(marker); end=s.index('{',start)+1; depth=1
    while depth:
        depth+=(s[end]=='{')-(s[end]=='}');end+=1
    return s[start:end]
markers=['    func upsertMCPServer(', '    func deleteMCPServers(', '    func refreshMCPTools(', '    private func currentMCPRefreshIndex(']
source=mcp[:mcp.index('struct MCPApprovalRequest')]+'''
struct Assistant { var mcpServerIDs: [UUID] = [] }
@MainActor enum AssistantPersistence { static func saveAssistants(_ a: [Assistant]) {} }
@MainActor enum MCPPersistence { static var saves = 0; static func saveServers(_ a: [MCPServerConfig]) { saves += 1 } }
@MainActor enum MCPHTTPClient {
 static var pending: [CheckedContinuation<[MCPToolConfig], Error>] = []
 static func listTools(server: MCPServerConfig, timeoutSeconds: Int) async throws -> [MCPToolConfig] {
  try await withCheckedThrowingContinuation { pending.append($0) }
 }
 static func answer(_ i: Int, _ name: String) { pending[i].resume(returning: [MCPToolConfig(name: name)]) }
 static func fail(_ i: Int) { pending[i].resume(throwing: NSError(domain:"synthetic",code:1)) }
}
@MainActor final class Model {
 var mcpServers: [MCPServerConfig] = []
 var mcpRuntimeStates: [UUID:MCPServerRuntimeState] = [:]
 var mcpRefreshRequestIDs: [UUID:UUID] = [:]
 var mcpRequestTimeoutSeconds = 30
 var assistants: [Assistant] = []
'''+ '\n'.join(block(app,x) for x in markers)+'''
}
@MainActor func spin(_ condition: () -> Bool) async {
 for _ in 0..<10000 { if condition() { return }; await Task.yield() }
 fatalError("scheduler condition failed")
}
@main struct Runner {
 @MainActor static func main() async {
  let modes = ["delete-target", "delete-predecessor", "preferences", "newest-success", "stale-error", "configuration", "delete-readd", "cancel", "single-sync"]
  for mode in modes {
   MCPHTTPClient.pending=[]; MCPPersistence.saves=0
   let m=Model(); let a=MCPServerConfig(name:"A"), b=MCPServerConfig(name:"B",tools:[MCPToolConfig(name:"write")]), c=MCPServerConfig(name:"C")
   m.mcpServers=[a,b,c]
   if mode == "single-sync" {
    m.upsertMCPServer(b,refreshTools:false)
    let t=Task { await m.refreshMCPTools(serverID:b.id) }
    await spin { MCPHTTPClient.pending.count == 1 }
    for _ in 0..<100 { await Task.yield() }
    precondition(MCPHTTPClient.pending.count == 1)
    MCPHTTPClient.answer(0,"write");await t.value
   } else {
    let t=Task { await m.refreshMCPTools(serverID:b.id) }
    await spin { MCPHTTPClient.pending.count == 1 }
    switch mode {
    case "delete-target": m.deleteMCPServers(at:IndexSet(integer:1))
    case "delete-predecessor": m.deleteMCPServers(at:IndexSet(integer:0))
    case "preferences": m.mcpServers[1].tools[0].needsApproval=true; m.mcpServers[1].tools[0].enabled=false
    case "configuration": var changed=b;changed.url="https://changed.invalid"; m.upsertMCPServer(changed,refreshTools:false)
    case "delete-readd": m.deleteMCPServers(at:IndexSet(integer:1));m.upsertMCPServer(b,refreshTools:false)
    case "newest-success", "stale-error":
     let t2=Task { await m.refreshMCPTools(serverID:b.id) };await spin { MCPHTTPClient.pending.count == 2 }
     MCPHTTPClient.answer(1,"new");await t2.value
    case "cancel": t.cancel()
    default: fatalError(mode)
    }
    if mode == "stale-error" { MCPHTTPClient.fail(0) } else { MCPHTTPClient.answer(0,"write") }
    await t.value
    let result=m.mcpServers.first { $0.id == b.id }
    switch mode {
    case "delete-target": precondition(result == nil && m.mcpRuntimeStates[b.id] == nil)
    case "delete-predecessor": precondition(result?.tools.first?.name == "write" && m.mcpServers[1].id == c.id && m.mcpServers[1].tools.isEmpty)
    case "preferences": precondition(result?.tools.first?.needsApproval == true && result?.tools.first?.enabled == false)
    case "newest-success", "stale-error": precondition(result?.tools.first?.name == "new" && m.mcpRuntimeStates[b.id]?.status == .connected)
    case "configuration", "delete-readd", "cancel": precondition(MCPPersistence.saves == (mode == "cancel" ? 0 : mode == "delete-readd" ? 2 : 1));precondition(m.mcpRuntimeStates[b.id]?.status == .idle)
    default: break
    }
   }
   print("PASS A1 "+mode)
  }
 }
}
'''
(out/'MCPRefresh.swift').write_text(source)
(out/'mcp-extraction.json').write_text(json.dumps({m:hashlib.sha256(block(app,m).encode()).hexdigest() for m in markers},indent=2))
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(out/'MCPRefresh.swift'),'-o',str(out/'mcp-refresh')],check=True)
subprocess.run([str(out/'mcp-refresh')],check=True,timeout=30)
