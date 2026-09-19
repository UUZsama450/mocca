#!/usr/bin/env python3
"""Offline time-profile Running sample weights in explicit trace-time windows.

No device, export, build, runloop reconstruction, presentation inference or FPS.
Run with /usr/bin/python3; standard library only. See TOOLS_TRANSITION_CPU.md.
"""
import argparse
import collections
from decimal import Decimal, InvalidOperation
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path


HANDOFF = re.compile(r"UpdateGroup\.syncMain|sync_main_callback|run_moved_callback")
DISPLAY_LIST = re.compile(r"DisplayList\.ViewUpdater\.(?:render|update)")
REQUIRED_COLUMNS = {"time", "thread", "process", "thread-state", "weight", "stack"}
METRICS = ("sampled_running_ns", "handoff_path_inclusive_ns",
           "executing_moved_callback_inclusive_ns", "display_list_on_handoff_inclusive_ns",
           "kernel_leaf_without_moved_callback_on_handoff_ns")


def xml_rows(path):
    """Consume the entire XML, resolving file-local interned subtrees."""
    refs, schema = {}, None
    schemas = 0

    def resolve(element):
        if "ref" in element.attrib:
            reference = element.attrib["ref"]
            if reference not in refs:
                raise ValueError("Unresolved XML reference: " + reference)
            return refs[reference]
        value = {"tag": element.tag, "text": (element.text or "").strip(),
                 "attrs": dict(element.attrib),
                 "children": tuple(resolve(c) for c in element)}
        if "id" in element.attrib:
            refs[element.attrib["id"]] = value
        return value

    for _, element in ET.iterparse(path, events=("end",)):
        if element.tag == "schema":
            schemas += 1
            if schemas != 1 or element.attrib.get("name") != "time-profile":
                raise ValueError("Expected exactly one time-profile table; export runs separately")
            schema = [c.findtext("mnemonic") for c in element.findall("col")]
            if len(set(schema)) != len(schema) or not REQUIRED_COLUMNS.issubset(schema):
                raise ValueError("Unsupported time-profile columns: " + repr(schema))
        elif element.tag == "row":
            values = [resolve(c) for c in element]
            if schema is None or len(values) != len(schema):
                raise ValueError("Row does not match the declared schema")
            yield dict(zip(schema, values))
            element.clear()
    if schemas != 1:
        raise ValueError("Missing time-profile schema")


def node_text(value):
    return value["text"] or value["attrs"].get("fmt", "")


def node_fmt(value):
    return value["attrs"].get("fmt", node_text(value))


def child(value, tag):
    return next((c for c in value["children"] if c["tag"] == tag), None)


def process_pid(value):
    item = child(value, "pid")
    if item is not None:
        return int(node_text(item))
    item = child(value, "process")
    return process_pid(item) if item is not None else None


def stack_frames(value):
    result = []
    for item in value["children"]:
        if item["tag"] == "frame":
            binary = child(item, "binary")
            result.append((item["attrs"].get("name", "<unnamed>"),
                           binary["attrs"].get("name", "<unknown>") if binary else "<unknown>"))
    return result


