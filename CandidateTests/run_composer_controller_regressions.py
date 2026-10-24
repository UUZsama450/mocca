#!/usr/bin/python3
"""Run existing 13 real UIKit controller/reuse regressions against GitHub and candidate."""
from pathlib import Path
import hashlib, json, platform, plistlib, subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'work/verification/composer-layout/controller'; OUT.mkdir(parents=True,exist_ok=True)
sim=sys.argv[1]; base='9a29bb1b033df824ffecb0f4766294600992b448'
current=(ROOT/'Mocca/NativeChatTranscript.swift').read_text()
baseline=subprocess.check_output(['git','show',base+':Mocca/NativeChatTranscript.swift'],cwd=ROOT,text=True)
fixture=(ROOT/'CandidateTests/NativeRowConfigurationHarness.swift').read_text()
stubs='''
@MainActor enum NativeReadingFixtures { static let requestedName: String? = nil }
@MainActor protocol TextSelectionAutoscrollHost: AnyObject { func selectionAutoscrollDidBegin(); func selectionAutoscrollDidEnd() }
@MainActor enum DrawerTextSelectionInteractionGate { static func cancelAutoscroll(in view: UIView) {} }
@MainActor enum MessageTextViewportDrawing { static func refreshAfterLayout(in view: UIView, visibleOnly: Bool) {} }
'''
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
reports={}
for label,source in [('baseline',baseline),('candidate',current)]:
 marker='        cell.configuredKey = key; cell.configuredPublication = publication\n'
 assert source.count(marker)==1
 tested=source.replace(marker,marker+'        RowConfigurationProbe.record(cell: cell, key: key, publication: publication)\n')
 reuse='    override func prepareForReuse() {\n'; assert tested.count(reuse)==1
 tested=tested.replace(reuse,reuse+'        let probeOldHost = measurementHostID\n        defer { RowConfigurationProbe.reused(old: probeOldHost, new: measurementHostID) }\n')
 swift=OUT/(label+'.swift');swift.write_text(tested+'\n'+stubs+'\n'+fixture)
 app=OUT/(label+'.app');app.mkdir(exist_ok=True);bundle='com.mocca.fixture.composer-controller.'+label
 (app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle,CFBundleExecutable='Probe',CFBundleName='Controller Probe',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='26.0',UIDeviceFamily=[1],UILaunchScreen={})))
 cmd=['xcrun','swiftc','-O','-D','DEBUG','-parse-as-library','-swift-version','6','-target',platform.machine()+'-apple-ios26.0-simulator','-sdk',sdk,str(swift),str(ROOT/'Mocca/ComposerNativeTextInput.swift'),'-o',str(app/'Probe')]
 with (OUT/(label+'-compile.log')).open('w') as f:subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,check=True)
 subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
 subprocess.run(['xcrun','simctl','install',sim,str(app)],check=True,capture_output=True)
 container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',sim,bundle,'data'],text=True).strip())
 result=container/'Documents/row-configuration-result.json'
 if result.exists():result.unlink()
 run=subprocess.run(['xcrun','simctl','launch','--console-pty','--terminate-running-process',sim,bundle,'-fullMotionLean'],capture_output=True,text=True,timeout=90)
 (OUT/(label+'-run.log')).write_text(run.stdout+run.stderr)
 report=json.loads(result.read_text());report['sourceSHA256']=hashlib.sha256(source.encode()).hexdigest()
 (OUT/(label+'-result.json')).write_text(json.dumps(report,indent=2)+'\n')
 print(label,report['status'],report['checks'],report['failures'],flush=True)
 assert run.returncode==0 and report['status']=='PASS'
 reports[label]=report
for old,new in zip(reports['baseline']['cases'],reports['candidate']['cases']):
 assert old['name']==new['name'] and old['rows']==new['rows']
 assert old['visible']==new['visible'],old['name']
 assert abs(old['offset']-new['offset'])<1,old['name']
 assert new['duplicateConfigurations']==0,new['name']
(OUT/'result.json').write_text(json.dumps(dict(status='PASS',baseline=base,reports=reports),indent=2)+'\n')
print('PASS: baseline/candidate visible frames, measured heights, row order, offsets, and duplicate configuration checks')
