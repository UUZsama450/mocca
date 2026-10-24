#!/usr/bin/python3
"""Compile production transcript/editor plus simulator-only semantic and motion fixtures."""
from pathlib import Path
import argparse, hashlib, json, platform, plistlib, subprocess
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'work/verification/composer-layout'
BASE = '9a29bb1b033df824ffecb0f4766294600992b448'
def block(text, marker):
    start = text.index(marker); pos = text.index('{', start) + 1; depth = 1
    while depth:
        depth += (text[pos] == '{') - (text[pos] == '}'); pos += 1
    return text[start:pos]
def main():
    p = argparse.ArgumentParser(); p.add_argument('--simulator', required=True); p.add_argument('--build-only', action='store_true'); a=p.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    source=(ROOT/'Mocca/NativeChatTranscript.swift').read_text()
    baseline=subprocess.check_output(['git','show',BASE+':Mocca/NativeChatTranscript.swift'],cwd=ROOT,text=True)
    old=block(baseline,'private final class ReadingCollectionLayout:').replace('ReadingCollectionLayout','BaselineReadingCollectionLayout')
    old=old.replace('private func rebuild() {','private func rebuild() { Probe.oldBuilds += 1')
    tested=source.replace('private func rebuild() {','private func rebuild() { Probe.newBuilds += 1')
    marker='        cell.configuredKey = key; cell.configuredPublication = publication\n'
    assert tested.count(marker)==1
    tested=tested.replace(marker, marker+'        ControllerProbe.configured(cell, key, publication)\n')
    oldtests=(ROOT/'CandidateTests/NativeLayoutReuseCheck.swift').read_text().split('@main final class LayoutApp:')[0]
    fixture=(ROOT/'CandidateTests/ComposerLayoutProbeHarness.swift').read_text()
    swift=OUT/'ComposerLayoutCombined.swift'; swift.write_text(tested+'\n'+old+'\n'+oldtests+'\n'+fixture)
    app=OUT/'ComposerLayoutProbe.app'; app.mkdir(exist_ok=True); bundle='com.mocca.fixture.composer-layout'
    (app/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle,CFBundleExecutable='ComposerLayoutProbe',CFBundleName='Composer Layout Probe',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='26.0',UIDeviceFamily=[1],UILaunchScreen={},CADisableMinimumFrameDurationOnPhone=True)))
    sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
    cmd=['xcrun','swiftc','-O','-D','DEBUG','-parse-as-library','-swift-version','6','-target',platform.machine()+'-apple-ios26.0-simulator','-sdk',sdk,str(swift),str(ROOT/'Mocca/ComposerNativeTextInput.swift'),'-o',str(app/'ComposerLayoutProbe')]
    with (OUT/'probe-compile.log').open('w') as f: subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,check=True)
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    if a.build_only: return
    subprocess.run(['xcrun','simctl','install',a.simulator,str(app)],check=True,capture_output=True)
    container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',a.simulator,bundle,'data'],text=True).strip())
    reports=[]
    for repeat in range(3):
        for mode in (['legacy','candidate'] if repeat%2==0 else ['candidate','legacy']):
            args=['-composerLayoutProbe','-fullMotionLean']+(['-composerLayoutLegacy'] if mode=='legacy' else [])
            proc=subprocess.run(['xcrun','simctl','launch','--console-pty','--terminate-running-process',a.simulator,bundle]+args,capture_output=True,text=True,timeout=150)
            (OUT/f'{mode}-{repeat}.log').write_text(proc.stdout+proc.stderr)
            path=container/'Documents/composer-layout-result.json'
            report=json.loads(path.read_text()); report.update(mode=mode,repeat=repeat)
            (OUT/f'{mode}-{repeat}.json').write_text(json.dumps(report,indent=2)+'\n'); reports.append(report)
            print(mode, repeat, report['status'], report['checks'],report['failures'],flush=True)
            assert proc.returncode==0 and report['status']=='PASS'
    summary=dict(baseline=BASE,simulator=a.simulator,sourceSHA256=hashlib.sha256(source.encode()).hexdigest(),fixtureSHA256=hashlib.sha256(fixture.encode()).hexdigest(),reports=reports,scope='Production transcript/editor + synthetic rows and composer shell on simulator. CADisplayLink callback intervals, not GPU presentation or physical-device FPS. No user data.')
    (OUT/'result.json').write_text(json.dumps(summary,indent=2)+'\n')
if __name__=='__main__': main()
