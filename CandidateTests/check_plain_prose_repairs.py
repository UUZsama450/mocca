#!/usr/bin/env python3
"""Compare the real inline parser against 5045 without building the iOS app."""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", default="32628f3fc1fd980443c2526737c1e11611698739")
parser.add_argument("--output", type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
source_path = "Mocca/MessageMarkdownView.swift"
baseline = subprocess.check_output(
    ["git", "show", f"{args.baseline}:{source_path}"], cwd=repo, text=True
)
candidate = (repo / source_path).read_text()


def extracted(source, name):
    start = source.index("    static func makeAttributedText(for source: String) -> AttributedString {")
    end = source.index("\nprivate final class MarkdownBlockCacheEntry", start)
    return f"enum {name} {{\n" + source[start:end]


driver = (repo / "CandidateTests/ParserComparison.swift").read_text()
with tempfile.TemporaryDirectory(prefix="mocca-parser-") as directory:
    directory = Path(directory)
    main = directory / "main.swift"
    main.write_text("import Foundation\n" + extracted(baseline, "BaselineMarkdown")
                    + extracted(candidate, "CandidateMarkdown") + driver)
    binary = directory / "parser-comparison"
    subprocess.run(["xcrun", "swiftc", "-O", str(main), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
    report = json.loads(result.stdout)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(result.stdout)
    print(json.dumps({"checks": len(report["checks"]), "failures": report["failures"],
                      "scope": report["scope"]}, indent=2))
