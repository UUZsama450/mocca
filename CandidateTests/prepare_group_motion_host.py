"""Add actual group-control UI and frame capture to the isolated prompt QA host."""
from pathlib import Path
import plistlib, subprocess, sys
root = Path(__file__).resolve().parents[1]
host = Path(sys.argv[1]).resolve()
subprocess.run([sys.executable, str(root / 'CandidateTests/prepare_prompt_motion_host.py'), str(host)], check=True)
entry = host / 'Mocca/MoccaApp.swift'
source = entry.read_text()
needle = '                if ProcessInfo.processInfo.arguments.contains("-searchPromptUITest") {'
assert source.count(needle) == 1
source = source.replace(needle, '''                if ProcessInfo.processInfo.arguments.contains("-groupComposerUITest") {
                    GroupComposerTestRoot()
                } else if ProcessInfo.processInfo.arguments.contains("-searchPromptUITest") {''')
source = source.replace('        if ProcessInfo.processInfo.arguments.contains("-searchPromptUITest") { return false }', '        if ProcessInfo.processInfo.arguments.contains("-searchPromptUITest") || ProcessInfo.processInfo.arguments.contains("-groupComposerUITest") { return false }')
entry.write_text(source + '\n' + (root / 'CandidateTests/GroupComposerMotionFixture.swift').read_text())
ui = host / 'QAUI.swift'
ui.write_text((root / 'CandidateTests/SearchToolPromptUITests.swift').read_text() + '\n' + (root / 'CandidateTests/GroupComposerMotionUITests.swift').read_text())
project = host / 'Mocca.xcodeproj/project.pbxproj'
data = plistlib.loads(project.read_bytes())
for item in data['objects'].values():
    if item.get('path') == str(root / 'CandidateTests/SearchToolPromptUITests.swift'):
        item['path'] = str(ui)
project.write_bytes(plistlib.dumps(data, sort_keys=False))
print(host)
