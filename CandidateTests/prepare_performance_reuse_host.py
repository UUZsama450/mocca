"""Prepare the existing observation host plus the citation/projection integration cases."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
subprocess.run(["/usr/bin/python3", str(root / "CandidateTests/prepare_message_observation_host.py"), str(out)], check=True)
tests = out / "Slice1UITests/Slice1UITests.swift"
tests.write_text(tests.read_text() + "\n" + (root / "CandidateTests/CitationProjectionReuseTests.swift").read_text())
