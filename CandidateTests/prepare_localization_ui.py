from pathlib import Path
import subprocess,plistlib,shutil,sys
ROOT=Path(__file__).resolve().parents[1];OUT=Path(sys.argv[1]).resolve();OUT.mkdir(parents=True,exist_ok=True)
# Production sources are referenced; QA entry and conditional fake balance transport are copied.
for folder in ['Mocca','GenerationActivityExtension']:
 dest=OUT/folder;dest.mkdir(exist_ok=True)
 for p in (ROOT/folder).iterdir():
  target=dest/p.name
  if p.name=='ProviderViews.swift':
   if target.is_symlink():target.unlink()
   provider_source=p.read_text()
   needle='try await AIChatService.fetchBalance(for: $0)'
   assert provider_source.count(needle)==1
   provider_source=provider_source.replace(needle,'''if ProcessInfo.processInfo.arguments.contains("-showProviderBalances") {
                try await Task.sleep(for: .milliseconds(40))
                return .credits(remaining: "12.34", total: "20")
            }
            return try await AIChatService.fetchBalance(for: $0)''')
   target.write_text(provider_source)
   continue
  if target.exists() or target.is_symlink():continue
  if p.name in ['Assets.xcassets','AppIcon.icon']:shutil.copytree(p,target)
  elif p.name=='MoccaApp.swift':continue
  else:target.symlink_to(p)
(OUT/'Mocca/MoccaApp.swift').write_text('''import SwiftUI
@main struct LocalizationQAApp: App {
 @State private var model: AppModel
 @State private var draft = ""
 init() {
  let model = AppModel()
  if ProcessInfo.processInfo.arguments.contains("-showProviderBalances") {
   model.providers = [true,false].enumerated().map { index,enabled in
    ProviderConfiguration(id:UUID(uuidString:index==0 ? "00000000-0000-0000-0000-000000000001" : "00000000-0000-0000-0000-000000000002")!,enabled:true,name:enabled ? "Example Provider With A Long Name" : "Balance Disabled",type:.openAI,apiKey:"fixture-not-a-secret",baseURL:"https://example.invalid",chatPath:"/chat/completions",models:[ModelConfiguration(id:"gpt-qa-\\(index)",displayName:"QA Chat Model \\(index)")],balanceEnabled:enabled)
   }
  }
  _model=State(initialValue:model)
  if ProcessInfo.processInfo.arguments.contains("-resetLanguageForUITest") {
   UserDefaults.standard.removeObject(forKey: AppLocalization.preferenceKey)
  }
 }
 var body:some Scene {WindowGroup {
  Group {
   if ProcessInfo.processInfo.arguments.contains("-showProviderBalances") {
    ModelSelectorView(onSelect:{_ in})
   } else if ProcessInfo.processInfo.arguments.contains("-showProfile") {
    UserProfileView()
   } else if ProcessInfo.processInfo.arguments.contains("-showSponsor") {
    NavigationStack { SponsorPage() }
   } else {
  VStack(spacing:0) {
   HStack {
    TextField("QA draft",text:$draft).accessibilityIdentifier("localization.testDraft")
    Button("Seed draft") {draft="Keep this draft"}.accessibilityIdentifier("localization.seedDraft")
   }.padding()
   SettingsView()
  }
   }
  }.environment(model).environment(\\.locale,AppLocalization.shared.locale)
 }}
}
''')
project=OUT/'Mocca.xcodeproj';project.mkdir(exist_ok=True)
subprocess.run(['plutil','-convert','xml1','-o',str(OUT/'project.xml'),str(ROOT/'Mocca.xcodeproj/project.pbxproj')],check=True)
p=plistlib.loads((OUT/'project.xml').read_bytes());o=p['objects'];counter=0
for v in o.values():
 if v.get('isa')=='XCBuildConfiguration':
  b=v.get('buildSettings',{});bid=b.get('PRODUCT_BUNDLE_IDENTIFIER')
  if bid:b['PRODUCT_BUNDLE_IDENTIFIER']=bid.replace('com.uuzsama450.mocca.migration','com.mocca.localizationqa')
  b['CODE_SIGNING_ALLOWED']='NO'
def add(isa,**fields):
 global counter
 counter+=1;k=f'C5054A000000000000{counter:06X}';o[k]=dict(isa=isa,**fields);return k
