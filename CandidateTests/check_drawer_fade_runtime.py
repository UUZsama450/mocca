"""Observe real SwiftUI/CALayer writes with extracted 5026/current effects.

The probe and KVO observer are test-only; production code is never instrumented.
Synthetic 1,000-row content covers stable data, content commits, rapid reversals
and the detached vertical-list phase, with deep scroll offsets preserved.
Simulator results are not phone FPS.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
from check_drawer_close_driver_reuse import extract

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/drawer-fade-ownership"
BASE = "3491e0f2d48cd90da5610dee5720634c50319001"
old = subprocess.check_output(["git", "show", f"{BASE}:Mocca/RootView.swift"], cwd=ROOT, text=True)
new = (ROOT / "Mocca/RootView.swift").read_text()
OUT.mkdir(parents=True, exist_ok=True)
simfile = OUT / "simulator.json"
if simfile.exists():
    simulator = json.loads(simfile.read_text())["udid"]
else:
    simulator = subprocess.check_output(["xcrun", "simctl", "create", "Mocca Fade Ownership 5027",
        "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "com.apple.CoreSimulator.SimRuntime.iOS-26-2"], text=True).strip()
    simfile.write_text(json.dumps({"udid": simulator, "scope": "Task-owned synthetic fade tests only"}, indent=2) + "\n")
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
if next(d["state"] for group in devices["devices"].values() for d in group if d["udid"] == simulator) == "Shutdown":
    subprocess.run(["xcrun", "simctl", "boot", simulator], check=True)
with (OUT / "runtime-boot.log").open("w") as log:
    subprocess.run(["xcrun", "simctl", "bootstatus", simulator, "-b"], stdout=log, stderr=subprocess.STDOUT, check=True)
sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
report = {"base": BASE, "candidate_root_sha256": hashlib.sha256(new.encode()).hexdigest(), "runs": {}}

for label, source in [("baseline", old), ("candidate", new)]:
    owner = extract(old, r"^@MainActor\nprivate enum DrawerTrackedContentLayerMotion\b")[0]
    if label == "baseline":
        owner = owner.replace("    private static func apply(to target: CALayer) {",
            "    private static func apply(to target: CALayer) {\n        FadeTrace.begin(target: target, progress: latestProgress)\n        defer { FadeTrace.isApplying = false }")
        modifier = extract(old, r"^private struct DrawerTrackedContentLayerModifier\b")[0]
    else:
        # The old locator is used solely for a comparable native-layer observer.
        # The candidate never calls its layer setters or corrective queue write.
        old_apply = extract(owner, r"^    private static func apply\(to target: CALayer\)")[0]
        owner = owner.replace(old_apply, """    private static func apply(to target: CALayer) {
        FadeTrace.begin(target: target, progress: latestProgress)
        FadeTrace.isApplying = false
    }""").replace("static let markerOpacity = Float(0.999)", "static let markerOpacity = Float(0.35)")
        modifier = extract(new, r"^private struct DrawerContentMotionModifier\b")[0]
    declarations = [owner, modifier,
        extract(old, r"^private struct DrawerTrackedContentLayerProbe\b")[0],
        extract(old, r"^@MainActor\nprivate final class DrawerTrackedContentLayerProbeUIView\b")[0],
        extract(source, r"^@MainActor\n@Observable\nprivate final class DrawerDetachedMainPanelProgress\b")[0]]
    swift = "import UIKit\nimport SwiftUI\nimport Observation\n" + "\n".join(declarations)
    swift += "\n" + (ROOT / "CandidateTests/DrawerFadeRuntimeHarness.swift").read_text()
    path = OUT / f"{label}-runtime.swift"
    path.write_text(swift)
    app = OUT / f"{label}-runtime.app"
    app.mkdir(exist_ok=True)
    bundle = f"com.uuzsama450.mocca.fade5027.{label}runtime"
    (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle, "CFBundleName": "Fade Runtime",
        "CFBundleExecutable": "FadeHarness", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0", "LSRequiresIPhoneOS": True, "MinimumOSVersion": "17.0",
        "UILaunchScreen": {}, "UIDeviceFamily": [1]}))
    command = ["xcrun", "swiftc", "-parse-as-library", "-sdk", sdk, "-target", "x86_64-apple-ios17.0-simulator",
               "-swift-version", "6", str(path), "-o", str(app / "FadeHarness")]
    if label == "baseline":
        command += ["-DBASELINE"]
    with (OUT / f"{label}-runtime-build.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    subprocess.run(["xcrun", "simctl", "install", simulator, str(app)], check=True)
    for case in ["stable", "content-changes"]:
        args = ["-stable-content"] if case == "stable" else []
        with (OUT / f"{label}-{case}-console.log").open("w") as log:
            subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", "--console", simulator, bundle, *args],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", simulator, bundle, "data"], text=True).strip())
        data = (container / "Documents/fade-trace.json").read_bytes()
        (OUT / f"{label}-{case}-trace.json").write_bytes(data)
        trace = json.loads(data)
        wrong = [r for r in trace["externalWrites"] if abs(r["new"] - r["expected"]) > 0.005]
        summary = {"registrations": trace["registrations"], "content_bodies": trace["contentBodies"],
                   "writes_from_framework": len(trace["externalWrites"]), "wrong_framework_values": len(wrong),
                   "opacity_mismatches": len(trace["mismatchesAtNextFrame"]),
                   "position_mismatches": len(trace["positionMismatches"]),
                   "scroll_registrations": trace["scrollRegistrations"],
                   "deep_scroll_steps": trace["deepScrollSteps"],
                   "scroll_mismatches": len(trace["scrollMismatches"])}
        assert summary["registrations"] == 1, summary
        assert summary["scroll_registrations"] == 1, summary
        assert summary["deep_scroll_steps"] == [1800, 2900], summary
        assert summary["scroll_mismatches"] == 0, summary
        report["runs"][f"{label}-{case}"] = summary
        (OUT / "runtime-report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(label, case, summary, flush=True)

assert report["runs"]["baseline-content-changes"]["wrong_framework_values"] > 0
for case in ["stable", "content-changes"]:
    before = report["runs"][f"baseline-{case}"]
    after = report["runs"][f"candidate-{case}"]
    assert after["wrong_framework_values"] == after["opacity_mismatches"] == after["position_mismatches"] == 0, after
    assert after["content_bodies"] == before["content_bodies"], (before, after)
print("Runtime ownership, position, deep scroll, and content body checks PASS")
