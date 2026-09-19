"""Prepare a disposable hosted test project without modifying the shipping project."""
from pathlib import Path
import shutil, subprocess, sys
root = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=False)
for child in root.iterdir():
    if child.is_dir() and child.name not in {"work", ".git", "Mocca.xcodeproj"}:
        (output / child.name).symlink_to(child, target_is_directory=True)
shutil.copytree(root / "Mocca.xcodeproj", output / "Mocca.xcodeproj", ignore=shutil.ignore_patterns("xcuserdata", "project.xcworkspace"))
subprocess.run(["git", "apply", str(root / "CandidateTests/StorageSaveTestHost.patch")], cwd=output, check=True)
schemes = output / "Mocca.xcodeproj/xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / "CandidateTests/StorageSaveValidation.xcscheme", schemes / "Slice1Validation.xcscheme")
(output / "Slice1UITests").mkdir()
shutil.copyfile(root / "CandidateTests/RecordStorageTests.swift", output / "Slice1UITests/Slice1UITests.swift")
print(output)
