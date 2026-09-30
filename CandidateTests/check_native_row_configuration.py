"""Compare full 5127/candidate UIKit transcript controllers in a synthetic simulator app.

Only configuration and reuse counters are injected into the product copy. This uses
real collection batch updates, cell reuse, layout and hosting, not phone timing.
"""
from pathlib import Path
import argparse, hashlib, json, platform, plistlib, subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'work/verification/native-row-configuration'
FILE = 'Mocca/NativeChatTranscript.swift'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--simulator', required=True)
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    baseline = subprocess.check_output(['git', 'show', 'e0588d4:' + FILE], cwd=ROOT, text=True)
    current = (ROOT / FILE).read_text()
    harness = (ROOT / 'CandidateTests/NativeRowConfigurationHarness.swift').read_text()
    expected = json.loads((ROOT / 'CandidateTests/PHONE_5127_SOURCE.json').read_text())[FILE]
    digest = lambda value: hashlib.sha256(value.encode()).hexdigest()
    assert digest(baseline) == expected
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    reports = {}
    for label, source in [('baseline', baseline), ('candidate', current)]:
        marker = '        cell.configuredKey = key; cell.configuredPublication = publication\n'
        assert source.count(marker) == 1
        tested = source.replace(marker, marker + '        RowConfigurationProbe.record(cell: cell, key: key, publication: publication)\n')
        reuse = '    override func prepareForReuse() {\n'
        assert tested.count(reuse) == 1
        tested = tested.replace(reuse, reuse + '        let probeOldHost = measurementHostID\n        defer { RowConfigurationProbe.reused(old: probeOldHost, new: measurementHostID) }\n')
        tested += '\n' + harness
        swift = OUT / (label + '.swift'); swift.write_text(tested)
        app = OUT / (label + '.app'); app.mkdir(exist_ok=True)
        bundle = 'com.mocca.fixture.row-configuration.' + label
        (app / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle, CFBundleExecutable='RowConfiguration',
            CFBundleName='RowConfiguration', CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1.0',
            MinimumOSVersion='26.0', UIDeviceFamily=[1], UILaunchScreen={})))
        command = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-swift-version', '6', '-target',
                   platform.machine() + '-apple-ios26.0-simulator', '-sdk', sdk, str(swift), '-o', str(app / 'RowConfiguration')]
        with (OUT / (label + '-compile.log')).open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        subprocess.run(['xcrun', 'simctl', 'install', args.simulator, str(app)], check=True, capture_output=True)
        container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.simulator, bundle, 'data'], text=True).strip())
        result = container / 'Documents/row-configuration-result.json'
        if result.exists(): result.unlink()
        run = subprocess.run(['xcrun', 'simctl', 'launch', '--console-pty', '--terminate-running-process', args.simulator, bundle],
                             capture_output=True, text=True, timeout=90)
        (OUT / (label + '-run.log')).write_text(run.stdout + run.stderr)
        report = json.loads(result.read_text())
        report.update(sourceSHA256=digest(source), harnessSHA256=digest(tested), command=command)
        (OUT / (label + '-result.json')).write_text(json.dumps(report, indent=2) + '\n')
        print(label, json.dumps({k: v for k, v in report.items() if k in ['status', 'checks', 'failures']}), flush=True)
        assert run.returncode == 0 and report['status'] == 'PASS'
        reports[label] = report
    table = []
    for old, new in zip(reports['baseline']['cases'], reports['candidate']['cases']):
        assert old['name'] == new['name'] and old['rows'] == new['rows']
        assert old['visible'] == new['visible'], (old['name'], old['visible'], new['visible'])
        assert abs(old['offset'] - new['offset']) < 1, (old['name'], old['offset'], new['offset'])
        assert new['duplicateConfigurations'] == 0, new
        table.append({'scenario': old['name'], 'baselineConfigurations': old['configurations'],
            'candidateConfigurations': new['configurations'], 'baselineDuplicateConfigurations': old['duplicateConfigurations'],
            'candidateDuplicateConfigurations': new['duplicateConfigurations']})
    assert sum(row['baselineDuplicateConfigurations'] for row in table) > 0
    assert (ROOT / FILE).read_text() == current
    assert (ROOT / 'CandidateTests/NativeRowConfigurationHarness.swift').read_text() == harness
    summary = {'status': 'PASS', 'table': table, 'checksPerBuild': reports['candidate']['checks'],
        'sourceSHA256': digest(current), 'baselineSHA256': digest(baseline), 'testHarnessSHA256': digest(harness), 'simulator': args.simulator,
        'scope': __doc__}
    (OUT / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__': main()
