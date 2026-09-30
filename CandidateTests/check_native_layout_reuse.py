#!/usr/bin/env python3
"""Compare exact installed and candidate UIKit layout classes in an isolated simulator."""
import argparse
import hashlib
import json
import platform
import plistlib
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--simulator", required=True)
parser.add_argument("--baseline-ref", default="fad79b7")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
source = root / "Mocca/NativeChatTranscript.swift"
current = source.read_text()
baseline = subprocess.check_output(["git", "show", f"{args.baseline_ref}:Mocca/NativeChatTranscript.swift"], cwd=root, text=True)


def block(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


parts = ["import UIKit\nimport SwiftUI\n@MainActor enum Probe { static var oldBuilds = 0; static var newBuilds = 0 }"]
for marker in ["struct NativeChatLayoutConfiguration:", "enum NativeChatScrollTarget {",
               "private struct NativeChatHeightIndex {", "private struct NativeChatRowKey:",
               "private final class NativeChatAttributes:", "private final class NativeChatInvalidation:",
               "private final class NativeChatCell:"]:
    common = block(current, marker)
    assert common == block(baseline, marker), marker + " changed unexpectedly"
    parts.append(common)
# In particular, both 5114/5116 keyboard protections remain byte-for-byte intact.
assert block(current, "fileprivate final class NativeChatCollectionView:") == block(baseline, "fileprivate final class NativeChatCollectionView:")
for name, text, counter in [("BaselineReadingCollectionLayout", baseline, "oldBuilds"), ("ReadingCollectionLayout", current, "newBuilds")]:
    layout = block(text, "private final class ReadingCollectionLayout:")
    layout = layout.replace("ReadingCollectionLayout", name)
    assert layout.count("private func rebuild() {") == 1
    layout = layout.replace("private func rebuild() {", f"private func rebuild() {{\n        Probe.{counter} += 1")
    parts.append(layout)
parts.append((root / "CandidateTests/NativeLayoutReuseCheck.swift").read_text())
swift = out / "NativeLayoutExtracted.swift"
swift.write_text("\n\n".join(parts))
app = out / "LayoutReuse.app"
app.mkdir(exist_ok=True)
bundle = "com.mocca.fixture.layout-reuse5116"
(app / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier=bundle, CFBundleExecutable="LayoutReuse", CFBundleName="LayoutReuse", CFBundleDevelopmentRegion="en", CFBundlePackageType="APPL", CFBundleVersion="1", CFBundleShortVersionString="1.0", MinimumOSVersion="26.0", LSRequiresIPhoneOS=True, UIDeviceFamily=[1], UILaunchScreen={})))
sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
build = subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "6", "-target", f"{platform.machine()}-apple-ios26.0-simulator", "-sdk", sdk, str(swift), "-o", str(app / "LayoutReuse")], capture_output=True, text=True, timeout=180)
(out / "compile.log").write_text(build.stdout + build.stderr)
build.check_returncode()
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True, capture_output=True)
container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.simulator, bundle, "data"], text=True).strip())
result_file = container / "Documents/layout-result.json"
if result_file.exists():
    result_file.unlink()
run = subprocess.run(["xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", args.simulator, bundle], capture_output=True, text=True, timeout=120)
(out / "run.log").write_text(run.stdout + run.stderr)
run.check_returncode()
result = json.loads(result_file.read_text())
result.update(source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), extracted_sha256=hashlib.sha256(swift.read_bytes()).hexdigest(), baseline_ref=args.baseline_ref, simulator=args.simulator,
              scope="Exact UIKit layout and cell classes in iOS simulator; synthetic direct invalidation/measurement replay, not physical phone or natural user interaction.")
(out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
assert result["status"] == "PASS"
