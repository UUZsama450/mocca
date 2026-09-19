#!/usr/bin/python3
"""Run production paste policies on macOS and typecheck its UIKit adapter."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/composer-native-text-input-host"
OUT.mkdir(parents=True, exist_ok=True)
SOURCE = ROOT / "Mocca/ComposerNativeTextInput.swift"
TESTS = ROOT / "CandidateTests/ComposerNativeTextInputHostTests.swift"
BINARY = OUT / "ComposerNativeTextInputHostTests"
SDK = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
COMMANDS = [
    ("build", ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(SOURCE), str(TESTS), "-o", str(BINARY)]),
    ("tests", [str(BINARY)]),
    ("ios-typecheck", ["xcrun", "swiftc", "-swift-version", "6", "-typecheck", "-target", "arm64-apple-ios17.0", "-sdk", SDK, str(SOURCE)]),
]
for name, command in COMMANDS:
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=180)
    (OUT / (name + ".log")).write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end="")
    result.check_returncode()
(OUT / "manifest.json").write_text(json.dumps({
    "production": str(SOURCE),
    "production_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
    "tests_sha256": hashlib.sha256(TESTS.read_bytes()).hexdigest(),
    "scope": "macOS production policy semantics + iOS SDK typecheck; no simulator/device, native Undo/IME/selection/layout acceptance",
}, indent=2) + "\n")
