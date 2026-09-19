"""Extract actual routing classes into a standalone simulator-only UIKit harness."""
from pathlib import Path
import hashlib
import json
import platform
import plistlib
import subprocess
from check_drawer_close_driver_reuse import extract

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT.parents[1] / 'verification/drawer-native-hit-routing-5038/harness'
OUT.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'Mocca/RootView.swift').read_text()
baseline = subprocess.check_output(['git', 'show', '06911104abb3c10d599d0ca2137849aa0d4ef683:Mocca/RootView.swift'], cwd=ROOT, text=True)
classes = [extract(baseline, r'^private final class DrawerLivePanelPassthroughView\b')[0].replace('DrawerLivePanelPassthroughView', 'BaselineDrawerLivePanelPassthroughView')]
classes.append(extract(baseline, r'^private struct MainChatPanelChrome\b')[0])
for name in ['DrawerLivePanelPassthroughView', 'DrawerMainPanelTouchShield']:
    classes.append(extract(source, rf'^private final class {name}\b')[0])
generated = (ROOT / 'CandidateTests/DrawerNativeHitRoutingHarness.swift').read_text().replace('// EXTRACTED_ROUTING_CLASSES', '\n\n'.join(classes))
swift = OUT / 'Generated.swift'
swift.write_text(generated)
app = OUT / 'Harness.app'; app.mkdir(exist_ok=True)
bundle = 'com.mocca.local.drawer-native-hit-routing5038.harness'
(app / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle, CFBundleExecutable='Harness', CFBundleName='Drawer Routing Checks', CFBundlePackageType='APPL', CFBundleVersion='5038', CFBundleShortVersionString='1.0', LSRequiresIPhoneOS=True, MinimumOSVersion='18.0', UILaunchScreen={}, UIDeviceFamily=[1])))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
cmd = ['xcrun', 'swiftc', '-parse-as-library', '-O', '-g', '-sdk', sdk, '-target', f'{platform.machine()}-apple-ios18.0-simulator', '-swift-version', '6', str(swift), '-o', str(app / 'Harness')]
manifest = dict(source_sha256=hashlib.sha256(source.encode()).hexdigest(), generated_sha256=hashlib.sha256(generated.encode()).hexdigest(), build_command=cmd, app=str(app), bundle=bundle)
(OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(json.dumps(manifest, indent=2))
