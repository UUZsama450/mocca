#!/usr/bin/python3
"""Explicit, bounded physical-device capture; never launches or installs an app.

Call only after checking the device/PID and coordinating the user's manual input.
This adds no display link or app-side instrumentation. Export/analysis is offline.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
parser.add_argument("--pid", required=True, type=int)
parser.add_argument("--build", required=True)
parser.add_argument("--phase", required=True, choices=["a1", "b", "a2"])
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--seconds", type=int, default=45, choices=range(30, 61))
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
cmd = ["xcrun", "xctrace", "record", "--template", "Animation Hitches",
       "--device", args.device, "--attach", str(args.pid),
       "--time-limit", f"{args.seconds}s", "--output", str(out / "tools.trace")]
env = os.environ.copy()
env.pop("NSZombieEnabled", None)  # Reader-only workaround must not affect capture.
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
metadata = {"command": cmd, "pid": args.pid, "build": args.build,
            "phase": args.phase, "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "phone_actions": "manual; record actual coverage and feedback separately"}
(out / "record-command.json").write_text(json.dumps(metadata, indent=2) + "\n")
started = time.monotonic()
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, bufsize=1, env=env, start_new_session=True)
(out / "recorder-pid.json").write_text(json.dumps({"pid": proc.pid}) + "\n")

def stop_recorder(signum, _frame):
    # One normal stop request; do not kill a recorder that is saving its trace.
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGINT)

signal.signal(signal.SIGINT, stop_recorder)
signal.signal(signal.SIGTERM, stop_recorder)
with (out / "record.log").open("w") as log, (out / "record-events.jsonl").open("w") as events:
    for line in proc.stdout:
        log.write(line)
        log.flush()
        events.write(json.dumps({"wall_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                 "elapsed": time.monotonic() - started, "line": line.strip()}) + "\n")
        events.flush()
        print(line, end="", flush=True)
code = proc.wait()
result = {"exit_code": code, "elapsed_including_save_seconds": time.monotonic() - started,
          "trace_exists": (out / "tools.trace").exists(),
          "ended_utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}
(out / "record-result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result), flush=True)
raise SystemExit(code)
