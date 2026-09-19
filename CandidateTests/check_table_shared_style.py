"""Compare extracted 5009 and shared-style tables with native macOS SwiftUI.

No simulator or phone is used. Geometry probes are compiled out for timings.
The NSFont/NSColor bridge and Markdown fixture parser are shared by both sides;
The table views themselves are extracted from the two source files.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT.parent / "mocca-chat-thumbnail-background-a"
OUT = ROOT / "work/verification/table-shared-style/host"
OUT.mkdir(parents=True, exist_ok=True)
PRODUCT = "Mocca/MessageMarkdownView.swift"


def extract(source, marker, next_marker):
    return source[source.index(marker):source.index(next_marker)]


def adapt(source, name):
    source = source.replace("private struct MarkdownTableBlock: View", f"struct {name}: View")
    for key, color in [("headerBackground", ".controlBackgroundColor"),
                       ("evenRowBackground", ".textBackgroundColor"),
                       ("oddRowBackground", ".windowBackgroundColor"),
                       ("separator", ".separatorColor")]:
        source = re.sub(r"    private static let " + key + r" = UIColor \{.*?\n    \}",
                        f"    private static let {key}: NSColor = {color}", source, flags=re.S)
    source = source.replace("uiColor:", "nsColor:").replace("UIFont", "NSFont")
    source = source.replace("AppFontStore.swiftNSFont", "AppFontStore.swiftUIFont")
    source = source.replace("Color(nsColor: .label)", "Color(nsColor: .labelColor)")
    source = source.replace("Color(nsColor: .link)", "Color(nsColor: .linkColor)")
    source = source.replace("            .padding(0.5)",
                            '            .padding(0.5)\n            .reportFrame("grid")')
    source = source.replace("            .multilineTextAlignment",
                            '            .reportFrame("text-\\(rowIndex.map(String.init) ?? "header")-\\(columnIndex)")\n            .multilineTextAlignment')
    source = source.replace("            .background(cellBackground(rowIndex: rowIndex, isHeader: isHeader))",
                            '            .background(cellBackground(rowIndex: rowIndex, isHeader: isHeader))\n            .reportFrame("cell-\\(rowIndex.map(String.init) ?? "header")-\\(columnIndex)")')
    return source


old = (BASE / PRODUCT).read_text()
new = (ROOT / PRODUCT).read_text()
types = (ROOT / "Mocca/MarkdownTableSupport.swift").read_text().split("struct MarkdownTableParseResult:")[0]
table_marker = "private struct MarkdownTableBlock: View"
next_marker = "private struct MarkdownCodeBlockPalette"
tables = [adapt(extract(old, table_marker, next_marker), "BaselineTable"),
          adapt(extract(new, table_marker, next_marker), "CandidateTable")]
snapshot_tables = []
for table, name in zip(tables, ["BaselineTable", "CandidateTable"]):
    # ImageRenderer does not paint the platform-backed ScrollView on this host.
    # Snapshot only its unchanged Grid/cell subtree; geometry tests above still
    # use the complete original horizontal and vertical scroll containers.
    snapshot = table.replace(f"struct {name}: View", f"struct {name}Snapshot: View")
    snapshot = snapshot.replace("ScrollView(.horizontal, showsIndicators: true)", "Group")
    snapshot_tables.append(snapshot)
generated = OUT / "ExtractedTables.swift"
generated.write_text("import AppKit\nimport SwiftUI\n" + types + "\n".join(tables)
                     + "\n#if GEOMETRY\n" + "\n".join(snapshot_tables) + "\n#endif\n")
manifest = {"baseline": str(BASE), "candidate": str(ROOT),
            "source_sha256": hashlib.sha256(new.encode()).hexdigest(),
            "baseline_sha256": hashlib.sha256(old.encode()).hexdigest(),
            "extracted_sha256": hashlib.sha256(generated.read_bytes()).hexdigest()}
(OUT / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

mode = sys.argv[1] if len(sys.argv) > 1 else "geometry"
binary = OUT / f"host-{mode}"
command = ["xcrun", "swiftc", "-swift-version", "6", "-O", "-parse-as-library",
           "-module-cache-path", str(OUT / "ModuleCache"),
           str(generated), str(ROOT / "CandidateTests/TableSharedStyleHost.swift"), "-o", str(binary)]
if mode == "geometry":
    command += ["-D", "GEOMETRY"]
with (OUT / f"compile-{mode}.log").open("w") as log:
    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
with (OUT / f"run-{mode}.log").open("w") as log:
    subprocess.run([str(binary), str(OUT), mode], stdout=log, stderr=subprocess.STDOUT, check=True)

results = json.loads((OUT / f"{mode}.json").read_text())
if mode == "geometry":
    pairs = {}
    for row in results:
        pairs.setdefault(row["case"], {})[row["variant"]] = row
    differences = []
    compared = 0
    for name, pair in pairs.items():
        before, after = pair["baseline"]["frames"], pair["candidate"]["frames"]
        expected_cells = pair["baseline"]["expectedCells"]
        for side, frames in [("baseline", before), ("candidate", after)]:
            actual = sum(key.startswith("cell-") for key in frames)
            if actual != expected_cells:
                differences.append([name, side, "cell-count", expected_cells, actual])
        if not all(key in before and key in after for key in ["after", "grid", "actions"]):
            differences.append([name, "missing-required-frames"])
            continue
        if before.keys() != after.keys():
            differences.append([name, "frame-keys", sorted(before), sorted(after)])
            continue
        for key in before:
            for axis in before[key]:
                compared += 1
                if abs(before[key][axis] - after[key][axis]) > 0.55:
                    differences.append([name, key, axis, before[key][axis], after[key][axis]])
        for side, frames in [("baseline", before), ("candidate", after)]:
            for key, text in frames.items():
                if key.startswith("text-"):
                    cell = frames["cell-" + key[5:]]
                    if text["y"] < cell["y"] - 0.55 or text["maxY"] > cell["maxY"] + 0.55:
                        differences.append([name, side, "text-outside-cell", key])
            if frames["after"]["y"] < frames["grid"]["maxY"] - 0.55:
                differences.append([name, side, "following-prose-overlap"])
    summary = {"status": "PASS" if not differences else "FAIL", "pairs": len(pairs),
               "compared_frame_coordinates": compared, "difference_count": len(differences),
               "differences": differences[:60],
               "limits": ["macOS SwiftUI geometry, not iPhone FPS or interaction acceptance",
                          "Same platform bridges, synthetic text and drawer-probe stub on both sides"]}
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: value for key, value in summary.items() if key != "differences"}, ensure_ascii=False))
    if differences:
        print(json.dumps(differences[:10], ensure_ascii=False))
        sys.exit(1)
else:
    print(json.dumps(results, ensure_ascii=False))
