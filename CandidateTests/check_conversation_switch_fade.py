"""Compare real SwiftUI/native-text lifecycle and layout with/without the fade.

Runs only generated text in a task-owned simulator. Opacity observations come
from the extracted shipping modifier. This is not physical-device FPS proof.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'work/verification/conversation-fade-5030'
OUT.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'Mocca/RootView.swift').read_text()
begin = source.index('private struct ConversationSwitchFadeModifier:')
end = source.index('\nprivate struct ChatView:', begin)
modifier = source[begin:end]
probe = (ROOT / 'CandidateTests/ConversationSwitchFadeHarness.swift').read_text()
simfile = OUT / 'simulator.json'
if not simfile.exists():
    simulator = subprocess.check_output(['xcrun', 'simctl', 'create', 'Mocca Conversation Fade 5030',
        'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
        'com.apple.CoreSimulator.SimRuntime.iOS-26-2'], text=True).strip()
    simfile.write_text(json.dumps({'udid': simulator, 'scope': '5030 synthetic tests only'}, indent=2))
simulator = json.loads(simfile.read_text())['udid']
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
if next(d['state'] for group in devices['devices'].values() for d in group if d['udid'] == simulator) == 'Shutdown':
    subprocess.run(['xcrun', 'simctl', 'boot', simulator], check=True)
with (OUT / 'boot.log').open('w') as log:
    subprocess.run(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], stdout=log, stderr=subprocess.STDOUT, check=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
runs = {}
for name in ['baseline', 'candidate']:
    body = modifier.replace('\\.accessibilityReduceMotion', '\\.testReduceMotion').replace('content.opacity(reduceMotion ? 1 : opacity)',
        'content.opacity(MainActor.assumeIsolated { FadeProbe.opacity(reduceMotion ? 1 : opacity, id: conversationID) })')
    body = body.replace('MoveKeyframe(reduceMotion ? 1 : (currentOpacity < 1 ? max(0.25, currentOpacity) : 0.25))',
        'MoveKeyframe(MainActor.assumeIsolated { FadeProbe.startOpacity(reduceMotion ? 1 : (currentOpacity < 1 ? max(0.25, currentOpacity) : 0.25), current: currentOpacity) })')
    if name == 'baseline':
        body = '''private struct ConversationSwitchFadeModifier: ViewModifier {
            let conversationID: UUID
            func body(content: Content) -> some View { content }
        }'''
    path = OUT / f'{name}.swift'
    path.write_text('import SwiftUI\nimport UIKit\n' + body + '\n' + probe)
    app = OUT / f'{name}.app'
    app.mkdir(exist_ok=True)
    bundle = f'com.mocca.local.conversation-fade5030.{name}'
    (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'FadeHarness',
        'CFBundleName': 'Fade Harness', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
        'CFBundleShortVersionString': '1.0', 'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '18.0',
        'UILaunchScreen': {}, 'UIDeviceFamily': [1]}))
    with (OUT / f'{name}-build.log').open('w') as log:
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-sdk', sdk,
            '-target', 'x86_64-apple-ios18.0-simulator', '-swift-version', '6',
            str(path), '-o', str(app / 'FadeHarness')] + (['-DBASELINE'] if name == 'baseline' else []), stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], capture_output=True, check=True)
    subprocess.run(['xcrun', 'simctl', 'install', simulator, str(app)], capture_output=True, check=True)
    with (OUT / f'{name}-launch.log').open('w') as log:
        subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', '--console', simulator, bundle],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=35)
    container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', simulator, bundle, 'data'], text=True).strip())
    data = (container / 'Documents/fade-report.json').read_bytes()
    (OUT / f'{name}-report.json').write_bytes(data)
    runs[name] = json.loads(data)

events = {name: {event['name']: event for event in report['events']} for name, report in runs.items()}
for event_name, candidate in events['candidate'].items():
    baseline = events['baseline'][event_name]
    for key in ['offsetY', 'height', 'contentHeight']:
        assert candidate.get(key) == baseline.get(key), (event_name, key, candidate, baseline)
    if event_name in ['initial', 'single-finished', 'content-update-finished']:
        for key in ['bodies', 'makes', 'textWrites', 'dismantles']:
            assert candidate[key] == baseline[key], (event_name, key, candidate, baseline)
# Rapid semantic changes can coalesce differently between display frames.
# Count each actually rendered content identity, rather than falsely requiring
# both runs to draw every intermediate selection on the same simulator frame.
for report in runs.values():
    assert len(report['renderedKeys']) == len(set(report['renderedKeys'])), report['renderedKeys']
    assert report['events'][-1]['textWrites'] == len(report['renderedKeys'])
    assert report['events'][-1]['makes'] == len(report['renderedKeys']) - 1  # one same-ID text revision
    assert report['events'][-1]['dismantles'] == report['events'][-1]['makes'] - 1
# Stable message content is not rebuilt or written by animation frames.
assert events['candidate']['finish']['bodies'] == events['candidate']['restored-finished']['bodies']
assert events['candidate']['finish']['textWrites'] == events['candidate']['restored-finished']['textWrites']
samples = runs['candidate']['samples']
assert all(0.25 <= row['value'] <= 1 for row in samples)
for phase in ['initial', 'content', 'reentry', 'reduced', 'reduce-off']:
    assert all(row['value'] == 1 for row in samples if row['phase'] == phase), phase
for phase in ['single', 'next-single', 'restored']:
    values = [row['value'] for row in samples if row['phase'] == phase]
    assert values and min(values) < 0.9 and values[-1] == 1, (phase, values)
rapid = [row['value'] for row in samples if row['phase'] == 'rapid']
assert all(b + 0.000001 >= a or a == 1 for a, b in zip(rapid, rapid[1:])), rapid
assert rapid[-1] == 1
interruptions = [row for row in runs['candidate']['starts'] if row['phase'] in ['interrupted', 'rapid'] and 0.25 < row['current'] < 1]
assert interruptions, 'Run must exercise a real in-flight keyframe replacement'
assert all(row['chosen'] >= row['current'] for row in interruptions), interruptions
summary = {'passed': True, 'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'simulator': simulator, 'checks': ['single 100ms reveal despite disabled selection transaction',
    'rapid replacement preserves opacity continuity and settles fully', 'initial/empty/stream-like updates do not replay',
    'reduce motion stays opaque', 'body/text construction and settled layout match baseline'],
    'counts': {name: report['events'][-1] for name, report in runs.items()}, 'interruptions': interruptions,
    'scope': 'Real SwiftUI keyframes and native text; synthetic selections, not phone FPS.'}
(OUT / 'runtime-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
