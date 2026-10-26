"""Real UIKit controller regressions with snapshot copy/mutation/adoption checks.

Synthetic data in a separate simulator application. No production data access.
"""
from pathlib import Path
import hashlib, json, platform, plistlib, subprocess, sys
root = Path(__file__).resolve().parents[1]
out = root / 'work/verification/row-snapshot'
out.mkdir(parents=True, exist_ok=True)
sim = sys.argv[1]
source = (root/'Mocca/NativeChatTranscript.swift').read_text()
fixture = (root/'CandidateTests/NativeRowConfigurationHarness.swift').read_text()
fixture = fixture.replace('    func run() async {', '    func run() async {\n        await rowSnapshotChecks()')
marker = '        cell.configuredKey = key; cell.configuredPublication = publication\n'
assert source.count(marker) == 1
tested = source.replace(marker, marker+'        RowConfigurationProbe.record(cell: cell, key: key, publication: publication)\n')
reuse = '    override func prepareForReuse() {\n'
tested = tested.replace(reuse, reuse+'        let probeOldHost = measurementHostID\n        defer { RowConfigurationProbe.reused(old: probeOldHost, new: measurementHostID) }\n')
stubs = '''
@MainActor enum NativeReadingFixtures { static let requestedName: String? = nil }
@MainActor protocol TextSelectionAutoscrollHost: AnyObject { func selectionAutoscrollDidBegin(); func selectionAutoscrollDidEnd() }
@MainActor enum DrawerTextSelectionInteractionGate { static func cancelAutoscroll(in view: UIView) {} }
@MainActor enum MessageTextViewportDrawing { static func refreshAfterLayout(in view: UIView, visibleOnly: Bool) {} }
'''
swift = out/'Combined.swift'
swift.write_text(tested+'\n'+stubs+'\n'+fixture+'\n'+(root/'CandidateTests/NativeRowSnapshotChecks.swift').read_text())
app = out/'SnapshotChecks.app'; app.mkdir(exist_ok=True)
bundle = 'com.mocca.fixture.row-snapshot-20261026'
(app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle, CFBundleExecutable='Probe', CFBundleName='Snapshot Checks', CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1.0', MinimumOSVersion='26.0', UIDeviceFamily=[1], UILaunchScreen={})))
sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
cmd = ['xcrun','swiftc','-O','-D','DEBUG','-parse-as-library','-swift-version','6','-target',platform.machine()+'-apple-ios26.0-simulator','-sdk',sdk,str(swift),str(root/'Mocca/ComposerNativeTextInput.swift'),'-o',str(app/'Probe')]
with (out/'compile.log').open('w') as log: subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
subprocess.run(['xcrun','simctl','install',sim,str(app)],check=True,capture_output=True)
container = Path(subprocess.check_output(['xcrun','simctl','get_app_container',sim,bundle,'data'],text=True).strip())
run = subprocess.run(['xcrun','simctl','launch','--console-pty','--terminate-running-process',sim,bundle,'-fullMotionLean'],capture_output=True,text=True,timeout=120)
(out/'run.log').write_text(run.stdout+run.stderr)
report = json.loads((container/'Documents/row-configuration-result.json').read_text())
report['sourceSHA256'] = hashlib.sha256(source.encode()).hexdigest()
(out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'status':report['status'],'checks':report['checks'],'cases':len(report['cases']),'failures':report['failures']}))
assert run.returncode == 0 and report['status'] == 'PASS'
