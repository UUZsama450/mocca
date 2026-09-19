# Offline tools-transition CPU association

`analyze_tools_transition_cpu.py` uses only the Python standard library. It reads an existing **complete** `time-profile` XML and explicit windows from the same recording. It never exports a trace, contacts a device, builds an app, reconstructs runloops or derives FPS.

```sh
/usr/bin/python3 CandidateTests/analyze_tools_transition_cpu.py \
  --time-profile /absolute/path/time-profile.xml \
  --receipt /absolute/path/time-profile-result.json \
  --pid 12345 \
  --windows /absolute/path/presentation.json \
  --window-name central_50_to_250ms \
  --eligible-only --group-field cadence_band \
  --output /absolute/path/new-cpu-analysis.json
```

The presentation analyzer's flattened `windows` array is accepted directly. `excluded_by_user: true` windows are always omitted. `--window-name` selects one width; `--eligible-only` additionally requires `eligible_for_comparison: true`. `--group-field cadence_band` uses externally supplied presentation labels, with no route/direction or fast/slow inference from CPU samples. Omitting the width filter can include overlapping window widths; group aggregates use interval unions so those do not multiply the CPU total.

A simple input may instead be a bare list, or the object below. Without presentation metadata, omit `--window-name` and `--eligible-only`; default grouping uses the `group` field.

```json
{
  "target_pid": 12345,
  "time_origin": "trace_start",
  "windows": [
    {"id": "root-open-1", "start_ns": 1000000000, "end_ns": 1200000000, "group": "control"},
    {"id": "child-open-1", "bounds_s": [2.05, 2.25], "group": "candidate"}
  ]
}
```

`start_s`/`end_s` are also accepted. Seconds are rounded to integer nanoseconds. All intervals are half-open `[start,end)`, relative to trace start; wall-clock Unix or movie PTS must be mapped by a separate, validated process. The tool checks a provided target PID, but matching PIDs alone cannot prove two inputs came from the same trace. Input paths, byte sizes and SHA-256 are recorded for provenance.

The XML schema is discovered by column mnemonics, with file-local `id/ref` resolution. Exactly one `time-profile` table is required; parse errors, unresolved references, absent target PID and failed/mismatched receipts are errors. Raw sample time and weight are interpreted as nanoseconds, with observed raw/formatted weight calibration retained. Weights need not equal 1 ms. Only rows explicitly marked `Running` for the supplied PID contribute. A supplied receipt must contain `exit_code: 0`, `xml_complete: true`, no timeout/parse error, and matching `row_count`/`bytes`. Without a receipt the report explicitly verifies XML structure only, not successful capture/export provenance.

Main classification defaults to `^Main Thread(?: |$)` in the exported thread description; use `--main-tid` when that convention does not apply. AsyncRenderer defaults to `SwiftUI\.AsyncRenderer`; `--main-thread-regex` and `--async-thread-regex` are available. Inspect `target_running_threads` and coverage before treating absent classified samples as meaningful. Main and AsyncRenderer classifiers may not overlap.

For each window and each supplied group's nonoverlapping union, output includes total/main/AsyncRenderer/other Running sample weights and inclusive handoff-path weights. A sample contributes its full exported weight when its timestamp lies in the interval. These are estimates, not continuous CPU execution spans. Inclusive handoff categories overlap and must not be added; a lock-named or kernel-leaf stack does not prove a lock-wait duration. Different groups can also overlap, so their totals must not be added without checking their intervals. No sample is linked to a later displayed buffer.

Existing output files are never overwritten. The legacy validation under `work/verification/tools-cpu-analyzer-5033/` is a fixed historical fixture, not a hard-coded production invariant. Future traces may have different PIDs, phases, sample weights, nesting or arbitrary activity outside the supplied windows; those are not rejected solely for differing from 5032.
