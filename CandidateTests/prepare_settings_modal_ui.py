#!/usr/bin/env python3
"""Build files for an isolated modal smoke host; never builds the Mocca app.

Extracts the actual dismissal observer, ProviderEditor alert/dismiss modifiers,
and save/discard/dirty methods. The visible form, configuration, persistence,
avatar store and nested editor are local fixtures. No network or user data.
"""
from pathlib import Path
import hashlib
import json
import plistlib
from check_drawer_close_driver_reuse import extract, method

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/settings-polish-5032/modal-ui"
OUT.mkdir(parents=True, exist_ok=True)
provider = (ROOT / "Mocca/ProviderViews.swift").read_text()
observer, observer_lines = extract(provider, r"^private struct ProviderDraftDismissObserver:")
editor, editor_lines = extract(provider, r"^struct ProviderEditorView:")
modifiers = editor[editor.index("        .interactiveDismissDisabled(hasUnsavedChanges)"):editor.index("\n    private var configurationPage:")]
helpers = "\n".join(method(editor, name)[0] for name in ["save", "requestDismiss", "discardAndDismiss", "cleanUpAvatarIfNeeded"])
helpers += "\n" + "\n".join(extract(editor, r"^    private var " + name + r":")[0] for name in ["hasUnsavedChanges", "canSave"])
template = (ROOT / "CandidateTests/SettingsModalSmokeHost.swift").read_text()
host = template.replace("// EXTRACTED_OBSERVER", observer).replace("// EXTRACTED_EDITOR_MODIFIERS_AND_BODY_END", modifiers).replace("// EXTRACTED_EDITOR_HELPERS", helpers)
(OUT / "SettingsModalSmokeHost.swift").write_text(host)
(OUT / "provenance.json").write_text(json.dumps({"source": "Mocca/ProviderViews.swift", "sha256": hashlib.sha256(provider.encode()).hexdigest(), "observer_lines": observer_lines, "editor_lines": editor_lines, "limits": __doc__}, indent=2) + "\n")

project_dir = OUT / "SettingsModalSmoke.xcodeproj"
project_dir.mkdir(exist_ok=True)
objects = {}
counter = 0
def add(isa, **fields):
    global counter
    counter += 1
    key = f"5032AA000000000000{counter:06X}"
    objects[key] = dict(isa=isa, **fields)
    return key

base_settings = dict(SDKROOT="iphonesimulator", SUPPORTED_PLATFORMS="iphonesimulator", IPHONEOS_DEPLOYMENT_TARGET="18.0", SWIFT_VERSION="6.0", TARGETED_DEVICE_FAMILY="1", GENERATE_INFOPLIST_FILE="YES", PRODUCT_NAME="$(TARGET_NAME)", CODE_SIGNING_ALLOWED="NO", SWIFT_OPTIMIZATION_LEVEL="-Onone", ENABLE_TESTABILITY="YES", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"])
def configs(extra):
    config = add("XCBuildConfiguration", name="Debug", buildSettings={**base_settings, **extra})
    return add("XCConfigurationList", buildConfigurations=[config], defaultConfigurationName="Debug", defaultConfigurationIsVisible=0)
files = []
products = []
targets = []
refs = []
for name, source_path, bundle, product_type, product_path, extra in [
    ("SettingsModalSmoke", OUT / "SettingsModalSmokeHost.swift", "com.mocca.local.settings-modal-5032", "com.apple.product-type.application", "SettingsModalSmoke.app", {"INFOPLIST_KEY_UILaunchScreen_Generation": "YES", "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES"}),
    ("SettingsModalSmokeUITests", ROOT / "CandidateTests/SettingsModalSmokeUITests.swift", "com.mocca.local.settings-modal-5032.tests", "com.apple.product-type.bundle.ui-testing", "SettingsModalSmokeUITests.xctest", {"TEST_TARGET_NAME": "SettingsModalSmoke"}),
]:
    file = add("PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(source_path), sourceTree="<absolute>")
    files.append(file)
    product = add("PBXFileReference", explicitFileType="wrapper.application" if product_path.endswith(".app") else "wrapper.cfbundle", path=product_path, sourceTree="BUILT_PRODUCTS_DIR")
    products.append(product)
    buildfile = add("PBXBuildFile", fileRef=file)
    phase = add("PBXSourcesBuildPhase", buildActionMask=2147483647, files=[buildfile], runOnlyForDeploymentPostprocessing=0)
    target = add("PBXNativeTarget", name=name, productName=name, productType=product_type, productReference=product, buildConfigurationList=configs({"PRODUCT_BUNDLE_IDENTIFIER": bundle, **extra}), buildPhases=[phase], buildRules=[], dependencies=[])
    targets.append(target)
    refs.append(f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product_path}" BlueprintName="{name}" ReferencedContainer="container:SettingsModalSmoke.xcodeproj"/>')
product_group = add("PBXGroup", name="Products", children=products, sourceTree="<group>")
main_group = add("PBXGroup", children=files + [product_group], sourceTree="<group>")
project = add("PBXProject", attributes={"LastUpgradeCheck": "2600", "TargetAttributes": {targets[1]: {"TestTargetID": targets[0]}}}, buildConfigurationList=configs({}), compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en", "Base"], mainGroup=main_group, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=targets)
(project_dir / "project.pbxproj").write_bytes(plistlib.dumps(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject=project)))
scheme_dir = project_dir / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / "SettingsModalSmoke.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{refs[0]}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{refs[1]}</BuildActionEntry>
</BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{refs[1]}</TestableReference></Testables></TestAction></Scheme>''')
print(project_dir)
