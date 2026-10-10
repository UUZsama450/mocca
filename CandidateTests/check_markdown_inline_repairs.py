#!/usr/bin/env python3
"""Check real inline compatibility repairs against explicit and native semantics."""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/markdown-inline-repairs"
OUT.mkdir(parents=True, exist_ok=True)
source = (ROOT / "Mocca/MessageMarkdownView.swift").read_text()
start = source.index("    static func makeAttributedText(for source: String) -> AttributedString {")
end = source.index("\nprivate final class MarkdownBlockCacheEntry", start)
host = "import Foundation\nenum CandidateMarkdown {\n" + source[start:end]
host += (ROOT / "CandidateTests/MarkdownInlineRepairTests.swift").read_text()
(OUT / "host.swift").write_text(host)
subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "6", str(OUT / "host.swift"), "-o", str(OUT / "host")], check=True)
result = subprocess.run([str(OUT / "host")], capture_output=True, text=True)
(OUT / "results.json").write_text(result.stdout)
if result.stdout:
    report = json.loads(result.stdout)
    print(json.dumps(report, ensure_ascii=False, indent=2))
else:
    print(result.stderr)
raise SystemExit(result.returncode)
