"""Add the existing hosted-XCTest target to a disposable copy of this project."""
from pathlib import Path
import re
import shutil
import sys

root = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=False)
for child in root.iterdir():
    if child.is_dir() and child.name not in {"work", ".git", "Mocca.xcodeproj"}:
        (output / child.name).symlink_to(child, target_is_directory=True)
shutil.copytree(root / "Mocca.xcodeproj", output / "Mocca.xcodeproj", ignore=shutil.ignore_patterns("xcuserdata"))
project = output / "Mocca.xcodeproj/project.pbxproj"
text = project.read_text()
patch = (root / "CandidateTests/StorageSaveTestHost.patch").read_text()
for hunk in re.split(r"^@@.*@@.*\n", patch, flags=re.M)[1:]:
    lines = hunk.splitlines(keepends=True)
    old = "".join(line[1:] for line in lines if line.startswith((" ", "-")))
    new = "".join(line[1:] for line in lines if line.startswith((" ", "+")))
    # Later shipping projects insert package sections between these sections.
    prefix = "/* End PBXTargetDependency section */\n\n"
    if old.startswith(prefix) and old not in text:
        old = old[len(prefix):]
        new = new[len(prefix):]
    if text.count(old) == 0:
        # Newly declared shipping files may precede the historical first entry.
        section = next((line for line in lines if line.startswith(" /* Begin PBX") and "section */" in line), None)
        additions = "".join(line[1:] for line in lines if line.startswith("+"))
        assert section is not None and additions, "Unreviewed historical context drift"
        anchor = section[1:]
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + additions, 1)
    else:
        assert text.count(old) == 1, "Ambiguous historical context"
        text = text.replace(old, new, 1)
project.write_text(text)
schemes = output / "Mocca.xcodeproj/xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / "CandidateTests/StorageSaveValidation.xcscheme", schemes / "Slice1Validation.xcscheme")
(output / "Slice1UITests").mkdir()
shutil.copyfile(root / "CandidateTests/ConversationLookupTests.swift", output / "Slice1UITests/Slice1UITests.swift")
print(output)
