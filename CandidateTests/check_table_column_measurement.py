"""Check extracted 4998/4999 table column measurement semantics on macOS.

The production functions are extracted, not reimplemented. A separate Python
max -> ceil -> clamp oracle checks the results; recorded measurement calls
check which cells are skipped. AppKit cases exercise actual NSString sizing,
but neither their timing nor their call counts measure iPhone performance.
No App, simulator, or device is launched.
"""

from pathlib import Path
import hashlib
import json
import math
import platform
import random
import struct
import subprocess


ROOT = Path(__file__).resolve().parents[1]
BASE = "083574d"
PRODUCT = "Mocca/MessageMarkdownView.swift"
OUT = ROOT / "work/verification/table-column-measurement-host"
SEED = 0x49992026


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def extract(source, marker):
    """Extract these brace-balanced, string-brace-free production members."""
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def double_bits(value):
    return str(struct.unpack("<Q", struct.pack("<d", float(value)))[0])


def from_bits(value):
    return struct.unpack("<d", struct.pack("<Q", int(value)))[0]


def injected_case(name, header_widths, row_widths):
    bits = {}

    def cell(token, width):
        bits[token] = double_bits(width)
        return token

    return {
        "name": name,
        "category": "injected",
        "header": [cell(f"h{col}", width) for col, width in enumerate(header_widths)],
        "rows": [
            [cell(f"r{row}c{col}", width) for col, width in enumerate(values)]
            for row, values in enumerate(row_widths)
        ],
        "widthBits": bits,
        "fontSize": 18.9,
        "fontName": None,
    }


def fixtures():
    cases = []
    boundaries = [
        0, 1, 67, math.nextafter(68.0, -math.inf), 68,
        math.nextafter(68.0, math.inf), 68.25, 69, 230,
        math.nextafter(231.0, -math.inf), 231,
        math.nextafter(231.0, math.inf), 231.25,
        math.nextafter(232.0, -math.inf), 232,
        math.nextafter(232.0, math.inf), 260, 10_000,
    ]
    for index, width in enumerate(boundaries):
        cases.append(injected_case(f"boundary-header-{index}", [width], []))
        cases.append(injected_case(f"boundary-row-{index}", [0], [[width]]))
        cases.append(injected_case(f"boundary-followed-by-cap-{index}", [0], [[width], [900], [80]]))

    explicit = [
        ("empty-table", [], []),
        ("empty-header-extra-rows", [], [[100, 900], [], [1]]),
        ("missing-all-cells", [20, 200, 232], [[], [], []]),
        ("header-already-full", [232], [[40], [900], [50]]),
        ("first-row-full", [20], [[232], [60], [900]]),
        ("middle-row-full", [20], [[40], [231.5], [900]]),
        ("last-row-full", [20], [[40], [80], [232]]),
        ("never-full", [20], [[40], [230.5], [231]]),
        ("all-zero", [0, 0], [[0, 0], [0, 0]]),
        ("missing-and-extra", [30, 80, 140], [[10], [], [20, 232], [90, 100, 200, 9999]]),
        ("columns-independent", [232, 10, 10, 10], [[1, 232, 20, 30], [2, 1, 231.5, 40], [3, 2, 10, 231]]),
        ("saturated-with-missing-rows", [232, 5], [[], [4], [], [8, 232], []]),
    ]
    for name, header, rows in explicit:
        cases.append(injected_case(name, header, rows))

    # Every prefix is a new production evaluation, as with displayed streaming
    # revisions; include growth, replacement, and an empty-to-present cell.
    stream_rows = [[12, 68, 230], [50], [], [90, 231, 231.25], [999, 10, 800], [2, 3, 4]]
    for end in range(len(stream_rows) + 1):
        cases.append(injected_case(f"stream-row-prefix-{end}", [20, 60, 220], stream_rows[:end]))
    for index, width in enumerate(boundaries):
        cases.append(injected_case(f"stream-last-cell-revision-{index}", [20, 40], [[50, 68], [60, width]]))

    rng = random.Random(SEED)
    for index in range(1_200):
        columns = rng.randrange(0, 9)
        count = rng.randrange(0, 36)

        def random_width():
            if index % 3 == 0:
                return rng.random() * 231  # A substantial unsaturated matrix.
            if rng.randrange(3) == 0:
                return rng.choice(boundaries)
            return rng.random() * 1_500

        header = [random_width() for _ in range(columns)]
        rows = [[random_width() for _ in range(rng.randrange(columns + 4))] for _ in range(count)]
        cases.append(injected_case(f"seeded-random-{index}", header, rows))
        if index < 30:
            for end in range(count + 1):
                cases.append(injected_case(f"seeded-stream-{index}-{end}", header, rows[:end]))

    tick = chr(96)
    real_rows = [
        ["短", "a", ""],
        ["中文和 Latin 混排", "一二三四五六七八九十" * 8, "🙂👨‍👩‍👧‍👦 e\u0301"],
        ["第一行\n第二行更长", "tab\tbetween\twords", "**粗体原文** " + tick + "code" + tick],
        [],
        ["only one cell"],
        ["W" * 180, "x" * 12, "\\| literal", "ignored extra column"],
    ]
    for font_name in [None, "Menlo", "Helvetica"]:
        for font_size in [11, 14.5, 18.9, 24]:
            for end in range(len(real_rows) + 1):
                cases.append({
                    "name": f"appkit-{font_name}-{font_size}-{end}",
                    "category": "appkit",
                    "header": ["类型", "content", "说明 / notes"],
                    "rows": real_rows[:end],
                    "widthBits": None,
                    "fontSize": font_size,
                    "fontName": font_name,
                })
    return cases


