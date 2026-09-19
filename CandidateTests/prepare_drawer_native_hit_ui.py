"""Generate an isolated UI test runner; does not modify the shipping project."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
generator = (root / 'CandidateTests/make_entry_ui_project.py').read_text()
generator = generator.replace('work/native-entry-qa', 'work/verification/drawer-native-hit-routing-5038/ui')
generator = generator.replace('NativeConversationEntryUITests.swift', 'DrawerNativeHitRoutingUITests.swift')
generator = generator.replace('BottomEntryUI', 'DrawerNativeHitUI')
generator = generator.replace('com.mocca.local.native-entry-ui', 'com.mocca.local.drawer-hit5038-ui')
exec(compile(generator, __file__, 'exec'), {'__file__': __file__})
