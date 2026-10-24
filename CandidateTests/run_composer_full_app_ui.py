#!/usr/bin/python3
"""Build the complete app with its existing synthetic fixture gate, then test composer UI."""
from pathlib import Path
import argparse, subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'work/verification/composer-layout'
p=argparse.ArgumentParser();p.add_argument('--simulator',required=True);a=p.parse_args()
OUT.mkdir(parents=True,exist_ok=True)
# Reuse the repository's standalone UI runner generator; do not edit the app project.
s=(ROOT/'CandidateTests/make_entry_ui_project.py').read_text().replace('work/native-entry-qa/BottomEntryUI.xcodeproj','work/verification/composer-layout/AppUI.xcodeproj').replace('CandidateTests/NativeConversationEntryUITests.swift','CandidateTests/ComposerLayoutFullAppUITests.swift').replace('container:BottomEntryUI.xcodeproj','container:AppUI.xcodeproj')
exec(compile(s,'generate_composer_ui','exec'),{'__file__':str(ROOT/'CandidateTests/make_entry_ui_project.py')})
def run(cmd,log):
 with (OUT/log).open('w') as f:subprocess.run(cmd,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,check=True)
run(['xcodebuild','-project','Mocca.xcodeproj','-scheme','Mocca','-configuration','Debug','-sdk','iphonesimulator','-destination','platform=iOS Simulator,id='+a.simulator,'-derivedDataPath',str(OUT/'DerivedData'),'ONLY_ACTIVE_ARCH=YES','MOCCA_BUNDLE_IDENTIFIER=com.mocca.lab.streamheight5157','CODE_SIGNING_ALLOWED=NO','build'],'build-fixture.log')
subprocess.run(['xcrun','simctl','install',a.simulator,str(OUT/'DerivedData/Build/Products/Debug-iphonesimulator/Mocca.app')],check=True)
result=OUT/'full-app-ui.xcresult'
if result.exists():
 import datetime
 result=OUT/('full-app-ui-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'.xcresult')
run(['xcodebuild','-project',str(OUT/'AppUI.xcodeproj'),'-scheme','BottomEntryUI','-destination','platform=iOS Simulator,id='+a.simulator,'-derivedDataPath',str(OUT/'AppUITestDerivedData'),'-resultBundlePath',str(result),'CODE_SIGNING_ALLOWED=NO','test'],'ui-test.log')
print(result)
