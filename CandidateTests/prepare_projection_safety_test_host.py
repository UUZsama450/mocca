"""Prepare actual AppModel comparison tests in the disposable storage test host."""
from pathlib import Path
import shutil, subprocess

root = Path(__file__).resolve().parents[1]
baseline = subprocess.check_output(["git", "show", "b4a4207:Mocca/AppModel.swift"], cwd=root, text=True)
candidate = (root / "Mocca/AppModel.swift").read_text()

def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

host = root / "work/test-host"
folder = host / "Mocca"
if folder.is_symlink():
    folder.unlink()
    folder.mkdir()
    for child in (root / "Mocca").iterdir():
        if child.name != "AppModel.swift": (folder / child.name).symlink_to(child, target_is_directory=child.is_dir())
for name in ("AppIcon.icon", "Assets.xcassets"):
    resource = folder / name
    if resource.is_symlink():
        resource.unlink()
        shutil.copytree(root / "Mocca" / name, resource)
reference = block(baseline, "    private func appendMessagePreservingLatestWindow(").replace(
    "appendMessagePreservingLatestWindow", "baselineAppendMessagePreservingLatestWindow", 1)
(folder / "AppModel.swift").write_text(candidate + "\n" + (root / "CandidateTests/ProjectionTestHooks.swift").read_text()
    + "\nextension AppModel {\n" + reference + "\n}\n")
(host / "Slice1UITests/Slice1UITests.swift").write_text(
    (root / "CandidateTests/RecordStorageTests.swift").read_text() + "\n" + (root / "CandidateTests/ProjectionSafetyTests.swift").read_text())

print("Prepared hosted AppModel comparison tests")
