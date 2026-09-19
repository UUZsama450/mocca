"""Exercise extracted shipping SwiftUI views in a disposable simulator. Test hooks only schedule actions and record snapshots."""
from pathlib import Path
import subprocess,json,plistlib,sys,shutil
from check_drawer_close_driver_reuse import extract
root=Path(__file__).resolve().parents[1];out=root/'work/verification/interaction-polish'
source=(root/'Mocca/RootView.swift').read_text()
names=['MessageReactionPickerPresentation','MessageReactionPickerOverlay','MessageReactionPickerBar','MessageReactionOptions']
parts=[extract(source,rf'^private (?:struct|enum) {name}\b')[0] for name in names]
parts[1]=parts[1].replace('.onAppear {','.onAppear {\n            Probe.log("picker appear"); Probe.dismiss = { Probe.log("dismiss request"); dismiss() }; Probe.more = { dismiss(after: onMore) }',1)
parts[1]=parts[1].replace('withAnimation(animation) { isVisible = true }', 'withAnimation(animation) { isVisible = true }\n            if !Probe.capturedEntrance {\n                Probe.capturedEntrance = true\n                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { Probe.capture("entrance-060ms") }\n                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { Probe.capture("entrance-160ms") }\n            }\n            if Probe.dismissNextAppearance {\n                Probe.dismissNextAppearance = false\n                DispatchQueue.main.async { dismiss(); dismiss() }\n            }')
# The accessibility environment is read-only; supply only that input in the extracted test view.
parts[1]=parts[1].replace('@Environment(\\.accessibilityReduceMotion) private var reduceMotion', 'private let reduceMotion = ProcessInfo.processInfo.arguments.contains("-reduce-motion")')
path=out/'reaction-runtime.swift';path.write_text('import UIKit\nimport SwiftUI\nimport Observation\n'+'\n'.join(parts)+'\n'+(root/'CandidateTests/ReactionPickerRuntimeHarness.swift').read_text())
app=out/'ReactionRuntime.app';app.mkdir(exist_ok=True); bundle='com.uuzsama450.mocca.reaction5028.runtime'
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle,'CFBundleExecutable':'Harness','CFBundleName':'Reaction Runtime','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','LSRequiresIPhoneOS':True,'MinimumOSVersion':'17.0','UILaunchScreen':{},'UIDeviceFamily':[1]}))
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
with (out/'reaction-runtime-build.log').open('w') as log:
 subprocess.run(['xcrun','swiftc','-parse-as-library','-sdk',sdk,'-target','x86_64-apple-ios17.0-simulator','-swift-version','6',str(path),'-o',str(app/'Harness')],stdout=log,stderr=subprocess.STDOUT,check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],capture_output=True,check=True)
if '--build-only' in sys.argv: print('Runtime harness compiled');sys.exit(0)
sim=json.loads((out/'simulator.json').read_text())['udid']
subprocess.run(['xcrun','simctl','install',sim,str(app)],check=True)
for label,args in [('normal',[]),('reduced',['-reduce-motion'])]:
 with (out/f'reaction-{label}.log').open('w') as log:
  subprocess.run(['xcrun','simctl','launch','--terminate-running-process','--console',sim,bundle,*args],stdout=log,stderr=subprocess.STDOUT,check=True)
 data=Path(subprocess.check_output(['xcrun','simctl','get_app_container',sim,bundle,'data'],text=True).strip())/'Documents'
 dest=out/f'reaction-{label}';shutil.copytree(data,dest,dirs_exist_ok=True)
 report=json.loads((dest/'report.json').read_text());assert not report['failures'],report; print(label,report,flush=True)
