"""Isolated actual draft alert, message editor, menu label and bundled-logo UI."""
from pathlib import Path
import sys,plistlib,shutil,hashlib
from check_drawer_close_driver_reuse import extract
root=Path(__file__).resolve().parents[1];out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=False)
exitView=extract((root/'Mocca/DraftEditing.swift').read_text(),r'^struct DraftExitConfirmation:')[0]
message=extract((root/'Mocca/RootView.swift').read_text(),r'^private struct MessageEditSheet:')[0]
menu=extract((root/'Mocca/ProviderViews.swift').read_text(),r'^private struct ProviderTypeMenuLabel:')[0]
models=(root/'Mocca/ProviderModels.swift').read_text()
source='''import SwiftUI
import UIKit
enum L10n { static func lookup(_ key: String) -> String { key } }
enum Brand { case openAI, gemini, claude
 var assetName: String { switch self { case .openAI: "ProviderOpenAI"; case .gemini: "ProviderGemini"; case .claude: "ProviderClaude" } }
 var usesTemplateRendering: Bool { self == .openAI }
}
enum ProviderType: String, CaseIterable, Identifiable { case openAI, google, claude
 var id: Self { self }
 var title: String { switch self { case .openAI: "OpenAI"; case .google: "Google"; case .claude: "Claude" } }
 var brandIcon: Brand { switch self { case .openAI: .openAI; case .google: .gemini; case .claude: .claude } }
}
@main struct DialogOrderApp: App { var body: some Scene { WindowGroup { Fixture() } } }
struct Fixture: View {
 @State private var leave = false
 @State private var editor = false
 @State private var failure = false
 @State private var text = "Synthetic editable message"
 @State private var outcome = "unchanged"
 @State private var selectedType = ProviderType.openAI
 var mode: String { ProcessInfo.processInfo.arguments.dropFirst().first ?? "normal" }
 var body: some View {
  NavigationStack {
   VStack(spacing: 24) {
    Form {
     Picker("供应商类型", selection: $selectedType) {
      ForEach(ProviderType.allCases) { type in ProviderTypeMenuLabel(type: type).tag(type) }
     }.accessibilityIdentifier("provider-type-picker")
    }.frame(height: 110)
    Text(outcome).accessibilityIdentifier("outcome")
    Button("Open confirmation") { leave = true }
    Button("Edit message") { editor = true }
    ForEach(ProviderType.allCases) { type in
     let size = UIImage(named: type.brandIcon.assetName)?.size ?? .zero
     Text("\\(type.title): \\(Int(size.width))x\\(Int(size.height))").accessibilityIdentifier("size.\\(type.title)")
    }
   }.navigationTitle("Dialog QA").toolbar {
    Menu {
     ForEach(ProviderType.allCases) { type in Button {} label: { ProviderTypeMenuLabel(type: type) } }
    } label: { Image(systemName: "plus") }.accessibilityLabel("Provider logos")
   }
  }
  .background {
   DraftExitConfirmation(isPresented: $leave, title: "保存修改？", onSave: {
    if mode == "failure" { failure = true } else { outcome = "saved" }
   }, onDiscard: { outcome = "discarded" }, message: "合成草稿尚未保存。",
    showsSave: mode != "hidden", saveEnabled: mode != "disabled")
  }
  .alert("保存失败", isPresented: $failure) { Button("好",role:.cancel) {} }
  .sheet(isPresented: $editor) {
   MessageEditSheet(text: $text, roleTitle: "编辑助手消息", allowsSaveAndSend: mode != "saveOnly") { send in outcome = send ? "sent" : "saved" }
  }
  .preferredColorScheme(mode == "dark" ? .dark : .light)
 }
}
'''+exitView+'\n'+message+'\n'+menu
(out/'DialogOrderHost.swift').write_text(source)
generator=(root/'CandidateTests/prepare_settings_modal_ui.py').read_text();generator=generator[generator.index('project_dir = OUT /'):]
bundle='com.mocca.qa.dialogorder.'+hashlib.sha256(str(out).encode()).hexdigest()[:8]
generator=generator.replace('SettingsModalSmoke','DialogOrder').replace('com.mocca.local.settings-modal-5032',bundle)
exec(generator,{'ROOT':root,'OUT':out,'plistlib':plistlib})
project=out/'DialogOrder.xcodeproj/project.pbxproj';d=plistlib.loads(project.read_bytes());o=d['objects']
key='A52550000000000000000001';o[key]={'isa':'PBXFileReference','lastKnownFileType':'folder.assetcatalog','path':str(root/'Mocca/Assets.xcassets'),'sourceTree':'<absolute>'}
build='A52550000000000000000002';o[build]={'isa':'PBXBuildFile','fileRef':key};phase='A52550000000000000000003';o[phase]={'isa':'PBXResourcesBuildPhase','buildActionMask':2147483647,'files':[build],'runOnlyForDeploymentPostprocessing':0}
app=next(v for v in o.values() if v.get('isa')=='PBXNativeTarget' and v.get('name')=='DialogOrder');app['buildPhases'].append(phase)
o[o[d['rootObject']]['mainGroup']]['children'].append(key);project.write_bytes(plistlib.dumps(d))
