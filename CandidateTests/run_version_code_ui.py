#!/usr/bin/env python3
"""Run the combined candidate only in the explicitly supplied simulator."""
from pathlib import Path
import argparse, json, signal, subprocess, time

p = argparse.ArgumentParser()
p.add_argument('--simulator', required=True)
p.add_argument('--name', default='ui-combined')
p.add_argument('--only-test')
args = p.parse_args()
root = Path(__file__).resolve().parents[1]
out = root / 'work/version-code-integration'
app = out / 'AppDD/Build/Products/Debug-iphonesimulator/Mocca.app'
subprocess.run(['xcrun', 'simctl', 'install', args.simulator, str(app)], check=True)
with (out / (args.name + '-record.log')).open('w') as recordlog:
    record = subprocess.Popen(['xcrun', 'simctl', 'io', args.simulator, 'recordVideo', '--codec=h264',
                               str(out / (args.name + '.mp4'))], stdout=recordlog, stderr=subprocess.STDOUT)
    time.sleep(1)
    cmd = ['xcodebuild', 'test-without-building', '-project', str(out / 'UI/BottomEntryUI.xcodeproj'),
           '-scheme', 'BottomEntryUI', '-derivedDataPath', str(out / 'RunnerDD'),
           '-destination', 'id=' + args.simulator, '-parallel-testing-enabled', 'NO',
           '-resultBundlePath', str(out / (args.name + '.xcresult'))]
    if args.only_test:
        cmd.append('-only-testing:BottomEntryUITests/BottomEntryUITests/' + args.only_test)
    (out / (args.name + '-command.json')).write_text(json.dumps(cmd, indent=2))
    try:
        with (out / (args.name + '.log')).open('w') as log:
            result = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
    finally:
        record.send_signal(signal.SIGINT)
        record.wait(timeout=30)
print('UI exit:', result.returncode)
raise SystemExit(result.returncode)
