#!/usr/bin/env python3
"""Compare recorded native table frames; neither launches nor modifies an app."""
import argparse
import json
from pathlib import Path


def read_run(path, variant):
    lines = path.read_text().splitlines()
    rows = [json.loads(line.removeprefix("TABLE_HOST "))
            for line in lines if line.startswith("TABLE_HOST ")]
    assert any(line == f"TABLE_HOST_DONE variant={variant}" for line in lines), path
    assert rows and all(row["variant"] == variant for row in rows), path
    result = {(r["step"], r["phase"]): r for r in rows}
    assert len(result) == len(rows), "Duplicate capture keys"
    for r in rows:
        expected = {f"{kind}-{row}-{column}"
                    for kind in ("text", "cell")
                    for row in range(-1, r["rows"])
                    for column in range(3)}
        assert expected <= r["frames"].keys(), "Incomplete geometry capture"
    return result


def bottom(rect):
    return rect[1] + rect[3]


def overlaps(row):
    f = row["frames"]
    last_text = max(bottom(rect) for key, rect in f.items() if key.startswith("text-"))
    return (bottom(f["grid"]) > bottom(f["hscroll-outer"]) + 1,
            last_text > f["outro"][1] + 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    baseline = read_run(args.baseline, "baseline")
    candidate = read_run(args.candidate, "gridNatural")
    assert baseline.keys() == candidate.keys(), "Unmatched cases"
    original_grid = original_text = checked_texts = 0
    for key, old in baseline.items():
        new = candidate[key]
        for field in ("width", "rows", "spacing", "phase"):
            assert old[field] == new[field], (key, field)
        grid_overflow, text_overlap = overlaps(old)
        original_grid += grid_overflow
        original_text += text_overlap
        assert overlaps(new) == (False, False), key
        f = new["frames"]
        assert f["actions"][1] >= bottom(f["outro"]) - 0.5, key
        assert bottom(f["message"]) >= bottom(f["actions"]) - 0.5, key
        for name, rect in f.items():
            if name.startswith("text-"):
                previous = old["frames"][name]
                assert abs(rect[2] - previous[2]) < 0.5, (key, name, "width")
                assert abs(rect[3] - previous[3]) < 0.5, (key, name, "height")
                checked_texts += 1
        for row in range(-1, new["rows"]):
            cells = [f[f"cell-{row}-{c}"] for c in range(3)]
            texts = [f[f"text-{row}-{c}"] for c in range(3)]
            assert max(c[3] for c in cells) - min(c[3] for c in cells) < 0.5, (key, row)
            assert abs(cells[0][3] - max(t[3] for t in texts) - 18) < 0.5, (key, row)
            assert max(bottom(c) for c in cells) <= bottom(f["hscroll-outer"]) + 0.5, (key, row)
    assert original_grid > 0 and original_text > 0, "Baseline did not reproduce"
    summary = dict(status="PASS", cases=len(candidate), baseline_grid_overflow=original_grid,
                   baseline_text_overlap=original_text, candidate_grid_overflow=0,
                   candidate_text_overlap=0, unchanged_text_sizes=checked_texts,
                   same_row_background_heights="PASS", natural_row_heights="PASS",
                   full_app_interaction_acceptance="NOT_COVERED")
    text = json.dumps(summary, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
