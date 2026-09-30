"""Compare actual pre-change and candidate final parsers; no network, disk store, or phone timing."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/completion-work/codecs"
FILES = ["AIMessageReactionCodec.swift", "GenerationFeatures.swift", "SearchServices.swift"]
BASELINE_REF = "94a74f7"


def between(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-only", action="store_true",
                        help="Validate this snapshot without the original development history")
    parser.add_argument("--baseline-ref", default=BASELINE_REF)
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    commit = (None if args.candidate_only else subprocess.check_output(
        ["git", "rev-parse", args.baseline_ref], cwd=ROOT, text=True).strip())
    results, provenance = {}, {}
    template = (ROOT / "CandidateTests/CompletionCodecTests.swift").read_text()
    for label in (["candidate"] if args.candidate_only else ["baseline", "candidate"]):
        source = {name: (subprocess.check_output(["git", "show", f"{commit}:Mocca/{name}"], cwd=ROOT, text=True)
                         if label == "baseline" else (ROOT / "Mocca" / name).read_text()) for name in FILES}
        codecs = source["AIMessageReactionCodec.swift"] + between(source["GenerationFeatures.swift"],
            "struct ExternalImageGenerationRequest:", "struct ExternalImageModel:") + between(
                source["SearchServices.swift"], "struct SearchImageCandidate:", "enum SearchImageDownloadError:")
        for marker in ["        let matches = fullRegex.matches(", "        let stripped = fullRegex.stringByReplacingMatches("]:
            assert codecs.count(marker) == 2
            codecs = codecs.replace(marker, "        fullImageRegexPasses += 1\n" + marker)
        marker = "        let candidatesByID = Dictionary("
        assert codecs.count(marker) == 1
        codecs = codecs.replace(marker, "        candidateIndexBuilds += 1\n" + marker)
        host, binary = OUT / f"{label}.swift", OUT / label
        host.write_text(template.replace("// PRODUCT_CODECS", codecs))
        command = ["xcrun", "swiftc", "-swift-version", "6", "-O", "-parse-as-library", str(host), "-o", str(binary)]
        subprocess.run(command, check=True)
        run = subprocess.run([str(binary)], text=True, capture_output=True, check=True)
        results[label] = json.loads(run.stdout)
        provenance[label] = {"commit": commit if label == "baseline" else None,
            "inputs": {name: digest(text) for name, text in source.items()}, "command": command,
            "generatedHostSHA256": digest(host.read_text())}
        if label == "candidate":
            assert all((ROOT / "Mocca" / name).read_text() == value for name, value in source.items())
        print(label, json.dumps({k: v for k, v in results[label].items() if k != "behavior"}), flush=True)
    if not args.candidate_only:
        assert results["baseline"]["behavior"] == results["candidate"]["behavior"]
        assert results["baseline"]["work"]["ordinaryLongReply"]["imageRegexPasses"] == 3
    assert results["candidate"]["work"]["ordinaryLongReply"]["imageRegexPasses"] == 0
    assert results["candidate"]["work"]["ordinaryLongReply"]["candidateIndexBuilds"] == 0
    output = {"passed": True, "behaviorEquivalent": None if args.candidate_only else True, "scope": __doc__,
        "provenance": provenance, "runs": results}
    (OUT / "result.json").write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
    print("COMPLETION_CODECS=PASS")


if __name__ == "__main__":
    main()
