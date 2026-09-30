"""Exercise the actual candidate and 5064 Markdown parsers with Foundation.

This host checks inline semantics and CPU cost, not iPhone frame time or scroll
stability. It never builds, launches, installs, or changes the phone application.
"""
from pathlib import Path
import hashlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/streaming-emphasis-preview"
BASE = "be00846"
FILE = "Mocca/MessageMarkdownView.swift"
NAMES = ["MarkdownRenderBlock", "MarkdownListEntry", "MarkdownRenderCache",
         "MarkdownBlockCacheEntry", "MarkdownAttributedCacheEntry", "MarkdownRenderParser"]


def extracted(source, baseline=False):
    source = source[source.index("private struct MarkdownRenderBlock:"):]
    if baseline:
        for name in NAMES:
            source = re.sub(r"\b" + name + r"\b", "Baseline" + name, source)
    return source


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    source = (ROOT / FILE).read_text()
    baseline = subprocess.check_output(["git", "show", f"{BASE}:{FILE}"], cwd=ROOT, text=True)
    host = "import Foundation\n" + (ROOT / "Mocca/MarkdownTableSupport.swift").read_text()
    host += extracted(baseline, True) + extracted(source)
    host += (ROOT / "CandidateTests/streaming_emphasis_preview_host.swift").read_text()
    swift = OUT / "host.swift"
    swift.write_text(host)
    subprocess.run(["swiftc", "-O", "-swift-version", "6", str(swift), "-o", str(OUT / "host")], check=True)
    result = subprocess.run([str(OUT / "host")], capture_output=True, text=True)
    (OUT / "host-results.txt").write_text(result.stdout)
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr[:2000])
        raise SystemExit(result.returncode)
    print("SOURCE_SHA256", hashlib.sha256(source.encode()).hexdigest())


if __name__ == "__main__":
    main()
