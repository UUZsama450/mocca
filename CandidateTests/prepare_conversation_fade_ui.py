"""Reuse the standalone UI-project generator with this candidate's tests."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
generator = (root / 'CandidateTests/make_entry_ui_project.py').read_text()
generator = generator.replace('work/native-entry-qa', 'work/verification/conversation-fade-5030/ui')
generator = generator.replace('NativeConversationEntryUITests.swift', 'ConversationSwitchFadeUITests.swift')
generator = generator.replace('BottomEntryUI', 'ConversationFadeUI')
exec(compile(generator, __file__, 'exec'), {'__file__': __file__})
