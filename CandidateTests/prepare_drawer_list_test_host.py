"""Host the actual baseline and candidate drawer in one isolated simulator app.

Only copied RootView gains counters/private factories; copied AppModel gains an
unread test setter. Product code has no test switches.
"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
baseline_commit = "7a7f768"
refresh = "--refresh" in sys.argv[2:]
if refresh:
    assert out.is_relative_to(root / "work/verification/drawer-list")
    assert (out / "source-provenance.json").is_file()
else:
    subprocess.run(["/usr/bin/python3", str(root / "CandidateTests/prepare_conversation_lookup_test_host.py"), str(out)], check=True)
baseline = subprocess.check_output(["git", "show", baseline_commit + ":Mocca/RootView.swift"], cwd=root, text=True)
original = (root / "Mocca/RootView.swift").read_text()

def drawer(text):
    start = text.index("private struct ConversationDrawerContent:")
    end = text.index("\nprivate struct ConversationDateGroup:", start)
    # Candidate appends the selection leaf and date context after the drawer.
    end = min(end, text.find("\n/// Selection changes belong", start) if "\n/// Selection changes belong" in text[start:end] else end)
    return text[start:end]

def instrument(text, key):
    for marker, name in [
        ("    private var sourceConversations: [Conversation] {\n", "source"),
        ("    private var filteredConversations: [Conversation] {\n", "filter"),
        ("    private func conversationDateGroups(for conversations: [Conversation]) -> [ConversationDateGroup] {\n", "group"),
    ]:
        assert text.count(marker) == 1
        text = text.replace(marker, marker + f'        DrawerListProbe.count("{key}.{name}")\n')
    marker = "    var body: some View {\n"
    assert text.count(marker) == 1
    text = text.replace(marker, marker + f'        let _ = DrawerListProbe.count("{key}.body")\n')
    start = text.index("    private func conversationDateGroups(")
    end = text.index("    var body: some View", start)
    region = text[start:end].replace("        return grouped.keys.sorted", "        let result = grouped.keys.sorted")
    pos = region.rindex("    }")
    region = region[:pos] + f'''        DrawerListProbe.groups["{key}"] = result.map {{ ($0.day, $0.conversations.map(\\.id)) }}
        return result
''' + region[pos:]
    text = text[:start] + region + text[end:]
    for name, identity in [("conversationRow", "conversation.id"), ("contentSearchResultRow", "result.conversation.id")]:
        start = text.index("    private func " + name + "(")
        pos = text.index("        Button {", start)
        text = text[:pos] + f'''        DrawerListProbe.rows["{key}", default: [:]][{identity}] = isSelected
        DrawerListProbe.count("{key}.rows")
        return ''' + text[pos:].lstrip()
    return text

old_drawer = drawer(baseline)
candidate_drawer = drawer(original)
combined = original.replace(candidate_drawer, instrument(candidate_drawer, "candidate"), 1)
combined += "\n" + instrument(old_drawer, "baseline").replace("ConversationDrawerContent", "BaselineConversationDrawerContent")
hooks = (root / "CandidateTests/DrawerListTestHooks.swift").read_text()
combined += "\n" + hooks
factory = '''
extension TYPE {
    static func listTestView(_ options: DrawerListTestOptions) -> Self {
        var view = Self(width: 340, safeAreaInsets: EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0),
                        topReturnCoordinator: DrawerListTopReturnCoordinator(),
                        onRequestClose: {}, onRequestCloseAfterConversationReady: { _ in })
        view._query = State(initialValue: options.query)
        view._searchScope = State(initialValue: options.contentSearch ? .content : .title)
        view._isSearchModeActive = State(initialValue: !options.query.isEmpty)
        view._groupChatMode = State(initialValue: options.group)
        DATE_CONTEXT
        return view
    }
}
'''
combined += factory.replace("TYPE", "BaselineConversationDrawerContent").replace("DATE_CONTEXT", "")
combined += factory.replace("TYPE", "ConversationDrawerContent").replace("DATE_CONTEXT", "if let now = options.dateNow { view._dateContext = State(initialValue: DrawerDateContext(now: now, calendar: options.calendar)) }")
folder = out / "Mocca"
if not refresh:
    assert folder.is_symlink()
    folder.unlink()
    folder.mkdir()
for child in (root / "Mocca").iterdir():
    if child.name == "RootView.swift":
        (folder / child.name).write_text(combined)
    elif child.name == "AppModel.swift":
        if (folder / child.name).is_symlink():
            (folder / child.name).unlink()
        (folder / child.name).write_text(child.read_text() + '''
extension AppModel {
    func drawerTestUnread(_ ids: Set<UUID>) { unreadReplyConversationIDs = ids }
}
''')
    elif child.name in ["Assets.xcassets", "AppIcon.icon"]:
        if not refresh:
            shutil.copytree(child, folder / child.name)
    else:
        if not refresh:
            (folder / child.name).symlink_to(child, target_is_directory=child.is_dir())
project = out / "Mocca.xcodeproj/project.pbxproj"
project.write_text(project.read_text().replace("com.uuzsama450.mocca.migration", "com.mocca.drawer-list.qa"))
shutil.copyfile(root / "CandidateTests/DrawerListSelectionTests.swift", out / "Slice1UITests/Slice1UITests.swift")
(out / "source-provenance.json").write_text(json.dumps({
    "baselineCommit": baseline_commit,
    "baselineRootSHA256": hashlib.sha256(baseline.encode()).hexdigest(),
    "candidateRootSHA256": hashlib.sha256(original.encode()).hexdigest(),
    "candidateAppModelSHA256": hashlib.sha256((root / "Mocca/AppModel.swift").read_bytes()).hexdigest(),
    "instrumentedRootSHA256": hashlib.sha256(combined.encode()).hexdigest(),
    "testsSHA256": hashlib.sha256((root / "CandidateTests/DrawerListSelectionTests.swift").read_bytes()).hexdigest(),
    "scope": __doc__, "phoneAction": False,
}, indent=2) + "\n")
print(out)