SWIFT_SUPPORT = r'''
import AppKit
import Foundation

typealias UIFont = NSFont

// Font substitution is only for the macOS host. The column and raw-width
// functions below are verbatim extracted from production, apart from access
// control and renaming the raw measurement hook for call recording.
enum AppFontStore {
    static func uiFont(postScriptName: String?, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard let name = postScriptName, !name.isEmpty,
              let font = NSFont(name: name, size: size) else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        return weight.rawValue >= NSFont.Weight.semibold.rawValue
            ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            : font
    }
}
struct Table {
    let header: [String]
    let rows: [[String]]
}
struct Fixture: Decodable {
    let name: String
    let category: String
    let header: [String]
    let rows: [[String]]
    let widthBits: [String: String]?
    let fontSize: Double
    let fontName: String?
}
struct Result: Encodable {
    let name: String
    let before: [Double]
    let after: [Double]
    let beforeCalls: [String]
    let afterCalls: [String]
    let oracleColumns: [[Double]]
}
'''


def evaluator(name, members):
    return f"final class {name} {{\n" + r'''
    let table: Table
    let fontSize: CGFloat
    let fontName: String?
    let widthBits: [String: String]?
    var calls: [String] = []
    init(_ fixture: Fixture) {
        table = Table(header: fixture.header, rows: fixture.rows)
        fontSize = fixture.fontSize
        fontName = fixture.fontName
        widthBits = fixture.widthBits
    }
    private func measuredWidth(_ source: String, font: UIFont) -> CGFloat {
        calls.append(source)
        if let widthBits {
            guard let rawBits = widthBits[source], let bits = UInt64(rawBits) else {
                fatalError("Missing injected width for \(source)")
            }
            return CGFloat(Double(bitPattern: bits))
        }
        return nativeMeasuredWidth(source, font: font)
    }
    func rawColumnsForOracle() -> [[Double]] {
        let baseFont = AppFontStore.uiFont(postScriptName: fontName, size: tableFontSize)
        let headerFont = AppFontStore.uiFont(postScriptName: fontName, size: tableFontSize, weight: .semibold)
        return table.header.indices.map { column in
            [Double(nativeMeasuredWidth(table.header[column], font: headerFont))]
            + table.rows.compactMap { row in
                column < row.count ? Double(nativeMeasuredWidth(row[column], font: baseFont)) : nil
            }
        }
    }
''' + "\n".join(
        member.replace("private ", "", 1).replace("func measuredWidth(", "func nativeMeasuredWidth(", 1)
        for member in members
    ) + "\n}\n"


