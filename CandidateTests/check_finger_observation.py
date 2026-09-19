#!/usr/bin/env python3
"""Actual Observation dependency checks, not measured SwiftUI frames or FPS."""
from pathlib import Path
import json
import re
import subprocess
from check_drawer_close_driver_reuse import extract

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/drawer-finger-progress/observation"
OUT.mkdir(parents=True, exist_ok=True)
source = (ROOT / "Mocca/RootView.swift").read_text()
declaration = extract(source, r"^@MainActor\n@Observable\nprivate final class DrawerFingerTrackingProgress\b")[0]
root_reads = source[source.index("            let settledProgress:"):source.index("            ZStack(alignment: .leading)")]
swift = r'''
import Foundation
import Observation
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
@Observable final class BaselineProgress { var progress: CGFloat? }
/*STORE*/
@main struct Runner {
    @MainActor static func main() throws {
        let drawerFingerProgress = DrawerFingerTrackingProgress()
        let baseline = BaselineProgress()
        let model = (isDrawerPresented: false, unused: 0)
        let detachedMainPanelProgress = (isActive: false, unused: 0)
        func rootRead() {
            /*ROOT_READS*/
            _ = (drawerProgress, drawerVisible, chatCornerRadius)
        }
        let begin = Counter()
        withObservationTracking { rootRead() } onChange: { begin.bump() }
        drawerFingerProgress.set(0.25)
        baseline.progress = 0.25
        precondition(begin.value == 1)
        let oldRoot = Counter(), newRoot = Counter(), leaf = Counter()
        withObservationTracking { rootRead() } onChange: { newRoot.bump() }
        // Rearm Observation for each sample: old and new read the respective
        // Root dependencies, while the visual leaf reads live progress.
        for i in 1...500 {
            withObservationTracking { _ = baseline.progress } onChange: { oldRoot.bump() }
            withObservationTracking { _ = drawerFingerProgress.progress } onChange: { leaf.bump() }
            let value = CGFloat(i % 101) / 100
            baseline.progress = value
            drawerFingerProgress.set(value)
            precondition(drawerFingerProgress.progress == value)
            precondition(drawerFingerProgress.initialProgress == 0.25)
        }
        precondition(oldRoot.value == 500 && newRoot.value == 0 && leaf.value == 500)
        let rootNotificationsDuringSamples = newRoot.value
        let end = Counter()
        withObservationTracking { rootRead() } onChange: { end.bump() }
        drawerFingerProgress.set(nil)
        precondition(end.value == 1 && !drawerFingerProgress.isActive)
        precondition(drawerFingerProgress.initialProgress == nil && drawerFingerProgress.progress == nil)
        drawerFingerProgress.set(1.5)
        precondition(drawerFingerProgress.initialProgress == 1 && drawerFingerProgress.progress == 1)
        drawerFingerProgress.set(-0.5)
        precondition(drawerFingerProgress.initialProgress == 1 && drawerFingerProgress.progress == 0)
        let unchanged = Counter()
        withObservationTracking { _ = drawerFingerProgress.progress } onChange: { unchanged.bump() }
        drawerFingerProgress.set(0)
        precondition(unchanged.value == 0)
        drawerFingerProgress.set(nil)
        drawerFingerProgress.set(0.6)
        precondition(drawerFingerProgress.initialProgress == 0.6)
        let result: [String: Any] = ["samples": 500, "baseline_root_notifications": oldRoot.value,
            "candidate_root_notifications": rootNotificationsDuringSamples, "candidate_leaf_notifications": leaf.value,
            "root_begin_notifications": begin.value, "root_end_notifications": end.value,
            "limits": "Controlled Observation subscriptions using actual Root dependency expressions; not UI body counts or device FPS."]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
'''.replace("/*STORE*/", declaration).replace("/*ROOT_READS*/", root_reads)
(OUT / "observation.swift").write_text(swift)
subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(OUT / "observation.swift"), "-o", str(OUT / "observation")], check=True)
result = subprocess.check_output([str(OUT / "observation")], text=True)
(OUT / "result.json").write_text(json.dumps(json.loads(result), indent=2) + "\n")
print(result.strip())