def file_identity(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return {"path": str(path.resolve()), "bytes": path.stat().st_size,
            "sha256": digest.hexdigest()}


def validate_receipt(path, xml_path, row_count):
    if path is None:
        return {"status": "not_supplied", "limit": "Only complete XML parsing is verified; export success is not independently receipted"}
    data = json.loads(path.read_text())
    if (data.get("exit_code") != 0 or data.get("xml_complete") is not True
            or data.get("timed_out") or data.get("parse_error")):
        raise ValueError("Receipt reports incomplete or failed XML export")
    if data.get("bytes") != xml_path.stat().st_size or data.get("row_count") != row_count:
        raise ValueError("Receipt byte/row counts do not match this XML")
    return {"status": "validated", "input": file_identity(path), "receipt": data}


def seconds_to_ns(value):
    if isinstance(value, bool):
        raise ValueError("Boolean is not a timestamp")
    number = Decimal(str(value))
    if not number.is_finite():
        raise ValueError("Timestamp must be finite")
    return int((number * 1_000_000_000).to_integral_value())


def load_windows(path, target_pid):
    source = json.loads(path.read_text())
    if isinstance(source, dict):
        if source.get("target_pid", target_pid) != target_pid:
            raise ValueError("Window target_pid does not match --pid")
        if source.get("time_origin", "trace_start") != "trace_start":
            raise ValueError("Windows must use trace_start time origin")
        records = source.get("windows")
    else:
        records = source
    if not isinstance(records, list) or not records:
        raise ValueError("Expected a nonempty windows list")
    windows, ids = [], set()
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            raise ValueError("Window must be an object")
        identifier = str(record.get("id", index + 1))
        if identifier in ids:
            raise ValueError("Duplicate window id: " + identifier)
        ids.add(identifier)
        if "start_ns" in record and "end_ns" in record:
            values = [record["start_ns"], record["end_ns"]]
            if any(not isinstance(v, int) or isinstance(v, bool) for v in values):
                raise ValueError("start_ns/end_ns must be integers")
            start, end = values
        else:
            values = record.get("bounds_s", [record.get("start_s"), record.get("end_s")])
            if not isinstance(values, list) or len(values) != 2 or any(v is None for v in values):
                raise ValueError("Window needs start_ns/end_ns, bounds_s, or start_s/end_s")
            start, end = map(seconds_to_ns, values)
        if start < 0 or end <= start:
            raise ValueError("Window must satisfy 0 <= start < end")
        metadata = {k: v for k, v in record.items()
                    if k not in {"start_ns", "end_ns", "start_s", "end_s", "bounds_s"}}
        windows.append({**metadata, "id": identifier, "start_ns": start, "end_ns": end})
    return windows


def load_samples(path, target_pid, main_tid, main_pattern, async_pattern):
    samples, process_counts, states, calibration = [], collections.Counter(), collections.Counter(), collections.Counter()
    rows = 0
    for row in xml_rows(path):
        rows += 1
        pid = process_pid(row["process"])
        process_counts[str(pid)] += 1
        state = node_text(row["thread-state"])
        states[state] += 1
        timestamp, weight = int(node_text(row["time"])), int(node_text(row["weight"]))
        if timestamp < 0 or weight < 0:
            raise ValueError("Negative raw sample timestamp/weight")
        calibration[(weight, node_fmt(row["weight"]))] += 1
        if pid != target_pid or state != "Running":
            continue
        thread = node_fmt(row["thread"])
        tid_node = child(row["thread"], "tid")
        tid = int(node_text(tid_node)) if tid_node else None
        main = tid == main_tid if main_tid is not None else bool(main_pattern.search(thread))
        asynchronous = bool(async_pattern.search(thread))
        if main and asynchronous:
            raise ValueError("Main/AsyncRenderer classifiers overlap: " + thread)
        samples.append({"time_ns": timestamp, "weight_ns": weight, "thread": thread, "tid": tid,
                        "bucket": "main" if main else "async_renderer" if asynchronous else "other",
                        "frames": stack_frames(row["stack"])})
    if process_counts.get(str(target_pid), 0) == 0:
        raise ValueError("Target PID absent from time-profile; refusing to report zero CPU")
    samples.sort(key=lambda s: s["time_ns"])
    return samples, {"rows": rows, "process_rows": dict(process_counts), "thread_states": dict(states),
                     "weight_calibration": [{"raw_weight_ns": w, "formatted_weight": f, "rows": c}
                                            for (w, f), c in sorted(calibration.items())]}


def summarize(samples):
    result = {bucket: {"rows": 0, "nonempty_stack_rows": 0, "unresolved_stack_rows": 0,
                      **{metric.replace("_ns", "_ms"): 0.0 for metric in METRICS}}
              for bucket in ("all", "main", "async_renderer", "other")}
    totals = {bucket: collections.Counter() for bucket in result}
    for sample in samples:
        stack, weight = sample["frames"], sample["weight_ns"]
        handoff = any(HANDOFF.search(symbol) for symbol, _ in stack)
        moved = any(symbol == "run_moved_callback" for symbol, _ in stack)
        display = any(DISPLAY_LIST.search(symbol) for symbol, _ in stack)
        unresolved = any(symbol in ("<unnamed>", "<deduplicated_symbol>")
                         or re.fullmatch(r"0x[0-9a-fA-F]+", symbol) or binary == "<unknown>"
                         for symbol, binary in stack)
        for bucket in ("all", sample["bucket"]):
            out, counter = result[bucket], totals[bucket]
            out["rows"] += 1
            out["nonempty_stack_rows"] += bool(stack)
            out["unresolved_stack_rows"] += bool(unresolved)
            counter["sampled_running_ns"] += weight
            if handoff:
                counter["handoff_path_inclusive_ns"] += weight
                if moved:
                    counter["executing_moved_callback_inclusive_ns"] += weight
                if display:
                    counter["display_list_on_handoff_inclusive_ns"] += weight
                if stack and stack[0][1] == "libsystem_kernel.dylib" and not moved:
                    counter["kernel_leaf_without_moved_callback_on_handoff_ns"] += weight
    for bucket, counter in totals.items():
        for metric in METRICS:
            result[bucket][metric.replace("_ns", "_ms")] = counter[metric] / 1_000_000
    return result


def interval_union(windows):
    merged = []
    for start, end in sorted((w["start_ns"], w["end_ns"]) for w in windows):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return merged


def select(samples, intervals):
    return [sample for sample in samples
            if any(start <= sample["time_ns"] < end for start, end in intervals)]


def analyze(args):
    input_windows = load_windows(args.windows, args.pid)
    windows = [w for w in input_windows if w.get("excluded_by_user") is not True
               and (args.window_name is None or w.get("window_name") == args.window_name)
               and (not args.eligible_only or w.get("eligible_for_comparison") is True)]
    if not windows:
        raise ValueError("No windows remain after explicit selection/exclusion rules")
    samples, profile = load_samples(args.time_profile, args.pid, args.main_tid,
                                    re.compile(args.main_thread_regex), re.compile(args.async_thread_regex))
    receipt = validate_receipt(args.receipt, args.time_profile, profile["rows"])
    results = [{**window, "wall_ms": (window["end_ns"] - window["start_ns"]) / 1_000_000,
                "sample_weights": summarize(select(samples, [(window["start_ns"], window["end_ns"])]))}
               for window in windows]
    groups = {}
    for label in sorted({str(w.get(args.group_field, "unlabelled")) for w in windows}):
        members = [w for w in windows if str(w.get(args.group_field, "unlabelled")) == label]
        union = interval_union(members)
        groups[label] = {"window_ids": [w["id"] for w in members], "window_count": len(members),
                         "union_intervals_ns": union, "union_wall_ms": sum(b - a for a, b in union) / 1_000_000,
                         "sample_weights": summarize(select(samples, union))}
    all_union = interval_union(windows)
    union_samples = select(samples, all_union)
    return {"schema_version": 1, "target_pid": args.pid, "time_origin": "trace_start",
            "source_units": "Raw time-profile time and weight are interpreted as nanoseconds; windows are rounded to integer nanoseconds",
            "inputs": {"time_profile": file_identity(args.time_profile), "windows": file_identity(args.windows),
                       "analyzer": file_identity(Path(__file__))},
            "export_receipt": receipt, "profile": profile,
            "window_selection": {"input_count": len(input_windows), "selected_count": len(windows),
                                 "excluded_by_user_count": sum(w.get("excluded_by_user") is True for w in input_windows),
                                 "window_name": args.window_name, "eligible_only": args.eligible_only,
                                 "group_field": args.group_field},
            "thread_classification": {"main_tid": args.main_tid, "main_thread_regex": args.main_thread_regex,
                                      "async_thread_regex": args.async_thread_regex,
                                      "target_running_threads": dict(collections.Counter(s["thread"] for s in samples))},
            "whole_trace": summarize(samples), "windows": results, "groups": groups,
            "all_windows_union": {"intervals_ns": all_union, "sample_weights": summarize(union_samples),
                                  "target_running_rows_outside": len(samples) - len(union_samples)},
            "limitations": [
                "Running weights are sampled estimates, not scheduler-certified continuous CPU time, wall latency or a frame/FPS metric.",
                "Half-open windows assign a sample's full weight by timestamp; weights are not clipped into scheduler spans and may exceed tiny window duration through quantization.",
                "Handoff categories are inclusive and overlap. A stack containing a lock or kernel leaf does not establish lock-wait duration or contention.",
                "Main, AsyncRenderer and other partition samples; supplied groups may overlap. Each group's union counts a sample once, but different groups must not be summed if their windows overlap.",
                "Window routes, setup exclusions and fast/slow labels are supplied externally; this tool does not infer them from CPU work or validate their presentation attribution.",
                "Window and CPU clocks must be from the same trace. Their temporal association does not map each sampled stack to a later displayed buffer.",
                "No runloop nesting reconstruction, phase-count assertion, outside-envelope weight assumption or fixed 1 ms sample-weight assumption is made.",
                "Absent target PID and incomplete XML/receipts are errors. Zero matched window rows mean no observed Running samples in that window, not proof that no work occurred.",
                "Missing symbols, deduplicated frames and thread naming differences limit classification; inspect coverage and supplied classifier settings."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--time-profile", type=Path, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--windows", type=Path, required=True)
    parser.add_argument("--window-name", help="Select one exact window_name from a presentation analyzer result")
    parser.add_argument("--eligible-only", action="store_true", help="Require eligible_for_comparison=true; explicit user exclusions are always omitted")
    parser.add_argument("--group-field", default="group", help="Metadata field to group selected windows; e.g. cadence_band")
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--main-tid", type=int)
    parser.add_argument("--main-thread-regex", default=r"^Main Thread(?: |$)")
    parser.add_argument("--async-thread-regex", default=r"SwiftUI\.AsyncRenderer")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.pid <= 0:
            raise ValueError("--pid must be positive")
        if args.output.exists():
            raise ValueError("Output already exists; choose a new path to preserve evidence")
        report = analyze(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    except (ValueError, InvalidOperation, ET.ParseError, OSError, KeyError, TypeError) as error:
        parser.exit(2, "ERROR: " + str(error) + "\n")
    print(json.dumps({"target_pid": args.pid, "window_count": len(report["windows"]),
                      "groups": {k: {"windows": v["window_count"], "main_ms": v["sample_weights"]["main"]["sampled_running_ms"],
                                     "async_renderer_ms": v["sample_weights"]["async_renderer"]["sampled_running_ms"]}
                                 for k, v in report["groups"].items()}, "output": str(args.output)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
