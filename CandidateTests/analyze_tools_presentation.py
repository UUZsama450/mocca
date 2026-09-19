#!/usr/bin/env python3
"""Offline xctrace App Update / buffer-swap analysis. Never records or exports."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import xml.etree.ElementTree as ET

WINDOWS = {"central_50_to_250ms": (.05, .25), "central_50_to_300ms": (.05, .30),
           "post_input_0_to_500ms": (0, .50)}


def value(v):
    return v["text"] or v["attrs"].get("fmt", "")


def child(v, tag):
    return next((c for c in v["children"] if c["tag"] == tag), None)


def process_id(v):
    item = child(v, "pid")
    if item is not None:
        return int(value(item))
    item = child(v, "process")
    return process_id(item) if item is not None else None


def formatted_seconds(s):
    """Parse xctrace's mm:ss.mmm.uuu / hh:mm:ss.mmm.uuu display."""
    if not re.fullmatch(r"\d+(?::\d+){1,2}(?:\.\d+){1,2}", s):
        raise ValueError("Unrecognized timestamp display: " + repr(s))
    pieces = s.split(":")
    seconds, _, fractional = pieces[-1].partition(".")
    result = float(seconds + "." + fractional.replace(".", ""))
    for power, part in enumerate(reversed(pieces[:-1]), 1):
        result += int(part) * 60 ** power
    return result


