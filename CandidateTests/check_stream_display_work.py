"""Run 5126 and candidate stream methods with controlled model/service fixtures.

Display, append, suspension, finalization, ledger, and codecs are extracted from
product source. Only access control and a filter-entry counter are added to the
test copy. Persistence endpoints, native image services, and model DTOs are
fixtures; this is not a UIKit, network, disk durability, or phone FPS test.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/drawer-display-work"
FILES = ["AppModel.swift", "OffscreenStreamingDisplayPolicy.swift",
         "AIMessageReactionCodec.swift", "GenerationFeatures.swift", "SearchServices.swift"]


def between(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def make_host(source):
    model = source["AppModel.swift"]
    members = between(model, "    private static func hasVisibleStreamingText(",
                      "    private func registerSearchImageCandidates(")
    members += between(model, "    @discardableResult\n    private func finishStreaming(",
                       "    private func completeFinishedStreamingPersistence(")
    members = members.replace("    private ", "    ")
    needle = "        let traceEnabled = StreamDeliveryTrace.isEnabled\n        let codecStartedAt"
    assert members.count(needle) == 1
    members = members.replace(needle,
        "        filterCalls += 1\n" + needle)
    constants = between(model, "    private static let streamDisplayBaseCadence:",
                        "    static let translationPlaceholder")
    codecs = source["AIMessageReactionCodec.swift"]
    codecs += between(source["GenerationFeatures.swift"],
                      "struct ExternalImageGenerationRequest:", "struct ExternalImageModel:")
    codecs += between(source["SearchServices.swift"],
                      "struct SearchImageCandidate:", "enum SearchImageDownloadError:")
    template = (ROOT / "CandidateTests/StreamDisplayWorkTests.swift").read_text()
    return template.replace("// PRODUCT_CODECS", codecs).replace(
        "// PRODUCT_LEDGER", source["OffscreenStreamingDisplayPolicy.swift"]).replace(
        "// PRODUCT_MEMBERS", constants + members)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--baseline-manifest", type=Path,
                        default=ROOT / "CandidateTests/BASELINE_5126.json")
    parser.add_argument("--candidate-only", action="store_true",
                        help="Validate this snapshot without local baseline receipts")
    args = parser.parse_args()
    runs = [("candidate", ROOT)]
    if not args.candidate_only:
        if not args.baseline_manifest.is_file():
            parser.error("Comparison requires --baseline-manifest and its matching source; use --candidate-only for this snapshot")
        baseline = json.loads(args.baseline_manifest.read_text())
        baseline_root = args.baseline or Path(baseline["source"])
        runs.insert(0, ("baseline", baseline_root))
    OUT.mkdir(parents=True, exist_ok=True)
    results, provenance = {}, {}
    for label, root in runs:
        source = {name: (root / "Mocca" / name).read_text() for name in FILES}
        if label == "baseline":
            assert all(digest(text) == baseline["inputs"]["Mocca/" + name]
                       for name, text in source.items())
        host = OUT / (label + "-stream-host.swift")
        host.write_text(make_host(source))
        binary = OUT / (label + "-stream-host")
        command = ["xcrun", "swiftc", "-swift-version", "6", "-O", "-parse-as-library",
                   str(host), "-o", str(binary)]
        subprocess.run(command, check=True)
        run = subprocess.run([str(binary)], text=True, capture_output=True, check=True)
        results[label] = json.loads(run.stdout)
        assert all((root / "Mocca" / name).read_text() == text for name, text in source.items())
        provenance[label] = {"source": str(root), "sha256": {n: digest(t) for n, t in source.items()},
                             "generatedHostSHA256": digest(host.read_text()), "command": command}
        print(label, json.dumps({key: value for key, value in results[label].items()
                                if key != "behavior"}), flush=True)
    if not args.candidate_only:
        assert results["baseline"]["behavior"] == results["candidate"]["behavior"]
        assert results["baseline"]["suspendedFilterCalls"] == 128
        assert results["baseline"]["resumeFilterCalls"] == 20
    assert results["candidate"]["suspendedFilterCalls"] == 0
    assert results["candidate"]["resumeFilterCalls"] == 0
    output = {"passed": True, "behaviorEquivalent": None if args.candidate_only else True, "runs": results, "provenance": provenance,
              "scope": __doc__}
    (OUT / "stream-tests.json").write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n")
    print("STREAM_DISPLAY_WORK_TESTS=PASS")


if __name__ == "__main__":
    main()
