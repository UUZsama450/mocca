"""Create an isolated hosted XCTest project; never modifies the product project or a device."""
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=False)
for child in root.iterdir():
    if child.is_dir() and child.name not in {"work", ".git", "Mocca.xcodeproj"}:
        (output / child.name).symlink_to(child, target_is_directory=True)
shutil.copytree(root / "Mocca.xcodeproj", output / "Mocca.xcodeproj",
                ignore=shutil.ignore_patterns("xcuserdata", "project.xcworkspace"))
subprocess.run(["git", "apply", str(root / "CandidateTests/StorageSaveTestHost.patch")],
               cwd=output, check=True)
schemes = output / "Mocca.xcodeproj/xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / "CandidateTests/StorageSaveValidation.xcscheme", schemes / "Slice1Validation.xcscheme")
(output / "Slice1UITests").mkdir()
baseline = subprocess.check_output(["git", "show", "02f40f4:Mocca/ConversationStore.swift"], cwd=root, text=True)
baseline = baseline[baseline.index("struct ConversationStore {"):].replace("ConversationStore", "BaselineConversationStore")
# Keep shared model/error type names; only rename the historical store itself.
baseline = baseline.replace("BaselineConversationStoreError", "ConversationStoreError")
(output / "Slice1UITests/Slice1UITests.swift").write_text(
    (root / "CandidateTests/StorageSaveTests.swift").read_text() + "\n" + baseline
)
print(output)
