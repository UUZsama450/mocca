"""Isolated UI fixture using the production row, toggle and filter methods.

Visual glyphs and model metadata are synthetic. No networking, credentials,
app startup services or chat storage. Pass a new output directory.
"""
from pathlib import Path
import sys, hashlib, json
from check_drawer_close_driver_reuse import extract
root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve(); out.mkdir(parents=True, exist_ok=False)
provider = (root/'Mocca/ProviderViews.swift').read_text()
search = extract((root/'Mocca/ProviderModels.swift').read_text(), r'^struct ModelSearchQuery')[0]
intent = extract(provider, r'^private struct ModelCatalogIntentButtonStyle:')[0]
intent += '\n' + extract(provider, r'^private struct ModelCatalogTapSurface:')[0]
row = extract(provider, r'^    private func modelSelectionRow\(')[0]
toggle = extract(provider, r'^    private func toggle\(_ model: ModelConfiguration\)')[0]
filtered = extract(provider, r'^    private var filteredCatalog:')[0]
controls = extract(provider, r'^    private var searchControls:')[0]
bulk = '\n'.join(extract(provider, pattern)[0] for pattern in [
 r'^    private var allFilteredSelected:', r'^    private func toggleAllFiltered\(',
 r'^    private func invertFilteredSelection\(', r'^    private func appendMissing\('])
source = '''import SwiftUI
import UIKit
@Observable final class CatalogHapticProbe {
 var calls = 0
 func performListItemHaptic() { calls += 1 }
}
struct ModelConfiguration: Identifiable {
 let id: String
 let displayName: String
 let capabilities = 0
}
enum L10n { static func lookup(_ key: String) -> String {
 if key == "反选", ProcessInfo.processInfo.arguments.contains("-english") { return "Invert" }
 return key
} }
struct ProviderModelCatalogGlyph: View {
 let model: ModelConfiguration; let size: CGFloat
 var body: some View { Image(systemName: "cube").frame(width: size, height: size) }
}
struct ProviderModelCapabilityChips: View {
 let capabilities: Int
 var body: some View { HStack { Text("聊天"); Text("Aa"); Text("工具") }.font(.caption).foregroundStyle(.secondary) }
}
@main struct CatalogQA: App {
 var body: some Scene { WindowGroup { CatalogRoot() } }
}
struct CatalogRoot: View {
 @State var shown = true
 var body: some View {
  Color.gray.sheet(isPresented: $shown) {
   CatalogFixture().presentationDetents(ProcessInfo.processInfo.arguments.contains("-medium") ? [.medium, .large] : [.large])
  }
 }
}
struct CatalogFixture: View {
 @State private var appModel = CatalogHapticProbe()
 @State private var models: [ModelConfiguration] = []
 @State private var query = ""
 @FocusState private var isSearchFocused: Bool
 private var selectedIDs: Set<String> { Set(models.map(\\.id)) }
 private let catalog = [ModelConfiguration(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5"), ModelConfiguration(id: "openai/gpt-4o", displayName: "GPT-4o")]
  + (0..<180).map { ModelConfiguration(id: String(format: "catalog-%03d", $0), displayName: String(format: "Catalog %03d", $0)) }
  + [ModelConfiguration(id: "deepseek/deepseek-v3.1-terminus", displayName: "DeepSeek: DeepSeek V3.1 Terminus"),
     ModelConfiguration(id: "provider/" + String(repeating: "very-long-model-", count: 12) + "2026-10-26:preview", displayName: "Long Variant Preview With Extended Provider Details And Release Suffix")]
 var body: some View {
  VStack {
   searchControls
   Button("Clear search") { query = "" }
   Text("Selected \\(models.count)").accessibilityIdentifier("count")
   Text("Haptics \\(appModel.calls)").accessibilityIdentifier("haptics")
   ScrollView { LazyVStack(spacing: 0) {
    ForEach(filteredCatalog) { model in modelSelectionRow(model); Divider() }
   }}
  }.padding(.top, 16).frame(width: ProcessInfo.processInfo.arguments.contains("-compact") ? 320 : nil)
 }
'''+row+'\n'+toggle+'\n'+filtered+'\n'+controls+'\n'+bulk+'\n}\n'+search+'\n'+intent
(out/'ModelCatalogSmokeHost.swift').write_text(source)
(out/'provenance.json').write_text(json.dumps({'source':'Mocca/ProviderViews.swift','sha256':hashlib.sha256(provider.encode()).hexdigest(),'scope':__doc__},indent=2))
# Reuse the existing standalone iOS app + XCUITest project generator.
generator=(root/'CandidateTests/prepare_settings_modal_ui.py').read_text()
generator=generator[generator.index('project_dir = OUT /'):]
bundle = 'com.mocca.qa.modelcatalog.' + hashlib.sha256(str(out).encode()).hexdigest()[:8]
generator=generator.replace('SettingsModalSmoke','ModelCatalogSmoke').replace('com.mocca.local.settings-modal-5032',bundle).replace('CandidateTests/ModelCatalogSmokeUITests.swift','CandidateTests/ModelCatalogInteractionUITests.swift')
import plistlib
exec(generator, {'OUT':out, 'ROOT':root,'plistlib':plistlib})
