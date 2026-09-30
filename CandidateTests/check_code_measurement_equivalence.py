#!/usr/bin/python3
"""Compare baseline/candidate production code measurement in an isolated iOS simulator."""
from pathlib import Path
import argparse,subprocess,hashlib,json,platform,plistlib

parser=argparse.ArgumentParser();parser.add_argument('output',type=Path);parser.add_argument('--simulator',required=True);parser.add_argument('--baseline-ref',default='1d3d650');parser.add_argument('--extended-only',action='store_true');args=parser.parse_args()
root=Path(__file__).resolve().parents[1];out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
path='Mocca/MessageMarkdownView.swift';current=(root/path).read_text();old=subprocess.check_output(['git','show',args.baseline_ref+':'+path],cwd=root,text=True)
def block(s,marker):
 start=s.index(marker);end=s.index('{',start)+1;depth=1
 while depth:
  depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
cache=block(current,'@MainActor\nprivate final class UnifiedTextMeasurementCache')
assert cache==block(old,'@MainActor\nprivate final class UnifiedTextMeasurementCache')
oldmethod=block(old,'    private func measuredCodeSize(').replace('private func','func',1)
newmethod=block(current,'    private func measuredCodeSize(').replace('private func','func',1)
helper=block(current,'    private static func measuredCodeBounds(')
swift='import UIKit\n'+cache+'\n@MainActor struct Baseline {\n'+oldmethod+'\n}\n@MainActor struct Candidate {\n'+newmethod+'\n'+helper+'\n}\n'+(root/'CandidateTests/CodeMeasurementEquivalence.swift').read_text()
source=out/'Extracted.swift';source.write_text(swift)
app=out/'CodeMeasurement.app';app.mkdir(exist_ok=True);bundle='com.mocca.fixture.code-measure-equivalence5123'
(app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle,CFBundleExecutable='CodeMeasurement',CFBundleName='CodeMeasurement',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='26.0',LSRequiresIPhoneOS=True,UIDeviceFamily=[1],UILaunchScreen={})))
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
cmd=['xcrun','swiftc','-O','-parse-as-library','-swift-version','6','-target',platform.machine()+'-apple-ios26.0-simulator','-sdk',sdk,str(source),'-o',str(app/'CodeMeasurement')]
r=subprocess.run(cmd,capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr);r.check_returncode()
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True);subprocess.run(['xcrun','simctl','install',args.simulator,str(app)],check=True)
c=Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.simulator,bundle,'data'],text=True).strip());(c/'Documents/result.json').unlink(missing_ok=True)
r=subprocess.run(['xcrun','simctl','launch','--console-pty','--terminate-running-process',args.simulator,bundle]+(['-extendedOnly'] if args.extended_only else []),capture_output=True,text=True,timeout=300);(out/'run.log').write_text(r.stdout+r.stderr);r.check_returncode()
c=Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.simulator,bundle,'data'],text=True).strip());result=json.loads((c/'Documents/result.json').read_text())
result.update(baselineRef=args.baseline_ref,productSHA256=hashlib.sha256(current.encode()).hexdigest(),extractedSHA256=hashlib.sha256(swift.encode()).hexdigest(),simulator=args.simulator,scope='Exact extracted measurement methods; synthetic iOS simulator equivalence, not phone performance.')
(out/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps({k:v for k,v in result.items() if k!='failures'},ensure_ascii=False,indent=2));print('Failure count:',len(result['failures']));assert result['status']=='PASS'
