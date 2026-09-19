"""Build the full AppModel with private, test-only storage fault controls."""
from pathlib import Path
import subprocess,sys,shutil
root=Path(__file__).resolve().parents[1];out=Path(sys.argv[1]).resolve()
subprocess.run(['/usr/bin/python3',str(root/'CandidateTests/prepare_conversation_lookup_test_host.py'),str(out)],check=True)
folder=out/'Mocca';folder.unlink();folder.mkdir()
for child in (root/'Mocca').iterdir():
    if child.name in ('AppModel.swift','ConversationStore.swift'):
        text=child.read_text()
        if child.name=='AppModel.swift': text+='\n'+(root/'CandidateTests/ReviewCorrectnessTestHooks.swift').read_text()
        else: text+='\nextension ConversationStore { func reviewFailCommits(_ enabled: Bool) { records.failBeforeCommitForTesting = enabled } }\n'
        (folder/child.name).write_text(text)
    elif child.name in ('Assets.xcassets','AppIcon.icon'):shutil.copytree(child,folder/child.name)
    else:(folder/child.name).symlink_to(child,target_is_directory=child.is_dir())
project=out/'Mocca.xcodeproj/project.pbxproj'
project.write_text(project.read_text().replace('com.uuzsama450.mocca.migration','com.uuzsama450.mocca.review5047qa'))
(out/'Slice1UITests/Slice1UITests.swift').write_text((root/'CandidateTests/ReviewCorrectnessTests.swift').read_text())
