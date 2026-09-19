#!/usr/bin/env python3
"""Generate an isolated UI runner for the preinstalled simulator-only candidate."""
import pathlib
import plistlib

repo = pathlib.Path(__file__).resolve().parents[1]
root = repo / "work/native-entry-qa/BottomEntryUI.xcodeproj"
root.mkdir(parents=True, exist_ok=True)
objects = {}
def add(n, isa, **fields):
    identifier = f"BE4957000000000000{n:06X}"
    objects[identifier] = dict(isa=isa, **fields)
    return identifier
source = add(1, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(repo / "CandidateTests/NativeConversationEntryUITests.swift"), sourceTree="<absolute>")
product = add(2, "PBXFileReference", explicitFileType="wrapper.cfbundle", path="BottomEntryUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
buildfile = add(3, "PBXBuildFile", fileRef=source)
sources = add(4, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[buildfile], runOnlyForDeploymentPostprocessing=0)
frameworks = add(5, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
products = add(6, "PBXGroup", name="Products", children=[product], sourceTree="<group>")
group = add(7, "PBXGroup", children=[source, products], sourceTree="<group>")
settings = dict(SDKROOT="iphonesimulator", SUPPORTED_PLATFORMS="iphonesimulator", IPHONEOS_DEPLOYMENT_TARGET="18.0", SWIFT_VERSION="6.0", TARGETED_DEVICE_FAMILY="1", GENERATE_INFOPLIST_FILE="YES", PRODUCT_BUNDLE_IDENTIFIER="com.mocca.local.native-entry-ui", PRODUCT_NAME="$(TARGET_NAME)", CODE_SIGNING_ALLOWED="NO", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"], SWIFT_OPTIMIZATION_LEVEL="-Onone", ENABLE_TESTABILITY="YES")
config = add(8, "XCBuildConfiguration", name="Debug", buildSettings=settings)
configs = add(9, "XCConfigurationList", buildConfigurations=[config], defaultConfigurationName="Debug", defaultConfigurationIsVisible=0)
target = add(10, "PBXNativeTarget", name="BottomEntryUITests", productName="BottomEntryUITests", productType="com.apple.product-type.bundle.ui-testing", productReference=product, buildConfigurationList=configs, buildPhases=[sources, frameworks], buildRules=[], dependencies=[])
project = add(11, "PBXProject", attributes=dict(LastUpgradeCheck="2600"), buildConfigurationList=configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en", "Base"], mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[target])
(root / "project.pbxproj").write_bytes(plistlib.dumps(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject=project)))
scheme = root / "xcshareddata/xcschemes/BottomEntryUI.xcscheme"
scheme.parent.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="BottomEntryUITests.xctest" BlueprintName="BottomEntryUITests" ReferencedContainer="container:BottomEntryUI.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref}</TestableReference></Testables></TestAction>
</Scheme>''')
print(root)
