#!/usr/bin/python3
"""Read four tables from a saved trace, serially; never interacts with the phone."""
import argparse
import datetime
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--trace", required=True, type=Path)
parser.add_argument("--pid", required=True, type=int)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
assert args.trace.is_dir(), "Expected a saved .trace directory"
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
env = os.environ.copy()
env["NSZombieEnabled"] = "YES"  # Local offline-reader crash workaround only.


def export(name, selector):
    destination = out / f"{name}.xml"
    assert not destination.exists(), "Do not overwrite previous evidence"
    assert shutil.disk_usage(out).free > 3 * 2**30, "Stop exports below 3 GiB free"
    command = ["xcrun", "xctrace", "export", "--input", str(args.trace.resolve()),
               *selector, "--output", str(destination)]
    receipt = {"command": command, "reader_environment_override": {"NSZombieEnabled": "YES"},
               "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    started = time.monotonic()
    with (out / f"{name}.log").open("wb") as log:
        proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                env=env, start_new_session=True)
        try:
            code = proc.wait(timeout=150)
            receipt["timed_out"] = False
        except subprocess.TimeoutExpired:
            receipt["timed_out"] = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                code = proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                code = proc.wait()
    receipt.update(exit_code=code, elapsed_seconds=time.monotonic() - started,
                   bytes=destination.stat().st_size if destination.exists() else 0,
                   complete_xml_parse=False)
    if code == 0:
        try:
            rows, schemas = 0, []
            for _, element in ET.iterparse(destination, events=("end",)):
                if element.tag == "schema":
                    schemas.append(element.get("name"))
                if element.tag == "row":
                    rows += 1
                    element.clear()
            assert name == "toc" or name in schemas, (name, schemas)
            receipt.update(complete_xml_parse=True, rows=rows, schemas=schemas)
        except Exception as error:
            receipt["parse_error"] = repr(error)
    (out / f"{name}-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"table": name, "exit_code": code,
                      "complete_xml_parse": receipt["complete_xml_parse"],
                      "rows": receipt.get("rows")}), flush=True)
    return receipt["complete_xml_parse"]


assert export("toc", ["--toc"]), "TOC export failed"
root = ET.parse(out / "toc.xml").getroot()
runs = [run for run in root.findall("run")
        if run.find("./info/target/process") is not None
        and run.find("./info/target/process").get("pid") == str(args.pid)]
assert len(runs) == 1, "PID must identify exactly one recorded run"
run = runs[0]
available = {table.get("schema") for table in run.findall("./data/table")}
failed = []
for schema in ["hitches-updates", "display-surface-swap", "time-profile", "runloop-events"]:
    assert schema in available, f"Missing table: {schema}"
    xpath = f'/trace-toc/run[@number="{run.get("number")}"]/data/table[@schema="{schema}"]'
    if not export(schema, ["--xpath", xpath]):
        failed.append(schema)
raise SystemExit(1 if failed else 0)
