"""Exercise real navigation/send/save with synthetic data and no provider requests."""
from pathlib import Path
import subprocess, sys
root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
subprocess.run(['/usr/bin/python3', str(root/'CandidateTests/prepare_storage_noop_host.py'), str(out)], check=True)
p = out/'Slice1UITests/Slice1UITests.swift'
p.write_text(p.read_text() + '\n' + (root/'CandidateTests/FavoriteAssistantOwnershipTests.swift').read_text())
