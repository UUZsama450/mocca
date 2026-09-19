#!/usr/bin/python3
"""Run the unchanged production highlighter with HighlighterSwift on macOS.

Usage: /usr/bin/python3 CandidateTests/CodeSyntaxRunHostTests.py [engine-checkout]
Only a macOS command-line executable is built and run. All generated files and
logs live under the candidate's ignored work/verification directory.
"""

import argparse
import ast
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
ARGS = argparse.ArgumentParser(description=__doc__)
ARGS.add_argument("engine_checkout", nargs="?", default="/private/tmp/mocca-highlighter-research-20260910")
ARGS.add_argument("--benchmark-limits", action="store_true")
OPTIONS = ARGS.parse_args()
ENGINE = Path(OPTIONS.engine_checkout).resolve()
PIN = "fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0"  # upstream tag 3.1.0
OUT = ROOT / "work/verification/code-syntax-host"
PACKAGE = OUT / "package"
SOURCES = PACKAGE / "Sources/CodeSyntaxHostTests"


def production_limit(source, name):
    match = re.search(r"private static let " + name + r" = ([0-9_* ]+)$", source, re.MULTILINE)
    if not match:
        raise RuntimeError("Cannot read production constant {}".format(name))
    expression = ast.parse(match.group(1).strip().replace("_", ""), mode="eval")

    def integer(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mult):
            return integer(node.left) * integer(node.right)
        raise RuntimeError("Unsupported production constant expression")

    return integer(expression.body)


def run_logged(arguments, name, timeout=900):
    log = OUT / name
    start = time.monotonic()
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(arguments, cwd=ROOT, stdout=output,
                                stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        print(log.read_text(encoding="utf-8")[-18000:])
        raise RuntimeError("{} failed ({}) — {}".format(arguments[0], result.returncode, log))
    return {"seconds": round(time.monotonic() - start, 3), "log": str(log)}


def main():
    if platform.system() != "Darwin":
        raise RuntimeError("This host runner requires macOS and AppKit/JavaScriptCore")
    production = ROOT / "Mocca/CodeSyntaxHighlighter.swift"
    tests = ROOT / "CandidateTests/CodeSyntaxHighlighterHostTests.swift"
    for source in (production, tests, ENGINE / "Package.swift"):
        if not source.is_file():
            raise RuntimeError("Missing source: {}".format(source))
    revision = subprocess.check_output(["git", "-C", str(ENGINE), "rev-parse", "HEAD"],
                                       text=True).strip()
    if revision != PIN:
        raise RuntimeError("HighlighterSwift must be exactly 3.1.0 ({})".format(PIN))
    subprocess.run(["git", "-C", str(ENGINE), "diff", "--quiet", "HEAD", "--"], check=True)
    SOURCES.mkdir(parents=True, exist_ok=True)
    # Copy the complete production file byte-for-byte. Do not extract or rewrite
    # its implementation to make the host test pass.
    shutil.copyfile(production, SOURCES / production.name)
    shutil.copyfile(tests, SOURCES / tests.name)
    package_text = '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CodeSyntaxHostTests",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: ENGINE_PATH)],
    targets: [.executableTarget(
        name: "CodeSyntaxHostTests",
        dependencies: [.product(name: "Highlighter", package: ENGINE_ID)]
    )]
)
'''.replace("ENGINE_PATH", json.dumps(str(ENGINE))).replace(
        "ENGINE_ID", json.dumps(ENGINE.name.lower()))
    (PACKAGE / "Package.swift").write_text(package_text, encoding="utf-8")
    manifest = {
        "host": platform.platform(),
        "engine_revision": revision,
        "production_path": str(production),
        "production_sha256": hashlib.sha256(production.read_bytes()).hexdigest(),
        "test_sha256": hashlib.sha256(tests.read_bytes()).hexdigest(),
        "scope": "macOS host semantics and timings; no iOS/device/UI/performance acceptance",
    }
    manifest["production_limits"] = {name: production_limit(production.read_text(), name)
                                     for name in ("streamingUTF16Limit", "settledUTF16Limit", "runLimit")}
    manifest["build"] = run_logged([
        "xcrun", "swift", "build", "--package-path", str(PACKAGE),
        "--configuration", "release", "--product", "CodeSyntaxHostTests"
    ], "build.log")
    binary_dir = subprocess.check_output([
        "xcrun", "swift", "build", "--package-path", str(PACKAGE),
        "--configuration", "release", "--show-bin-path"
    ], text=True).strip()
    executable_arguments = [str(Path(binary_dir) / "CodeSyntaxHostTests")]
    executable_arguments.extend("--{}={}".format(name, value)
                                for name, value in manifest["production_limits"].items())
    if OPTIONS.benchmark_limits:
        executable_arguments.append("--benchmark-limits")
    result_name = "budget-benchmark.log" if OPTIONS.benchmark_limits else "results.log"
    manifest["run"] = run_logged(executable_arguments, result_name, timeout=180)
    result_text = (OUT / result_name).read_text(encoding="utf-8")
    marker = "CODE_SYNTAX_BUDGET_BENCH=PASS" if OPTIONS.benchmark_limits else "CODE_SYNTAX_HOST_TESTS=PASS"
    if marker not in result_text:
        raise RuntimeError("Host executable did not report PASS")
    if hashlib.sha256(production.read_bytes()).hexdigest() != manifest["production_sha256"]:
        raise RuntimeError("Production backend changed during verification; run again")
    if hashlib.sha256(tests.read_bytes()).hexdigest() != manifest["test_sha256"]:
        raise RuntimeError("Test sources changed during verification; run again")
    manifest["result"] = "PASS"
    manifest_path = OUT / ("budget-benchmark-manifest.json" if OPTIONS.benchmark_limits else "manifest.json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(result_text, end="")
    print("HOST_MANIFEST={}".format(manifest_path))


if __name__ == "__main__":
    main()
