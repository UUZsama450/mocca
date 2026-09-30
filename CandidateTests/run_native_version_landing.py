from pathlib import Path
import subprocess, json, plistlib, platform, hashlib, sys
root=Path(__file__).resolve().parents[1];out=root/'work/version-native-landing/NativeHarness';out.mkdir(parents=True,exist_ok=True)
source=root/'Mocca/NativeChatTranscript.swift';harness=root/'CandidateTests/NativeVersionLandingHarness.swift'
swift=out/'Harness.swift';swift.write_text(source.read_text()+'\n'+harness.read_text())
app=out/'NativeVersion.app';app.mkdir(exist_ok=True);bundle='com.mocca.fixture.native-version-landing'
(app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle,CFBundleExecutable='NativeVersion',CFBundleName='NativeVersion',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='26.0',UIDeviceFamily=[1],UILaunchScreen={})))
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
cmd=['xcrun','swiftc','-g','-D','DEBUG','-parse-as-library','-swift-version','6','-target',f'{platform.machine()}-apple-ios26.0-simulator','-sdk',sdk,str(swift),'-o',str(app/'NativeVersion')]
r=subprocess.run(cmd,capture_output=True,text=True);(out/'build.log').write_text(r.stdout+r.stderr);r.check_returncode()
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
sim=sys.argv[1];subprocess.run(['xcrun','simctl','install',sim,str(app)],check=True)
r=subprocess.run(['xcrun','simctl','launch','--console-pty','--terminate-running-process',sim,bundle],capture_output=True,text=True,timeout=100);(out/'run.log').write_text(r.stdout+r.stderr)
container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',sim,bundle,'data'],text=True).strip())
result=json.loads((container/'Documents/native-version-result.json').read_text());result['sourceSHA256']=hashlib.sha256(source.read_bytes()).hexdigest()
(out/'result.json').write_text(json.dumps(result,indent=2));print({k:v for k,v in result.items() if k!='cases'})
assert result['status']=='PASS', result['failures']
