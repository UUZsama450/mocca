#!/usr/bin/env python3
"""Execute the installed and candidate projection functions against identical mutations."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--baseline-ref", default="fad79b7")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
path = "Mocca/AppModel.swift"
current = (root / path).read_text()
baseline = subprocess.check_output(["git", "show", f"{args.baseline_ref}:{path}"], cwd=root, text=True)


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


store = block(current, "@MainActor\nfinal class ConversationMessageStore")
assert store == block(baseline, "@MainActor\nfinal class ConversationMessageStore")
stubs = '''import Foundation
import Observation
struct ChatMessage: Hashable {
    var id: UUID
    var versionGroupID: String?
    var version: Int = 0
    var createdAt: Date = Date(timeIntervalSince1970: 0)
    var role: String = "assistant"
    var text: String = "initial"
    var reasoning: String = ""
    var toolResults: [String] = []
    var translation: String?
    var status: String = "streaming"
    var reactions: [String] = []
    var versionGroupKey: String { versionGroupID ?? id.uuidString }
}
struct Conversation { var id: UUID; var versionSelections: [String: Int] = [:] }
struct ProjectionResult: Equatable {
    var key: String; var message: ChatMessage; var firstRawIndex: Int
}
@MainActor enum Probe { static var baselineBuilds = 0; static var candidateBuilds = 0; static var checksum = 0 }
'''
pieces = [stubs, store]
for label, source in [("Baseline", baseline), ("Candidate", current)]:
    types = block(source, "private struct SelectedMessageProjection {") + "\n" + block(source, "private struct SelectedMessageProjectionCache {")
    function = block(source, "    private func selectedMessageProjection(")
    counter = "baselineBuilds" if label == "Baseline" else "candidateBuilds"
    needle = "        var order: [String] = []"
    assert function.count(needle) == 1
    function = function.replace(needle, f"        Probe.{counter} += 1\n" + needle)
    wrapper = f'''@MainActor final class {label}ProjectionModel {{
    let conversationMessageStore = ConversationMessageStore(snapshot: [:])
    var conversations: [UUID: Conversation] = [:]
    private var selectedMessageProjectionCache: SelectedMessageProjectionCache?
    func conversation(for id: UUID) -> Conversation? {{ conversations[id] }}
    func project(_ id: UUID, supplied: [ChatMessage]? = nil) -> [ProjectionResult] {{
        selectedMessageProjection(for: id, rawMessages: supplied).map {{
            ProjectionResult(key: $0.groupKey, message: $0.message, firstRawIndex: $0.firstRawIndex)
        }}
    }}
{function}
}}
'''
    pieces.append((types + "\n" + wrapper).replace("SelectedMessageProjection", label + "MessageProjection"))
pieces.append((root / "CandidateTests/ProjectionContentReuseCheck.swift").read_text())
swift = out / "ProjectionContentExtracted.swift"
swift.write_text("\n".join(pieces))
binary = out / "ProjectionContentCheck"
build = subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], capture_output=True, text=True, timeout=120)
(out / "compile.log").write_text(build.stdout + build.stderr)
build.check_returncode()
run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=240)
(out / "run.log").write_text(run.stdout + run.stderr)
run.check_returncode()
result = json.loads(run.stdout)
result.update(source_sha256=hashlib.sha256((root / path).read_bytes()).hexdigest(),
              extracted_sha256=hashlib.sha256(swift.read_bytes()).hexdigest(), baseline_ref=args.baseline_ref,
              scope="Extracted actual projection functions and observable store; simplified message payload; host timings, not app or phone FPS.")
(out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