def read_table(path, expected_schema):
    refs, columns, result, calibration = {}, None, [], None

    def resolve(e):
        if "ref" in e.attrib:
            return refs[e.attrib["ref"]]
        v = {"tag": e.tag, "text": (e.text or "").strip(), "attrs": dict(e.attrib),
             "children": tuple(resolve(c) for c in e)}
        if "id" in e.attrib:
            if e.attrib["id"] in refs:
                raise ValueError("Duplicate XML definition ID")
            refs[e.attrib["id"]] = v
        return v

    for _, e in ET.iterparse(path, events=("end",)):
        if e.tag == "schema":
            if columns is not None or e.attrib.get("name") != expected_schema:
                raise ValueError("Unexpected/multiple schema in " + str(path))
            columns = [c.findtext("mnemonic") for c in e.findall("col")]
        elif e.tag == "row":
            if columns is None or len(columns) != len(e):
                raise ValueError("Row/schema mismatch")
            row = dict(zip(columns, [resolve(c) for c in e]))
            timestamp = row["start" if expected_schema == "hitches-updates" else "timestamp"]
            if calibration is None and int(value(timestamp)) > 0:
                shown = timestamp["attrs"].get("fmt", "")
                raw = int(value(timestamp))
                displayed = formatted_seconds(shown)
                if abs(raw / 1e9 - displayed) > .000002:
                    raise ValueError("Timestamp unit calibration failed")
                calibration = {"raw": raw, "formatted": shown, "raw_unit": "nanoseconds"}
            result.append(row)
            e.clear()
    if columns is None or not result or calibration is None:
        raise ValueError("Missing schema, rows, or timestamp calibration: " + str(path))
    return result, {"schema": expected_schema, "columns": columns, "complete_xml": True,
                    "rows": len(result), "timestamp_calibration": calibration,
                    "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def check_receipt(directory, schema, path):
    single = directory / (schema + "-receipt.json")
    receipts = directory / "export-receipts.json"
    if single.exists():
        candidates = [json.loads(single.read_text())]
    elif receipts.exists():
        entries = json.loads(receipts.read_text())
        candidates = [r for r in entries if r.get("schema") == schema]
    else:
        return {"present": False, "note": "XML completeness is checked; exporter exit status is unavailable."}
    if not candidates:
        raise ValueError("Receipt file exists but has no entry for " + schema)
    r = candidates[-1]
    if r.get("exit_code") != 0 or r.get("complete_xml_parse") is not True or r.get("timed_out"):
        raise ValueError("Export receipt is not successful/complete for " + schema)
    if r.get("bytes") != path.stat().st_size:
        raise ValueError("Export receipt byte count mismatch for " + schema)
    return {"present": True, "exit_code": r["exit_code"], "complete_xml_parse": True,
            "row_count": r.get("row_count", r.get("rows")), "bytes": r["bytes"]}


def load_tables(run_dir, pid):
    choices = [d for d in (run_dir, run_dir / "exports", run_dir / "presentation")
               if all((d / (name + ".xml")).exists() for name in ("hitches-updates", "display-surface-swap"))]
    if len(choices) != 1:
        raise ValueError("Choose a directory containing exactly one presentation-table pair (direct, exports/, or presentation/)")
    directory = choices[0]
    raw, provenance = {}, {}
    for name in ("hitches-updates", "display-surface-swap"):
        path = directory / (name + ".xml")
        receipt = check_receipt(directory, name, path)
        raw[name], provenance[name] = read_table(path, name)
        if receipt.get("row_count") is not None and receipt["row_count"] != len(raw[name]):
            raise ValueError("Export receipt row count mismatch")
        provenance[name].update(path=str(path.resolve()), receipt=receipt)
    updates, counts = [], Counter()
    for r in raw["hitches-updates"]:
        owner, level = process_id(r["process"]), int(value(r["containment-level"]))
        counts[str(owner) + "/" + str(level)] += 1
        if level != 0:
            continue
        start, duration = int(value(r["start"])), int(value(r["duration"]))
        if duration < 0:
            raise ValueError("Negative App Update duration")
        updates.append({"pid": owner, "display": value(r["display"]),
                        "key": (int(value(r["swap-id"])), int(value(r["surface-id"]))),
                        "start_s": start / 1e9, "end_s": (start + duration) / 1e9})
    if not any(u["pid"] == pid for u in updates):
        raise ValueError("No level-0 App Updates for requested PID")
    swaps = []
    for index, r in enumerate(raw["display-surface-swap"]):
        swaps.append({"xml_row": index, "timestamp_s": int(value(r["timestamp"])) / 1e9,
                      "desired_s": int(value(r["desired-presentation-time"])) / 1e9,
                      "generation_s": int(value(r["generation-time"])) / 1e9,
                      "hid_s": int(value(r["hid-time"])) / 1e9,
                      "key": (int(value(r["swap-id"])), int(value(r["surface-id"]))),
                      "display": value(r["display-name"]), "min_quanta": int(value(r["min-quanta"]))})
    swaps.sort(key=lambda s: (s["timestamp_s"], s["xml_row"]))
    quality = attribute(updates, swaps, pid)
    quality["update_pid_level_rows"] = dict(counts)
    toc = directory / "toc.xml"
    if toc.exists():
        runs = [r for r in ET.parse(toc).getroot().findall("run")
                if r.find("./info/target/process") is not None and r.find("./info/target/process").get("pid") == str(pid)]
        if len(runs) != 1:
            raise ValueError("TOC does not identify exactly one run for requested PID")
        quality["toc_target_run"] = {"number": runs[0].get("number"), "pid": pid,
                                     "duration_s": float(runs[0].findtext("./info/summary/duration"))}
    return updates, swaps, provenance, quality


def attribute(updates, swaps, pid):
    """Unique key across ALL level-0 owners, and unique swap key, or no match."""
    by_key = defaultdict(list)
    for u in updates:
        by_key[u["key"]].append(u)
    swap_counts = Counter(s["key"] for s in swaps)
    display_pairs = defaultdict(set)
    reverse_display_pairs = defaultdict(set)
    for s in swaps:
        candidates = by_key[s["key"]]
        unique = len(candidates) == 1 and swap_counts[s["key"]] == 1
        s["matched"] = unique and candidates[0]["pid"] == pid
        s["update_display"] = candidates[0]["display"] if unique else None
        if s["matched"]:
            display_pairs[s["update_display"]].add(s["display"])
            reverse_display_pairs[s["display"]].add(s["update_display"])
    for s in swaps:
        if s["matched"] and (len(display_pairs[s["update_display"]]) != 1 or
                             len(reverse_display_pairs[s["display"]]) != 1):
            s["matched"] = False
    mapped_pools = {(s["display"], s["key"][1]) for s in swaps if s["matched"]}
    for s in swaps:
        s["target_surface_pool"] = (s["display"], s["key"][1]) in mapped_pools
    matched_keys = {s["key"] for s in swaps if s["matched"]}
    return {"total_swaps": len(swaps), "exact_target_matches": sum(s["matched"] for s in swaps),
            "unmatched_swaps": sum(not s["matched"] for s in swaps),
            "ambiguous_update_keys": sum(len(us) > 1 for us in by_key.values()),
            "duplicate_swap_keys": sum(n != 1 for n in swap_counts.values()),
            "same_timestamp_extra_rows": len(swaps) - len({s["timestamp_s"] for s in swaps}),
            "target_level0_updates_without_unique_swap": sum(u["pid"] == pid and u["key"] not in matched_keys for u in updates),
            "display_mapping_candidates": {k: sorted(v) for k, v in display_pairs.items()},
            "ambiguous_display_mapping": any(len(v) != 1 for v in display_pairs.values()) or any(len(v) != 1 for v in reverse_display_pairs.values()),
            "min_quanta_raw_counts": dict(Counter(str(s["min_quanta"]) for s in swaps))}


def quantile(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    position = (len(xs) - 1) * p
    i = int(position)
    return xs[i] + (xs[min(i + 1, len(xs) - 1)] - xs[i]) * (position - i)


def distribution(xs):
    return {"count": len(xs), "median": statistics.median(xs) if xs else None,
            "p90": quantile(xs, .9), "min": min(xs) if xs else None, "max": max(xs) if xs else None,
            "histogram_rounded_0_1ms": dict(Counter(str(round(x, 1)) for x in xs))}


def pair_metrics(pairs):
    return {name: distribution([(b[key] - a[key]) * 1000 for a, b in pairs])
            for name, key in (("actual_swap_gap_ms", "timestamp_s"),
                              ("desired_presentation_gap_ms", "desired_s"), ("generation_gap_ms", "generation_s"))}


def window_metrics(swaps, start, end):
    # Keep the original chronological stream intact. Unmatched/duplicate/foreign
    # rows are barriers; never first filter them away and then zip survivors.
    pairs = [(a, b) for a, b in zip(swaps, swaps[1:])
             if start <= a["timestamp_s"] < b["timestamp_s"] <= end]
    exact = [(a, b) for a, b in pairs if a["matched"] and b["matched"]
             and a["display"] == b["display"] and a["update_display"] == b["update_display"]]
    matched = [s for s in swaps if start <= s["timestamp_s"] <= end and s["matched"]]
    return {"strict_exact_target_adjacent_pairs": pair_metrics(exact),
            "original_adjacent_pair_count": len(pairs), "rejected_pair_count": len(pairs) - len(exact),
            "exact_target_swap_count": len(matched),
            "actual_minus_desired_ms_exact": distribution([(s["timestamp_s"] - s["desired_s"]) * 1000 for s in matched])}


def group_hid(times, threshold):
    groups = []
    for timestamp in sorted(set(times)):
        if not groups or timestamp - groups[-1][-1] > threshold:
            groups.append([])
        groups[-1].append(timestamp)
    return groups


def read_segments(path, swaps, duration=None):
    if path is None:
        return [{"id": "all", "start_s": 0 if duration is not None else swaps[0]["timestamp_s"],
                 "end_s": duration if duration is not None else swaps[-1]["timestamp_s"] + 1e-9}], {}
    data = json.loads(path.read_text())
    entries = data if isinstance(data, list) else data.get("segments", data.get("phases", []))
    segments = []
    for entry in entries:
        bounds = entry.get("covered_trace_envelope_seconds", entry.get("trace_relative_host_envelope_seconds"))
        start, end = bounds if bounds is not None else (entry["start_s"], entry["end_s"])
        identifier = str(entry.get("id", entry.get("phase", "")))
        if not identifier or not math.isfinite(start) or not math.isfinite(end) or end <= start:
            raise ValueError("Invalid segment")
        segments.append({"id": identifier, "start_s": start, "end_s": end})
    if not segments or len({s["id"] for s in segments}) != len(segments):
        raise ValueError("Missing/duplicate segment IDs")
    segments.sort(key=lambda s: s["start_s"])
    if any(a["end_s"] > b["start_s"] for a, b in zip(segments, segments[1:])):
        raise ValueError("Overlapping segments are not allowed")
    labels = {}
    for entry in data.get("input_labels", []) if isinstance(data, dict) else []:
        key = (str(entry["segment"]), int(entry["input_group"]))
        if key in labels:
            raise ValueError("Duplicate input label")
        labels[key] = str(entry["label"])
    return segments, labels


def analyze(run_dir, pid, segments_path=None, exclusions=(), hid_source="matched", min_pairs=5):
    updates, swaps, provenance, quality = load_tables(run_dir, pid)
    if not any(s["matched"] for s in swaps):
        raise ValueError("No unique target swap attribution")
    segments, labels = read_segments(segments_path, swaps, quality.get("toc_target_run", {}).get("duration_s"))
    excludes = set()
    for exclusion in exclusions:
        segment, group = exclusion.rsplit(":", 1)
        key = (segment, int(group))
        if key in excludes or key[1] < 1:
            raise ValueError("Duplicate/invalid exclusion")
        excludes.add(key)
    results, seen = [], set()
    for segment in segments:
        left, right = segment["start_s"], segment["end_s"]
        selected = [s for s in swaps if left <= s["timestamp_s"] < right]
        matched_hid = {s["hid_s"] for s in selected if s["matched"] and s["hid_s"] > 0 and left <= s["hid_s"] < right}
        pool_hid = {s["hid_s"] for s in selected if s["target_surface_pool"] and s["hid_s"] > 0 and left <= s["hid_s"] < right}
        times = matched_hid if hid_source == "matched" else pool_hid
        groups = group_hid(times, .3)
        sensitivity = {str(t): group_hid(times, t) == groups for t in (.2, .3, .4, .5)}
        inputs = []
        for index, group in enumerate(groups, 1):
            key = (segment["id"], index)
            seen.add(key)
            last = group[-1]
            following = groups[index][0] if index < len(groups) else right
            windows = {}
            for name, (lo, hi) in WINDOWS.items():
                start = last + lo
                available_end = min(last + hi, following, right)
                end = max(start, available_end)
                metrics = window_metrics(swaps, start, end) if available_end > start else window_metrics([], start, start)
                count = metrics["strict_exact_target_adjacent_pairs"]["actual_swap_gap_ms"]["count"]
                windows[name] = {"bounds_s": [start, end], "unclipped": available_end == last + hi,
                                 "empty_after_clipping": available_end <= start, "minimum_strict_pairs": min_pairs,
                                 "enough_strict_pairs": count >= min_pairs, **metrics}
            inputs.append({"input_group": index, "hid_times_s": group, "last_hid_s": last,
                           "user_label": labels.get(key), "excluded_by_user": key in excludes, "windows": windows})
        results.append({"segment": segment, "hid_source": hid_source, "input_group_count": len(groups),
                        "grouping_identical_at_thresholds_s": sensitivity,
                        "hid_times_on_pool_without_exact_target_match": sorted(pool_hid - matched_hid),
                        "input_groups": inputs})
    if excludes - seen or set(labels) - seen:
        raise ValueError("Unknown excluded/labeled input group: " + str((excludes | set(labels)) - seen))
    central_counts = Counter()
    flat_windows = []
    for segment in results:
        for group in segment["input_groups"]:
            for name, w in group["windows"].items():
                actual = w["strict_exact_target_adjacent_pairs"]["actual_swap_gap_ms"]
                median = actual["median"]
                band = None if median is None else "near_8_33_ms" if abs(median - 1000 / 120) <= .6 else "near_16_67_ms" if abs(median - 1000 / 60) <= .6 else "other"
                flat_windows.append({"id": segment["segment"]["id"] + ":" + str(group["input_group"]) + ":" + name,
                                     "bounds_s": w["bounds_s"], "segment": segment["segment"]["id"],
                                     "input_group": group["input_group"], "window_name": name,
                                     "excluded_by_user": group["excluded_by_user"], "user_label": group["user_label"],
                                     "actual_swap_gap_median_ms": median, "strict_pair_count": actual["count"],
                                     "cadence_band": band, "grouping_stable": all(segment["grouping_identical_at_thresholds_s"].values()),
                                     "eligible_for_comparison": not group["excluded_by_user"] and w["unclipped"] and w["enough_strict_pairs"] and all(segment["grouping_identical_at_thresholds_s"].values())})
            window = group["windows"]["central_50_to_250ms"]
            if group["excluded_by_user"]:
                central_counts["explicitly_excluded"] += 1
                continue
            if not window["enough_strict_pairs"] or not window["unclipped"] or not all(segment["grouping_identical_at_thresholds_s"].values()):
                central_counts["insufficient_or_clipped"] += 1
                continue
            median = window["strict_exact_target_adjacent_pairs"]["actual_swap_gap_ms"]["median"]
            band = "near_8_33_ms" if abs(median - 1000 / 120) <= .6 else "near_16_67_ms" if abs(median - 1000 / 60) <= .6 else "other"
            central_counts[band] += 1
    return {"target_pid": pid, "time_origin": "trace_start", "source_run": str(run_dir.resolve()), "tables": provenance,
            "segments_input": None if segments_path is None else {"path": str(segments_path.resolve()), "sha256": hashlib.sha256(segments_path.read_bytes()).hexdigest()},
            "quality": quality, "central_window_group_median_bands": dict(central_counts), "segments": results, "windows": flat_windows,
            "limits": [
                "Offline buffer-swap telemetry, not callback FPS, changing-pixel proof, or whole-session average FPS.",
                "No route or direction is inferred. Segment IDs and optional labels come only from explicit input; excluded groups remain visible.",
                "Each strict endpoint has a unique swap key and a unique level-0 update key across all exported PIDs. Duplicate, foreign, and unmatched rows remain adjacency barriers.",
                "Time ordering preserves every XML row; strict pairs also require consistent display mapping. Different display names are mapped using uniquely shared keys, not name equality.",
                "Matched HID mode uses input timestamps carried by exactly attributed swaps. It may miss an input's last timestamp; pool-only HID times are reported separately.",
                "Target-surface-pool HID mode also uses unmatched swaps on previously matched display/surface pairs. This is weaker HID attribution, not PID proof for those swaps; strict cadence matching is unchanged.",
                "HID grouping thresholds and fixed post-input windows are observation choices, not route markers or measured animation duration. Missing/unstable groups are not synthesized.",
                "Desired Presentation Time is an exported pipeline target; Min Quanta remains an uninterpreted raw value. Neither establishes the application's frame-rate request API."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", "--run-dir", required=True, type=Path, dest="run")
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--segments", type=Path, help="Explicit segments JSON or existing phase-envelopes.json")
    parser.add_argument("--exclude-input", action="append", default=[], metavar="SEGMENT:INDEX")
    parser.add_argument("--hid-source", choices=("matched", "target-surface-pool"), default="matched")
    parser.add_argument("--min-strict-pairs", type=int, default=5)
    parser.add_argument("--output", required=True, type=Path, help="New output file; existing files are never overwritten")
    args = parser.parse_args()
    if args.pid <= 0 or args.min_strict_pairs < 1:
        parser.error("PID and minimum pair count must be positive")
    if args.output.exists():
        parser.error("Output already exists; choose a new path")
    result = analyze(args.run, args.pid, args.segments, args.exclude_input, args.hid_source, args.min_strict_pairs)
    with args.output.open("x") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(json.dumps({"quality": result["quality"], "central_window_group_median_bands": result["central_window_group_median_bands"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
