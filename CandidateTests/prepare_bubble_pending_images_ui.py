#!/usr/bin/python3
"""Generate/build only an external-app XCTest runner. Never boots a simulator."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess

REPO = pathlib.Path(__file__).resolve().parents[1]
ROOT = REPO / "work/preview-verification/ui"
ROOT.mkdir(parents=True, exist_ok=True)
SOURCE = REPO / "CandidateTests/BubbleAndPendingImagesUITests.swift"
PROJECT = ROOT / "ShortChatP01UI.xcodeproj"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true", help="compile UI runner for generic simulator; no test run")
    args = parser.parse_args()
    PROJECT.mkdir(exist_ok=True)
    objects = {}
    def add(number, isa, **fields):
        identifier = f"NR5075000000000000{number:06X}"
        # Xcode accepts only hexadecimal object identifiers.
        identifier = identifier.replace("NR", "AB")
        objects[identifier] = dict(isa=isa, **fields)
        return identifier
    source = add(1, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(SOURCE), sourceTree="<absolute>")
    product = add(2, "PBXFileReference", explicitFileType="wrapper.cfbundle", path="ShortChatP01UITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    buildfile = add(3, "PBXBuildFile", fileRef=source)
    sources = add(4, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[buildfile], runOnlyForDeploymentPostprocessing=0)
    frameworks = add(5, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    products = add(6, "PBXGroup", name="Products", children=[product], sourceTree="<group>")
    group = add(7, "PBXGroup", children=[source, products], sourceTree="<group>")
    settings = dict(SDKROOT="iphonesimulator", SUPPORTED_PLATFORMS="iphonesimulator", IPHONEOS_DEPLOYMENT_TARGET="18.0", SWIFT_VERSION="6.0", TARGETED_DEVICE_FAMILY="1", GENERATE_INFOPLIST_FILE="YES", PRODUCT_BUNDLE_IDENTIFIER="com.mocca.local.native-chat-short-chat-p01-5077-ui", PRODUCT_NAME="$(TARGET_NAME)", CODE_SIGNING_ALLOWED="NO", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"], SWIFT_OPTIMIZATION_LEVEL="-Onone", ENABLE_TESTABILITY="YES")
    config = add(8, "XCBuildConfiguration", name="Debug", buildSettings=settings)
    configs = add(9, "XCConfigurationList", buildConfigurations=[config], defaultConfigurationName="Debug", defaultConfigurationIsVisible=0)
    target = add(10, "PBXNativeTarget", name="ShortChatP01UITests", productName="ShortChatP01UITests", productType="com.apple.product-type.bundle.ui-testing", productReference=product, buildConfigurationList=configs, buildPhases=[sources, frameworks], buildRules=[], dependencies=[])
    project = add(11, "PBXProject", attributes=dict(LastUpgradeCheck="2600"), buildConfigurationList=configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en", "Base"], mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[target])
    (PROJECT / "project.pbxproj").write_bytes(plistlib.dumps(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject=project)))
    scheme = PROJECT / "xcshareddata/xcschemes/ShortChatP01UI.xcscheme"
    scheme.parent.mkdir(parents=True, exist_ok=True)
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="ShortChatP01UITests.xctest" BlueprintName="ShortChatP01UITests" ReferencedContainer="container:ShortChatP01UI.xcodeproj"/>'
    scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref}</TestableReference></Testables></TestAction>
</Scheme>''')
    result = {"project": str(PROJECT), "runner_only": True, "simulator_started": False,
              "ui_source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
              "source_sha256": {name: hashlib.sha256(SOURCE.read_bytes()).hexdigest()
                                for name in ["ShortChatUITests.swift"]}}
    if args.build:
        command = ["nice", "-n", "10", "xcodebuild", "build-for-testing", "-jobs", "2", "-project", str(PROJECT), "-scheme", "ShortChatP01UI", "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(ROOT/'RunnerDD'), "CODE_SIGNING_ALLOWED=NO"]
        with (ROOT / "runner-build.log").open("w") as log:
            build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        result["build_returncode"] = build.returncode
    (ROOT / "prepare-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    raise SystemExit(result.get("build_returncode", 0))

if __name__ == "__main__":
    main()
