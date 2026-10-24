#!/usr/bin/env python3
"""Compile real configuration/store sources into isolated macOS probe bundles.

Checks fail-closed configuration and disabled commerce entry points without a
phone or a StoreKit transaction. The localization shim only formats messages;
this is not a localization, UI, or purchase-success test.
"""
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = r'''
import Foundation

@MainActor enum L10n {
    static func lookup(_ key: String) -> String { key }
    static func format(_ key: String, _ arguments: [String]) -> String { key }
}

@main struct Probe {
    @MainActor static func main() async {
        let expected = CommandLine.arguments[1] == "YES"
        precondition(AppBuildConfiguration.sponsorshipEnabled == expected)
        let expectedPrefix = CommandLine.arguments[2] + ".background-generation"
        precondition(AppBuildConfiguration.backgroundTaskIdentifierPrefix == expectedPrefix)
        if !expected {
            let store = SponsorStore.shared
            // In particular, listening must return without waiting for transactions.
            await store.listenForTransactions()
            await store.prepare()
            await store.retryLoadingProducts()
            await store.purchase(.treat)
            precondition(store.productsByID.isEmpty)
            precondition(store.statistics.total == 0)
            precondition(!store.isLoadingProducts)
            precondition(store.purchasingTier == nil && store.celebration == nil)
            precondition(store.statusMessage == nil && !store.statusIsError)
        }
        print("PASS")
    }
}
'''


def main():
    cases = [("disabled", "NO", False), ("enabled", "YES", True),
             ("missing", None, False), ("unresolved", "$(MOCCA_ENABLE_SPONSORSHIP)", False),
             ("invalid", "true", False)]
    with tempfile.TemporaryDirectory(prefix="mocca-build-gate-") as temporary:
        root = Path(temporary)
        probe = root / "Probe.swift"
        probe.write_text(PROBE)
        binary = root / "Probe"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            "-target", platform.machine() + "-apple-macos14.0",
            str(ROOT / "Mocca/AppBuildConfiguration.swift"),
            str(ROOT / "Mocca/SponsorStore.swift"), str(probe), "-o", str(binary),
        ], check=True, timeout=120)
        for name, value, enabled in cases:
            contents = root / (name + ".app") / "Contents"
            macos = contents / "MacOS"
            macos.mkdir(parents=True)
            bundle_id = "org.example.mocca.gate." + name
            info = {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Probe",
                    "CFBundlePackageType": "APPL"}
            if value is not None:
                info["MoccaSponsorshipEnabled"] = value
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            executable = macos / "Probe"
            shutil.copy2(binary, executable)
            # An isolated home prevents the probe from touching personal defaults.
            probe_home = root / (name + "-home")
            probe_home.mkdir()
            env = dict(os.environ, CFFIXED_USER_HOME=str(probe_home))
            result = subprocess.run([str(executable), "YES" if enabled else "NO", bundle_id],
                                    env=env, text=True, capture_output=True, timeout=15, check=True)
            assert result.stdout.strip() == "PASS", result.stdout
    print(json.dumps({"passed": len(cases), "cases": [c[0] for c in cases],
                      "store_source": "Mocca/SponsorStore.swift",
                      "enabled_commerce_executed": False}))


if __name__ == "__main__":
    main()