ref=add('PBXFileReference',lastKnownFileType='sourcecode.swift',path=str(ROOT/'CandidateTests/LocalizationUITests.swift'),sourceTree='<absolute>')
build=add('PBXBuildFile',fileRef=ref)
phase=add('PBXSourcesBuildPhase',files=[build],buildActionMask=2147483647,runOnlyForDeploymentPostprocessing=0)
product=add('PBXFileReference',explicitFileType='wrapper.cfbundle',path='LocalizationUITests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
config=add('XCBuildConfiguration',name='Debug',buildSettings={'PRODUCT_BUNDLE_IDENTIFIER':'com.mocca.localizationqa.uitests','PRODUCT_NAME':'$(TARGET_NAME)','SDKROOT':'iphonesimulator','SUPPORTED_PLATFORMS':'iphonesimulator','IPHONEOS_DEPLOYMENT_TARGET':'18.0','SWIFT_VERSION':'5.0','GENERATE_INFOPLIST_FILE':'YES','CODE_SIGNING_ALLOWED':'NO','TEST_TARGET_NAME':'Mocca','TARGETED_DEVICE_FAMILY':'1','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks']})
configs=add('XCConfigurationList',buildConfigurations=[config],defaultConfigurationName='Debug',defaultConfigurationIsVisible=0)
app=next(k for k,v in o.items() if v.get('isa')=='PBXNativeTarget' and v.get('name')=='Mocca')
dep=add('PBXTargetDependency',target=app)
target=add('PBXNativeTarget',name='LocalizationUITests',productName='LocalizationUITests',productType='com.apple.product-type.bundle.ui-testing',productReference=product,buildConfigurationList=configs,buildPhases=[phase],buildRules=[],dependencies=[dep])
unitref=add('PBXFileReference',lastKnownFileType='sourcecode.swift',path=str(ROOT/'CandidateTests/LocalizationIsolationTests.swift'),sourceTree='<absolute>')
unitbuild=add('PBXBuildFile',fileRef=unitref)
unitphase=add('PBXSourcesBuildPhase',files=[unitbuild],buildActionMask=2147483647,runOnlyForDeploymentPostprocessing=0)
unitproduct=add('PBXFileReference',explicitFileType='wrapper.cfbundle',path='LocalizationIsolationTests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
unitsettings=dict(o[config]['buildSettings'])
unitsettings.update(PRODUCT_BUNDLE_IDENTIFIER='com.mocca.localizationqa.isolation',TEST_HOST='$(BUILT_PRODUCTS_DIR)/Mocca.app/Mocca',BUNDLE_LOADER='$(TEST_HOST)')
unitconfig=add('XCBuildConfiguration',name='Debug',buildSettings=unitsettings)
unitconfigs=add('XCConfigurationList',buildConfigurations=[unitconfig],defaultConfigurationName='Debug',defaultConfigurationIsVisible=0)
unitdep=add('PBXTargetDependency',target=app)
unittarget=add('PBXNativeTarget',name='LocalizationIsolationTests',productName='LocalizationIsolationTests',productType='com.apple.product-type.bundle.unit-test',productReference=unitproduct,buildConfigurationList=unitconfigs,buildPhases=[unitphase],buildRules=[],dependencies=[unitdep])
proj=o[p['rootObject']];proj['targets'] += [target,unittarget]

o[proj['mainGroup']]['children'] += [ref,unitref]
o[proj['productRefGroup']]['children'] += [product,unitproduct]
(project/'project.pbxproj').write_bytes(plistlib.dumps(p))
sd=project/'xcshareddata/xcschemes';sd.mkdir(parents=True,exist_ok=True)
refxml=lambda i,n:f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{i}" BuildableName="{n}" BlueprintName="{n.split(".")[0]}" ReferencedContainer="container:Mocca.xcodeproj"/>'
(sd/'LocalizationQA.xcscheme').write_text(f'''<Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{refxml(app,'Mocca.app')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{refxml(target,'LocalizationUITests.xctest')}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{refxml(unittarget,'LocalizationIsolationTests.xctest')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn"><Testables><TestableReference skipped="NO">{refxml(target,'LocalizationUITests.xctest')}</TestableReference><TestableReference skipped="NO">{refxml(unittarget,'LocalizationIsolationTests.xctest')}</TestableReference></Testables></TestAction></Scheme>''')
print(project)
