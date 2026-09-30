#!/usr/bin/python3
"""Exercise the complete production SponsorStore using deterministic external I/O.

This does not run a simulator, access a device, buy anything, or contact Apple.
The host test module shadows StoreKit.Product; the production file is copied
whole with only its transaction-history I/O expression replaced by an empty
typed stream. Every substitution and source hash is recorded in the manifest.
"""

import hashlib
import json
from pathlib import Path
import platform
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Mocca/SponsorStore.swift"
TESTS = ROOT / "CandidateTests/SponsorProductLoadingHostTests.swift"
OUT = ROOT / "work/verification/sponsor-product-loading-host"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, name):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
    output = result.stdout + result.stderr
    (OUT / (name + ".log")).write_text(output)
    print(output, end="")
    result.check_returncode()
    return output


def main():
    if platform.system() != "Darwin":
        raise RuntimeError("This runner requires macOS with the Swift and StoreKit SDKs")
    OUT.mkdir(parents=True, exist_ok=True)
    source_hash = sha256(SOURCE)
    test_hash = sha256(TESTS)
    original = SOURCE.read_text()
    before = "for await verification in StoreKit.Transaction.all {"
    after = "for await verification in SponsorHostIO.emptyTransactionHistory {"
    if original.count(before) != 1:
        raise RuntimeError("Transaction-history injection point changed; review the runner")
    host_source = OUT / "SponsorStore.swift"
    host_source.write_text(original.replace(before, after))
    binary = OUT / "SponsorProductLoadingHostTests"
    run([
        "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
        str(host_source), str(TESTS), "-o", str(binary),
    ], "build")
    output = run([str(binary)], "results")
    if "SPONSOR_PRODUCT_LOADING_HOST_TESTS=PASS" not in output:
        raise RuntimeError("Host tests did not report PASS")
    if sha256(SOURCE) != source_hash or sha256(TESTS) != test_hash:
        raise RuntimeError("A source changed during verification; rerun against the final files")
    manifest = {
        "result": "PASS",
        "production_path": str(SOURCE),
        "production_sha256": source_hash,
        "host_source_sha256": sha256(host_source),
        "test_sha256": test_hash,
        "scope": "Production SponsorStore control flow under simulated product and history I/O; no StoreKit, App Store Connect, sandbox, device, UI, pricing, or purchase acceptance",
        "substitutions": [
            {"from": before, "to": after, "count": 1},
            {"kind": "module-local type shadow", "from": "StoreKit.Product", "to": "test Product for unqualified Product references"},
            {"kind": "localization stub", "symbols": ["L10n.lookup", "L10n.format"]},
        ],
        "host": platform.platform(),
        "scenarios": 7,
    }
    manifest_path = OUT / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print("HOST_MANIFEST=" + str(manifest_path))


if __name__ == "__main__":
    main()
