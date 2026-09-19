"""Isolated UI host: actual approval methods and alert modifier, synthetic run/store."""
from pathlib import Path
import subprocess,hashlib,json
root=Path(__file__).resolve().parents[1];out=root/'work/review-approval-ui';out.mkdir(parents=True,exist_ok=True)
# The method harness is generated and validated first.
subprocess.run(['/usr/bin/python3',str(root/'CandidateTests/run_review_approvals.py')],check=True)
s=(root/'work/review-tests/Approvals.swift').read_text();s=s[:s.index('@main struct Runner')]
s=s.replace('import Foundation','import Foundation\nimport SwiftUI\nimport Observation',1)
s=s.replace('@MainActor final class Model','@MainActor @Observable final class AppModel').replace(' var pendingToolApprovalContinuation:', ' @ObservationIgnored var pendingToolApprovalContinuation:')
s=s.replace('var title = "synthetic"','var title = "Synthetic chat"')
mcp=(root/'Mocca/MCP.swift').read_text();modifier=mcp[mcp.index('struct ToolApprovalAlertModifier:'):mcp.index('\nenum MCPPersistence')]
s+=modifier+'''
@main struct ReviewApprovalApp: App {
 @State private var model=AppModel()
 var body: some Scene { WindowGroup { Fixture(model:model) } }
}
struct Fixture:View {
 let model:AppModel
 @State private var result="idle"
 @State private var competing="idle"
 func ask(_ kind:MCPApprovalRequest.Kind, parallel:Bool=false, cancel:Bool=false) {
  result="waiting"; competing="idle"
  let context=model.context()
  let waiter=Task { @MainActor in
   result=(await model.requestToolApproval(kind:kind,toolName:"synthetic tool",preview:"synthetic arguments",context:context)).rawValue
  }
  if cancel { Task { @MainActor in try? await Task.sleep(for:.seconds(3));waiter.cancel() } }
  if parallel {
   Task { @MainActor in
    await spin { model.pendingToolApproval != nil }
    competing=(await model.requestToolApproval(kind:.calendar,toolName:"other",preview:"other",context:context)).rawValue
   }
  }
 }
 var body:some View {
  VStack(spacing:30) {
   Text(result);Text(competing)
   Button("MCP") { ask(.mcp) }
   Button("日历") { ask(.calendar) }
   Button("自动取消") { ask(.mcp,cancel:true) }
   Button("同时请求") { ask(.mcp,parallel:true) }
  }.modifier(ToolApprovalAlertModifier(model:model,request:model.pendingToolApproval))
 }
}
'''
(out/'Host.swift').write_text(s)
# Reuse only the minimal Xcode project generator (no old host source or tests).
gen=(root/'CandidateTests/prepare_settings_modal_ui.py').read_text();gen=gen[gen.index('project_dir = OUT /'):]
gen=gen.replace('SettingsModalSmokeHost.swift','Host.swift').replace('SettingsModalSmokeUITests.swift','ReviewApprovalUITests.swift')
gen=gen.replace('com.mocca.local.settings-modal-5032','com.mocca.local.review-approval-5047')
exec('from pathlib import Path\nimport plistlib\nROOT=root\nOUT=out\n'+gen)
(out/'source.json').write_text(json.dumps({'app_model_sha256':hashlib.sha256((root/'Mocca/AppModel.swift').read_bytes()).hexdigest(),'mcp_sha256':hashlib.sha256(mcp.encode()).hexdigest(),'limitations':__doc__},indent=2))
