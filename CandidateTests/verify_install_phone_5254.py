"""Authorized same-bundle phone update; no uninstall or app-container access."""
from pathlib import Path
import argparse,datetime,fnmatch,hashlib,json,plistlib,re,shlex,shutil,subprocess,time
ROOT=Path(__file__).resolve().parents[1]; OUT=ROOT/'work/phone-5254'
DEVICE='4B6CACC3-FCC7-5A2E-80BA-83B55CFE5FCB';BUNDLE='com.uuzsama450.mocca.migration'
read=lambda p:json.loads(p.read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
files=lambda p:{str(f.relative_to(p)):sha(f) for f in p.rglob('*') if f.is_file()}
def run(c):return subprocess.check_output(c,stderr=subprocess.DEVNULL)
def entitlements(p):return plistlib.loads(run(['codesign','-d','--entitlements',':-',str(p)]))
def uuids(p):return sorted(re.findall(r'UUID: ([A-F0-9-]+) \(([^)]+)\)',run(['xcrun','dwarfdump','--uuid',str(p)]).decode()))
def verify():
 assert read(OUT/'build-result.json')['exitCode']==0
 log=(OUT/'build.log').read_text(); assert '** BUILD SUCCEEDED **' in log
 appCompiles=[line for line in log.splitlines() if 'swiftc' in line and '-module-name Mocca ' in line]
 assert appCompiles
 for line in appCompiles:
  tokens=shlex.split(line); defines={tokens[i+1] if value=='-D' else value[2:] for i,value in enumerate(tokens) if value.startswith('-D')}
  assert 'DEBUG' not in defines and '-O' in tokens

 qa=Path('/tmp/mocca-5254-tests.log').read_text();assert '** TEST SUCCEEDED **' in qa and 'Executed 72 tests, with 0 failures' in qa
 assert '** TEST SUCCEEDED **' in (ROOT/'work/verification/model-catalog-20261026/ui-tests.log').read_text()
 assert 'PASS language' in Path('/tmp/mocca-5254-localization.log').read_text()
 inputs=read(OUT/'source-sha256.json');assert all(sha(ROOT/p)==h and sha(OUT/'host'/p)==h for p,h in inputs.items())
 rollback=OUT/'rollback-5252/Mocca.app';assert files(rollback)==read(rollback.parent/'artifact-verification.json')['frozenAppFiles']
 run(['codesign','--verify','--deep','--strict',str(rollback)])
 products=OUT/'DerivedData/Build/Products/Release-iphoneos';app=products/'Mocca.app'
 udid=read(OUT/'device.json')['result']['hardwareProperties']['udid']
 checks=[]
 for rel,dsym,identifier in [('', 'Mocca.app.dSYM',BUNDLE),('PlugIns/GenerationActivityExtension.appex','GenerationActivityExtension.appex.dSYM',BUNDLE+'.GenerationActivityExtension')]:
  bundle=app/rel;info=plistlib.loads((bundle/'Info.plist').read_bytes())
  assert (info['CFBundleShortVersionString'],info['CFBundleVersion'],info['CFBundleIdentifier'])==('1.0.7','5254',identifier)
  run(['codesign','--verify','--deep','--strict',str(bundle)])
  e=entitlements(bundle);assert e==entitlements(rollback/rel)
  profile=plistlib.loads(run(['security','cms','-D','-i',str(bundle/'embedded.mobileprovision')]))
  assert udid in profile['ProvisionedDevices'] and profile['ExpirationDate']>datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
  assert fnmatch.fnmatchcase(e['application-identifier'],profile['Entitlements']['application-identifier'])
  binary=bundle/info['CFBundleExecutable'];assert run(['lipo','-archs',str(binary)]).strip()==b'arm64'
  assert uuids(binary) and uuids(binary)==uuids(products/dsym)
  assert b'XCTest' not in run(['otool','-L',str(binary)])
  assert not any(marker in binary.read_bytes() for marker in [b'document.test',b'fixture-main',b'CatalogFixture',b'ModelCatalogInteractionUITests',b'reviewInstallStore',b'reviewFailCommits'])
  checks.append({'bundle':identifier,'version':'1.0.7','build':'5254','signature':'PASS','entitlementsMatch5252':True,'deviceProvisioned':True,'arm64':True,'dSYMMatched':True,'testCodeExcluded':True})
 for name in ['Mocca.app','Mocca.app.dSYM','GenerationActivityExtension.appex.dSYM']:shutil.copytree(products/name,OUT/name,symlinks=True)
 result={'status':'PASS','checks':checks,'frozenAppFiles':files(OUT/'Mocca.app'),'tests':72,'phoneInstalled':False}
 (OUT/'artifact-verification.json').write_text(json.dumps(result,indent=2));print(json.dumps({'status':'PASS','checks':checks}))
def deploy():
 a=read(OUT/'artifact-verification.json');assert a['status']=='PASS' and files(OUT/'Mocca.app')==a['frozenAppFiles']
 evidence=OUT/'deployment';evidence.mkdir(exist_ok=False)
 def device(name,operation,*args):
  path=evidence/(name+'.json');r=subprocess.run(['xcrun','devicectl','--timeout','60',*operation,'--device',DEVICE,'--json-output',str(path),*args],capture_output=True,text=True)
  (evidence/(name+'.log')).write_text(r.stdout+r.stderr)
  if r.returncode:raise RuntimeError(name+' failed; inspect metadata before retry')
  return read(path)['result']
 def app(name):
  result=device(name,('device','info','apps'),'--filter','bundleIdentifier == "'+BUNDLE+'"');assert result['deviceIdentifier']==DEVICE
  values=result['apps'];assert len(values)==1;return values[0]
 before=app('before');assert before['bundleVersion']=='5252','Installed version changed; reconcile before updating.'
 assert not device('lock',('device','info','lockState'))['passcodeRequired'],'Unlock phone before updating.'
 result={'status':'prepared','device':DEVICE,'previousBuild':'5252','version':'1.0.7','build':'5254','sameBundleInPlace':True,'uninstalled':False,'appContainerAccessed':False,'physicalUXAccepted':False}
 def save():(OUT/'deployment.json').write_text(json.dumps(result,indent=2))
 save();device('install',('device','install','app'),str(OUT/'Mocca.app'));result['status']='installed_pending_readback';save()
 after=app('after');assert after['bundleVersion']=='5254' and after['version']=='1.0.7';result['status']='installed_verified';save()
 launch=device('launch',('device','process','launch'),BUNDLE);pid=launch['process']['processIdentifier']
 assert launch['launchOptions']['arguments']==[] and not launch['launchOptions']['startStopped']
 time.sleep(2)
 process=device('process',('device','info','processes'),'--filter','processIdentifier == '+str(pid))
 assert any(p['processIdentifier']==pid for p in process['runningProcesses'])
 result.update(status='installed_and_launched_verified',launchSucceeded=True,processIdentifier=pid);save();print(json.dumps(result))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('action',choices=['verify','deploy']);args=p.parse_args()
 verify() if args.action=='verify' else deploy()
