#!/usr/bin/env python3
"""Prepare source-extracted UIKit checks. Never builds, launches, or uses a device."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import subprocess

from check_drawer_close_driver_reuse import method

ROOT = Path(__file__).resolve().parents[1]
METHODS = ("isPointNearGlyph", "isPointNearVisibleGlyph")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-root", type=Path, required=True)
    parser.add_argument("--output", type=Path,
                        default=ROOT / "work/verification/text-hit-storage-5034")
    args = parser.parse_args()
    roots = {"Baseline": args.baseline_root.resolve(), "Candidate": ROOT}
    sources = {name: (root / "Mocca/MessageMarkdownView.swift").read_text()
               for name, root in roots.items()}
    extracted = {name: {fn: method(source, fn) for fn in METHODS}
                 for name, source in sources.items()}
    # Refuse a stale baseline, an unedited candidate, or an unrelated method change.
    for fn in METHODS:
        old, new = extracted["Baseline"][fn][0], extracted["Candidate"][fn][0]
        assert old.count("guard attributedText.length > 0") == 1, fn
        assert new.count("guard textStorage.length > 0") == 1, fn
        assert old.replace("attributedText.length", "textStorage.length", 1) == new, fn

    classes = []
    for name in roots:
        bodies = [extracted[name][fn][0].replace("private func", "func", 1) for fn in METHODS]
        classes.append(f"final class {name}GlyphProbe: CountingNativeTextView {{\n" +
                       "\n\n".join(bodies) + "\n" +
                       "    override func query(_ method: HitMethod, _ point: CGPoint) -> Bool {\n"
                       "        switch method {\n"
                       "        case .glyph: return isPointNearGlyph(point)\n"
                       "        case .visible: return isPointNearVisibleGlyph(point)\n"
                       "        }\n    }\n}\n")
    harness = ROOT / "CandidateTests/TextHitStorageUIKitHarness.swift"
    template = harness.read_text()
    marker = "// SOURCE_EXTRACTED_PROBE_CLASSES"
    assert template.count(marker) == 1
    generated = template.replace(marker, "\n".join(classes))
    args.output.mkdir(parents=True, exist_ok=True)
    swift = args.output / "TextHitStorageGenerated.swift"
    swift.write_text(generated)
    app = args.output / "TextHitStorageHarness.app"
    app.mkdir(exist_ok=True)
    bundle = "com.mocca.local.text-hit-storage5034.harness"
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle, "CFBundleExecutable": "Harness",
        "CFBundleName": "Text Hit Storage Checks", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "LSRequiresIPhoneOS": True, "MinimumOSVersion": "18.0",
        "UILaunchScreen": {}, "UIDeviceFamily": [1],
    }))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    arch = platform.machine()
    assert arch in ("arm64", "x86_64"), arch
    manifest = {
        "status": "PREPARED_NOT_EXECUTED", "app": str(app), "bundle_id": bundle,
        "swift": str(swift), "harness_sha256": hashlib.sha256(harness.read_bytes()).hexdigest(),
        "generated_sha256": hashlib.sha256(generated.encode()).hexdigest(),
        "sources": {name: {
            "path": str(roots[name] / "Mocca/MessageMarkdownView.swift"),
            "sha256": hashlib.sha256(sources[name].encode()).hexdigest(),
            "methods": {fn: {"lines": extracted[name][fn][1],
                               "sha256": hashlib.sha256(extracted[name][fn][0].encode()).hexdigest()}
                        for fn in METHODS},
        } for name in roots},
        "build_command": ["xcrun", "swiftc", "-parse-as-library", "-O", "-g", "-sdk", sdk,
                          "-target", f"{arch}-apple-ios18.0-simulator", "-swift-version", "6",
                          str(swift), "-o", str(app / "Harness")],
        "sign_command": ["codesign", "--force", "--sign", "-", str(app)],
        "runtime_report": "Documents/text-hit-storage-results.json",
        "scope": "Real UIKit/TextKit with synthetic strings, attachments, links and query points; no mocked glyph/layout API. Only production method access changes for the harness. Not a physical gesture or performance test.",
        "extraction_checks": "PASS: two candidate method bodies differ only in their non-empty guard expression",
    }
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"status": manifest["status"], "manifest": str(args.output / "manifest.json"),
                      "extraction_checks": manifest["extraction_checks"]}, indent=2))


if __name__ == "__main__":
    main()
