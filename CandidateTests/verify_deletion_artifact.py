"""Verify the exact signed 4989 artifact before same-bundle installation."""
from pathlib import Path
import datetime, hashlib, json, plistlib, re, subprocess
root=Path(__file__).resolve().parents[1]
out=root/'work/verification'
products=out/'device-4989/derived/Build/Products/Release-iphoneos'
app=products/'Mocca.app'
assert '** BUILD SUCCEEDED **' in (out/'build-signed-4989.log').read_text()
source=json.loads((out/'build-source-sha256.json').read_text())
for f,h in source.items():
    assert hashlib.sha256((root/f).read_bytes()).hexdigest()==h, f
udid=json.loads((out/'device-details.json').read_text())['result']['hardwareProperties']['udid']
rows=[]
for bundle,ident,dsym in [
    (app,'com.uuzsama450.mocca.migration',products/'Mocca.app.dSYM'),
    (app/'PlugIns/GenerationActivityExtension.appex','com.uuzsama450.mocca.migration.GenerationActivityExtension',products/'GenerationActivityExtension.appex.dSYM')
]:
    info=plistlib.loads((bundle/'Info.plist').read_bytes())
    assert info['CFBundleIdentifier']==ident
    assert info['CFBundleVersion']=='4989'
    assert info['CFBundleShortVersionString']=='0.1.0'
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(bundle)],check=True)
    exe=bundle/info['CFBundleExecutable']
    arch=subprocess.check_output(['xcrun','lipo','-archs',str(exe)],text=True).strip()
    assert arch=='arm64'
    uuid=lambda s: re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)',s)
    macho=uuid(subprocess.check_output(['xcrun','dwarfdump','--uuid',str(exe)],text=True))
    debug=uuid(subprocess.check_output(['xcrun','dwarfdump','--uuid',str(dsym)],text=True))
    assert macho and macho==debug
    profile=plistlib.loads(subprocess.check_output(['/usr/bin/security','cms','-D','-i',str(bundle/'embedded.mobileprovision')],stderr=subprocess.DEVNULL))
    assert profile['ExpirationDate']>datetime.datetime.utcnow()
    assert udid in profile.get('ProvisionedDevices',[]) or profile.get('ProvisionsAllDevices',False)
    assert profile['TeamIdentifier']==['Z44VFV3SBB']
    permitted=profile['Entitlements']['application-identifier']
    expected_identifier='Z44VFV3SBB.'+ident
    assert permitted==expected_identifier or (
        permitted.endswith('.*') and expected_identifier.startswith(permitted[:-1])
    )
    entitlements=plistlib.loads(subprocess.check_output(['/usr/bin/codesign','-d','--entitlements',':-',str(bundle)],stderr=subprocess.DEVNULL))
    assert entitlements['application-identifier']=='Z44VFV3SBB.'+ident
    rows.append({'bundle':ident,'build':'4989','version':'0.1.0','architecture':arch,
                 'uuid':macho,'signature':'PASS','device_profile':'PASS',
                 'executable_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'path':str(bundle)})
result={'source_sha256':source,'artifacts':rows}
(out/'artifact-4989-verification.json').write_text(json.dumps(result,indent=2)+'\n')
for row in rows: print(row['bundle'],row['build'],'signature/arm64/dSYM/profile PASS')
