"""Make an isolated simulator host with production code and test-only counters."""
from pathlib import Path
import shutil,subprocess,sys
root=Path(__file__).resolve().parents[1];out=Path(sys.argv[1]).resolve()
subprocess.run(['/usr/bin/python3',str(root/'CandidateTests/prepare_conversation_lookup_test_host.py'),str(out)],check=True)
folder=out/'Mocca';folder.unlink();folder.mkdir()
for child in (root/'Mocca').iterdir():
    if child.name=='AppModel.swift':
        text=child.read_text()
        text=text.replace('final class AppModel {','final class AppModel {\n    @ObservationIgnored var observationTestProjectionBuilds = 0',1)
        needle='        var order: [String] = []\n        var grouped: [String: [(rawIndex: Int, message: ChatMessage)]] = [:]'
        assert text.count(needle)==1
        text=text.replace(needle,'        observationTestProjectionBuilds += 1\n'+needle,1)
        text+='\n'+(root/'CandidateTests/ConversationMessageObservationHooks.swift').read_text()
        (folder/child.name).write_text(text)
    elif child.name in ("Assets.xcassets", "AppIcon.icon"):
        shutil.copytree(child,folder/child.name)
    else:(folder/child.name).symlink_to(child,target_is_directory=child.is_dir())
p=out/'Mocca.xcodeproj/project.pbxproj'
p.write_text(p.read_text().replace('com.uuzsama450.mocca.migration','com.uuzsama450.mocca.observationqa'))
tests=(root/'CandidateTests/ConversationMessageObservationTests.swift').read_text()+'\n'+(root/'CandidateTests/ConversationLookupTests.swift').read_text()
(out/'Slice1UITests/Slice1UITests.swift').write_text(tests)
