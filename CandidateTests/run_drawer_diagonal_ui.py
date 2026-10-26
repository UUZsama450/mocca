#!/usr/bin/python3
"""Build the actual app only for a dedicated simulator and exercise drawer UI.

No phone, App Store, real provider or user conversation access.
Curved-path release is covered separately by extracted production-body tests;
XCTest here validates normal native hit routing and admitted diagonal swipes.
"""
from pathlib import Path
import argparse,subprocess,datetime
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'work/verification/drawer-diagonal-ui'
p=argparse.ArgumentParser();p.add_argument('--simulator',required=True);a=p.parse_args()
OUT.mkdir(parents=True,exist_ok=True)
tests=(ROOT/'CandidateTests/DrawerNativeHitRoutingUITests.swift').read_text().replace('com.uuzsama450.mocca.migration','com.mocca.lab.streamheight5157')
extra=r'''
    func testAdmittedDiagonalAndVerticalScroll() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.mocca.lab.streamheight5157")
        app.launchArguments = ["-previewNavigationStress", "-skipStartupPrompt", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let menu = app.buttons["打开聊天列表"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 25))
        let closedX = menu.frame.minX
        for down in [true, false] {
            let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: down ? 0.40 : 0.53))
            let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: down ? 0.53 : 0.40))
            left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
            wait { menu.frame.minX > app.frame.width * 0.65 }
            right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
            wait { abs(menu.frame.minX - closedX) < 3 }
        }
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.65))
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.35))
        lower.press(forDuration: 0.05, thenDragTo: upper)
        wait { abs(menu.frame.minX - closedX) < 3 }
        menu.tap()
        wait { menu.frame.minX > app.frame.width * 0.65 }
        lower.press(forDuration: 0.05, thenDragTo: upper)
        wait { menu.frame.minX > app.frame.width * 0.65 }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.45)).tap()
        wait { abs(menu.frame.minX - closedX) < 3 }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "diagonal-and-vertical-final"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
    }
'''
tests=tests.replace('    func testNativeInteractions()',extra+'\n    func testNativeInteractions()',1)
(OUT/'DrawerUITests.swift').write_text(tests)
s=(ROOT/'CandidateTests/make_entry_ui_project.py').read_text().replace('work/native-entry-qa/BottomEntryUI.xcodeproj','work/verification/drawer-diagonal-ui/DrawerUI.xcodeproj').replace('CandidateTests/NativeConversationEntryUITests.swift','work/verification/drawer-diagonal-ui/DrawerUITests.swift').replace('container:BottomEntryUI.xcodeproj','container:DrawerUI.xcodeproj').replace('com.mocca.local.native-entry-ui','com.mocca.local.drawer-diagonal-ui')
exec(compile(s,'generate_drawer_ui','exec'),{'__file__':str(ROOT/'CandidateTests/make_entry_ui_project.py')})
def run(cmd,log):
 with (OUT/log).open('w') as f:subprocess.run(cmd,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,check=True)
# Reuse the prior isolated simulator build cache; old signed phone/store packages
# and their source manifests are retained separately and are never overwritten.
derived=ROOT/'work/verification/composer-layout/DerivedData'
run(['xcodebuild','-jobs','2','-project','Mocca.xcodeproj','-scheme','Mocca','-configuration','Debug','-sdk','iphonesimulator','-destination','platform=iOS Simulator,id='+a.simulator,'-derivedDataPath',str(derived),'-clonedSourcePackagesDirPath','/tmp/mocca-document-packages','-disableAutomaticPackageResolution','-onlyUsePackageVersionsFromResolvedFile','-skipPackageUpdates','ONLY_ACTIVE_ARCH=YES','MOCCA_BUNDLE_IDENTIFIER=com.mocca.lab.streamheight5157','CODE_SIGNING_ALLOWED=NO','build'],'build.log')
subprocess.run(['xcrun','simctl','install',a.simulator,str(derived/'Build/Products/Debug-iphonesimulator/Mocca.app')],check=True)
result=OUT/('ui-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'.xcresult')
run(['xcodebuild','-jobs','2','-project',str(OUT/'DrawerUI.xcodeproj'),'-scheme','BottomEntryUI','-destination','platform=iOS Simulator,id='+a.simulator,'-derivedDataPath',str(OUT/'TestDerivedData'),'-resultBundlePath',str(result),'CODE_SIGNING_ALLOWED=NO','test'],'ui.log')
print(result)
