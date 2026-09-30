#!/usr/bin/env python3
"""Compare the actual citation cache against archived 5116 behavior, then time it."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--baseline-ref", default="fad79b7")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
product_path = "Mocca/MessageMarkdownView.swift"
current = (repo / product_path).read_text()
baseline = subprocess.check_output(
    ["git", "show", f"{args.baseline_ref}:{product_path}"], cwd=repo, text=True
)


def extract(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


source_type = extract(current, "struct MessageCitationSource:", "@MainActor\nfinal class MessageCitationPreparationCache")
old_type = extract(baseline, "struct MessageCitationSource:", "@MainActor\nprivate final class CitationFaviconLoader")
assert source_type.strip() == old_type.strip(), "The established citation algorithm must remain unchanged."
cache_type = extract(current, "@MainActor\nfinal class MessageCitationPreparationCache", "@MainActor\nprivate final class CitationFaviconLoader")
# Counters exist only in this extracted executable, never in the app.
instrumented = source_type.replace(
    "static func sources(from toolEvents: [ToolEvent]) -> [MessageCitationSource] {",
    "static func sources(from toolEvents: [ToolEvent]) -> [MessageCitationSource] {\n        Probe.parseCalls += 1",
).replace(
    "var retainedSources: [(source: MessageCitationSource, userTurnsAfter: Int)] = []",
    "Probe.preparations += 1\n        var retainedSources: [(source: MessageCitationSource, userTurnsAfter: Int)] = []",
)
assert instrumented.count("Probe.preparations += 1") == 1
assert instrumented.count("Probe.parseCalls += 1") == 1
stubs = '''import Foundation
enum ErrorLocalization { static func lookup(_ value: String) -> String { value } }
struct ToolEvent {
    var resultText: String?
    var name: String = "search"
    var status: String = "complete"
}
struct ChatMessage {
    enum Role: String { case user, assistant, system, tool }
    var id: UUID
    var role: Role
    var toolEvents: [ToolEvent]
    var text: String = ""
    var reasoning: String = ""
    var status: String = "complete"
}
enum Probe {
    nonisolated(unsafe) static var preparations = 0
    nonisolated(unsafe) static var parseCalls = 0
    nonisolated(unsafe) static var checksum = 0
    static func reset() { preparations = 0; parseCalls = 0 }
}
'''
harness = (repo / "CandidateTests/CitationPreparationCacheCheck.swift").read_text()
swift = out / "CitationPreparationExtracted.swift"
swift.write_text(stubs + instrumented + cache_type + harness)
binary = out / "CitationPreparationCheck"
compile_result = subprocess.run(
    ["xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
    capture_output=True, text=True, timeout=120,
)
(out / "compile.log").write_text(compile_result.stdout + compile_result.stderr)
compile_result.check_returncode()
run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=240)
(out / "run.log").write_text(run.stdout + run.stderr)
run.check_returncode()
result = json.loads(run.stdout)
result["source_sha256"] = hashlib.sha256((repo / product_path).read_bytes()).hexdigest()
result["extracted_sha256"] = hashlib.sha256(swift.read_bytes()).hexdigest()
result["baseline_ref"] = args.baseline_ref
result["scope"] = "Actual extracted Foundation citation functions; simplified message payloads; host CPU timing, not UIKit or phone FPS."
(out / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(result, ensure_ascii=False, indent=2))
