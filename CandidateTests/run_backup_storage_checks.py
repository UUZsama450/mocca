"""Exercise production backup deletion/statistics against disposable local files."""
from pathlib import Path
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / 'work/backup-storage'
out.mkdir(parents=True, exist_ok=True)
sources = ['Mocca/LocalBackupStore.swift', 'CandidateTests/LocalBackupStorageTests.swift']
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-O',
                *[str(root / source) for source in sources], '-o', str(out / 'storage-tests')], check=True)
result = subprocess.run([str(out / 'storage-tests')], capture_output=True, text=True)
(out / 'storage-tests.log').write_text(result.stdout + result.stderr)
assert result.returncode == 0 and 'PASS: 23 safety/storage checks' in result.stdout, result.stdout + result.stderr
(out / 'storage-tests-source-sha256.json').write_text(json.dumps({
    source: hashlib.sha256((root / source).read_bytes()).hexdigest() for source in sources
}, indent=2) + '\n')
print(result.stdout, end='')
