"""Add prompt unit/UI tests to an isolated simulator app; never installs on a phone."""
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
host = Path(sys.argv[1]).resolve()
if not host.exists():
    subprocess.run([sys.executable, str(root / 'CandidateTests/prepare_conversation_lookup_test_host.py'), str(host)], check=True)
project = host / 'Mocca.xcodeproj/project.pbxproj'
subprocess.run(['plutil', '-convert', 'xml1', '-o', str(host / 'project.xml'), str(project)], check=True)
data = plistlib.loads((host / 'project.xml').read_bytes())
objects = data['objects']
for value in objects.values():
    if value.get('isa') == 'XCBuildConfiguration':
        settings = value.get('buildSettings', {})
        if 'PRODUCT_BUNDLE_IDENTIFIER' in settings:
            settings['MOCCA_BUNDLE_IDENTIFIER'] = 'com.mocca.qa.searchprompt'
            settings['PRODUCT_BUNDLE_IDENTIFIER'] = settings['PRODUCT_BUNDLE_IDENTIFIER'].replace(
                'com.uuzsama450.mocca.migration', 'com.mocca.qa.searchprompt')

# Only the test host entry point is changed. All feature sources remain linked
# to the production files being validated.
app_dir = host / 'Mocca'
if app_dir.is_symlink():
    app_dir.unlink()
    app_dir.mkdir()
    for child in (root / 'Mocca').iterdir():
        if child.name != 'MoccaApp.swift':
            (app_dir / child.name).symlink_to(child, target_is_directory=child.is_dir())
entry = (root / 'Mocca/MoccaApp.swift').read_text()
entry = entry.replace('            RootView()', '''            Group {
                if ProcessInfo.processInfo.arguments.contains("-searchPromptUITest") {
                    SearchPromptFixtureRoot()
                } else {
                    RootView()
                }
            }''', 1)
entry = entry.replace('    private var shouldRunStartupServices: Bool {', '''    private var shouldRunStartupServices: Bool {
        if ProcessInfo.processInfo.arguments.contains("-searchPromptUITest") { return false }''', 1)
entry += r'''
private struct SearchPromptFixtureRoot: View {
    @State private var presented = false
    @State private var mcpPresented = false
    @State private var themesPresented = false
    @State private var actionsPresented = false
    @State private var profile = AssistantProfile(name: "Draft Assistant")
    var body: some View {
        VStack {
            Button("Open search settings") { presented = true }
            Button("Open assistant MCP") { mcpPresented = true }
            Button("Open themes") { themesPresented = true }
            Button("Open assistant actions") { actionsPresented = true }
        }
        .sheet(isPresented: $presented) { NavigationStack { SearchServiceSettingsView() } }
        .sheet(isPresented: $mcpPresented) {
            NavigationStack {
                VStack {
                    TextField("Draft name", text: $profile.name).accessibilityIdentifier("qa.assistantName")
                    AssistantMCPServersView(profile: $profile)
                }
                .navigationTitle("Assistant MCP")
            }
        }
        .sheet(isPresented: $themesPresented) {
            NavigationStack { ThemeSettingsTestView().toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close themes") { themesPresented = false } }
            } }
        }
        .sheet(isPresented: $actionsPresented) {
            NavigationStack { AssistantActionsTestView().toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close actions") { actionsPresented = false } }
            } }
        }
    }
}
'''
settings = app_dir / 'SettingsViews.swift'
if settings.is_symlink():
    settings.unlink()
settings.write_text((root / 'Mocca/SettingsViews.swift').read_text() + '''
struct ThemeSettingsTestView: View { var body: some View { ThemePreferencesPage() } }
struct AssistantActionsTestView: View { var body: some View { AssistantMessageActionsPreferencesPage() } }
''')
(app_dir / 'MoccaApp.swift').write_text(entry)
(host / 'Slice1UITests/Slice1UITests.swift').write_text((root / 'CandidateTests/SearchToolPromptTests.swift').read_text())
if any(v.get('name') == 'SearchToolPromptUITests' and v.get('isa') == 'PBXNativeTarget' for v in objects.values()):
    print(host)
    sys.exit(0)
counter = 0

def add(isa, **fields):
    global counter
    counter += 1
    key = f'C5243B000000000000{counter:06X}'
    assert key not in objects
    objects[key] = dict(isa=isa, **fields)
    return key

app = next(k for k, v in objects.items() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Mocca')
unit = next(k for k, v in objects.items() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Slice1UITests')
ref = add('PBXFileReference', lastKnownFileType='sourcecode.swift', path=str(root / 'CandidateTests/SearchToolPromptUITests.swift'), sourceTree='<absolute>')
build = add('PBXBuildFile', fileRef=ref)
phase = add('PBXSourcesBuildPhase', files=[build], buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
product = add('PBXFileReference', explicitFileType='wrapper.cfbundle', path='SearchToolPromptUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
config = add('XCBuildConfiguration', name='Debug', buildSettings={
    'PRODUCT_BUNDLE_IDENTIFIER': 'com.mocca.qa.searchprompt.uitests', 'PRODUCT_NAME': '$(TARGET_NAME)',
    'SDKROOT': 'iphonesimulator', 'SUPPORTED_PLATFORMS': 'iphonesimulator', 'IPHONEOS_DEPLOYMENT_TARGET': '18.0',
    'SWIFT_VERSION': '5.0', 'GENERATE_INFOPLIST_FILE': 'YES', 'TEST_TARGET_NAME': 'Mocca',
    'TARGETED_DEVICE_FAMILY': '1', 'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
})
configs = add('XCConfigurationList', buildConfigurations=[config], defaultConfigurationName='Debug', defaultConfigurationIsVisible=0)
dependency = add('PBXTargetDependency', target=app)
ui = add('PBXNativeTarget', name='SearchToolPromptUITests', productName='SearchToolPromptUITests',
         productType='com.apple.product-type.bundle.ui-testing', productReference=product,
         buildConfigurationList=configs, buildPhases=[phase], buildRules=[], dependencies=[dependency])
proj = objects[data['rootObject']]
proj['targets'].append(ui)
objects[proj['mainGroup']]['children'].append(ref)
objects[proj['productRefGroup']]['children'].append(product)
project.write_bytes(plistlib.dumps(data))

def reference(key, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:Mocca.xcodeproj"/>'

entries = ''.join(f'<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference(k, n)}</BuildActionEntry>'
                  for k, n in [(app, 'Mocca.app'), (unit, 'Slice1UITests.xctest'), (ui, 'SearchToolPromptUITests.xctest')])
tests = ''.join(f'<TestableReference skipped="NO" parallelizable="NO">{reference(k, n)}</TestableReference>'
                for k, n in [(unit, 'Slice1UITests.xctest'), (ui, 'SearchToolPromptUITests.xctest')])
(host / 'Mocca.xcodeproj/xcshareddata/xcschemes/SearchPromptQA.xcscheme').write_text(
    f'<Scheme LastUpgradeVersion="2630" version="1.3"><BuildAction><BuildActionEntries>{entries}</BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn"><Testables>{tests}</Testables></TestAction></Scheme>')
print(host)
