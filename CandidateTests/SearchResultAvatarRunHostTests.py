#!/usr/bin/python3
"""Compile the complete production avatar file on macOS, without a simulator."""

import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/search-result-avatar-host"
SOURCE = ROOT / "Mocca/SearchResultAvatar.swift"
TESTS = ROOT / "CandidateTests/SearchResultAvatarHostTests.swift"
OUT.mkdir(parents=True, exist_ok=True)
EXECUTABLE = OUT / "SearchResultAvatarHostTests"

for name, command in [
    ("build", ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
               str(SOURCE), str(TESTS), "-o", str(EXECUTABLE)]),
    ("tests", [str(EXECUTABLE)]),
]:
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=180)
    (OUT / (name + ".log")).write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end="")
    result.check_returncode()

(OUT / "manifest.json").write_text(json.dumps({
    "production": str(SOURCE),
    "production_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
    "tests_sha256": hashlib.sha256(TESTS.read_bytes()).hexdigest(),
    "scope": "macOS resolver and cache semantics; no simulator, device, SwiftUI, or frame-time acceptance",
}, ensure_ascii=False, indent=2) + "\n")