SWIFT_RUN = r'''
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: input))
var results: [Result] = []
for fixture in fixtures {
    let before = Before(fixture)
    let after = After(fixture)
    let oldWidths = before.measuredColumnWidths.map(Double.init)
    let newWidths = after.measuredColumnWidths.map(Double.init)
    results.append(Result(name: fixture.name, before: oldWidths, after: newWidths,
                          beforeCalls: before.calls, afterCalls: after.calls,
                          oracleColumns: fixture.widthBits == nil ? before.rawColumnsForOracle() : []))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
try encoder.encode(results).write(to: output, options: .atomic)
print("HOST_COMPLETE cases=\(results.count)")
'''


def displayed_width(width):
    return min(260, max(96, math.ceil(width) + 28))


def verify(cases, results):
    if len(cases) != len(results):
        raise AssertionError("Host result count differs from fixture count")
    assertions = 0
    counters = {}
    selected_examples = {}

    def require(condition, message):
        nonlocal assertions
        assertions += 1
        if not condition:
            raise AssertionError(message)

    for fixture, result in zip(cases, results):
        name = fixture["name"]
        require(result["name"] == name, f"{name}: result order")
        columns = [
            [header] + [row[column] for row in fixture["rows"] if column < len(row)]
            for column, header in enumerate(fixture["header"])
        ]
        if fixture["widthBits"] is not None:
            raw_columns = [
                [from_bits(fixture["widthBits"][source]) for source in sources]
                for sources in columns
            ]
        else:
            raw_columns = result["oracleColumns"]
        require(len(raw_columns) == len(columns), f"{name}: oracle column count")
        expected = [displayed_width(max(widths)) for widths in raw_columns]
        expected_before_calls = [source for sources in columns for source in sources]
        expected_after_calls = []
        for sources, widths in zip(columns, raw_columns):
            require(len(sources) == len(widths), f"{name}: raw source count")
            # The independent display contract identifies the first single cell
            # already capable of filling the cap. Only that ordered prefix is
            # needed, regardless of the maxima in any later cells.
            saturated_prefixes = [index + 1 for index, width in enumerate(widths) if displayed_width(width) == 260]
            prefix_length = min(saturated_prefixes, default=len(sources))
            expected_after_calls.extend(sources[:prefix_length])
        require(result["before"] == expected, f"{name}: baseline != independent oracle: {result['before']} != {expected}")
        require(result["after"] == expected, f"{name}: candidate != independent oracle: {result['after']} != {expected}")
        require(result["after"] == result["before"], f"{name}: production versions differ")
        require(result["beforeCalls"] == expected_before_calls, f"{name}: unexpected baseline measurement order")
        require(result["afterCalls"] == expected_after_calls, f"{name}: unexpected candidate measurement prefix")
        require(len(result["afterCalls"]) <= len(result["beforeCalls"]), f"{name}: candidate adds measurements")
        category = fixture["category"]
        counter = counters.setdefault(category, {"cases": 0, "before_calls": 0, "after_calls": 0, "cases_with_fewer_calls": 0})
        counter["cases"] += 1
        counter["before_calls"] += len(result["beforeCalls"])
        counter["after_calls"] += len(result["afterCalls"])
        counter["cases_with_fewer_calls"] += len(result["afterCalls"]) < len(result["beforeCalls"])
        if name in {"header-already-full", "first-row-full", "middle-row-full", "last-row-full", "never-full", "empty-table", "missing-and-extra", "columns-independent"}:
            selected_examples[name] = {
                "column_widths": expected,
                "before_calls": len(result["beforeCalls"]),
                "after_calls": len(result["afterCalls"]),
            }
    return {"assertions": assertions, "categories": counters, "examples": selected_examples}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    before = subprocess.check_output(["git", "show", f"{BASE}:{PRODUCT}"], cwd=ROOT, text=True)
    after = (ROOT / PRODUCT).read_text()
    markers = [
        "private var tableFontSize: CGFloat",
        "private var measuredColumnWidths: [CGFloat]",
        "private func measuredWidth(_ source: String, font: UIFont)",
    ]
    members_before = [extract(before, marker) for marker in markers]
    members_after = [extract(after, marker) for marker in markers]
    if members_before[0] != members_after[0] or members_before[2] != members_after[2]:
        raise AssertionError("This focused test expects unchanged table font and raw width measurement")
    for label, members in [("4998", members_before), ("4999", members_after)]:
        (OUT / f"extracted-{label}.swift").write_text("\n\n".join(members) + "\n")
    swift = SWIFT_SUPPORT + evaluator("Before", members_before) + evaluator("After", members_after) + SWIFT_RUN
    source_file = OUT / "main.swift"
    source_file.write_text(swift)
    cases = fixtures()
    fixture_file = OUT / "fixtures.json"
    fixture_file.write_text(json.dumps(cases, ensure_ascii=False, sort_keys=True))
    results_file = OUT / "results.json"
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    compiler_version = subprocess.check_output([compiler, "--version"], text=True).strip()
    build = subprocess.run([compiler, "-O", str(source_file), "-o", str(OUT / "table-column-host")], cwd=ROOT, text=True, capture_output=True)
    (OUT / "compile.log").write_text(build.stdout + build.stderr)
    if build.returncode:
        raise RuntimeError(f"Swift host compilation failed; see {OUT / 'compile.log'}")
    run = subprocess.run([str(OUT / "table-column-host"), str(fixture_file), str(results_file)], cwd=ROOT, text=True, capture_output=True)
    (OUT / "run.log").write_text(run.stdout + run.stderr)
    if run.returncode:
        raise RuntimeError(f"Swift host failed; see {OUT / 'run.log'}")
    results = json.loads(results_file.read_text())
    checks = verify(cases, results)
    if (ROOT / PRODUCT).read_text() != after:
        raise AssertionError("Product source changed during this focused run")
    summary = {
        "status": "PASS",
        "baseline_commit": subprocess.check_output(["git", "rev-parse", BASE], cwd=ROOT, text=True).strip(),
        "candidate_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "product_path": PRODUCT,
        "source_sha256": {"4998": sha(before), "4999": sha(after)},
        "extracted_member_sha256": {
            label: {marker: sha(member) for marker, member in zip(markers, members)}
            for label, members in [("4998", members_before), ("4999", members_after)]
        },
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "host_source_sha256": sha(swift),
        "fixtures_sha256": hashlib.sha256(fixture_file.read_bytes()).hexdigest(),
        "results_sha256": hashlib.sha256(results_file.read_bytes()).hexdigest(),
        "host": {"system": platform.system(), "architecture": platform.machine(), "compiler": compiler_version},
        "seed": SEED,
        "cases": len(cases),
        **checks,
        "limits": [
            "Finite, nonnegative measured widths; one-ULP boundary inputs preserve Double bits.",
            "Actual production column functions extracted; only raw measurement injection and macOS font adapters are supplied.",
            "AppKit NSString/font results are host semantic checks, not iPhone typography or performance measurements.",
            "Measurement call counts are fixture counts, not a speedup percentage.",
            "No SwiftUI/App build, device operation, rendering, gesture, or selection acceptance test.",
        ],
    }
    (OUT / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"status": "PASS", "cases": len(cases), **checks, "summary": str(OUT / 'summary.json')}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
