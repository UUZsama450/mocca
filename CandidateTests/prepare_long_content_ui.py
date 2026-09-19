"""Generate the isolated long-content UI runner without changing the app project."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
combined = root / 'work/verification/long-content-preparation-5043/ui/CombinedUITests.swift'
combined.parent.mkdir(parents=True, exist_ok=True)
combined.write_text((root / 'CandidateTests/FixtureProviderSetupUITests.swift').read_text()
                    + '\n' + (root / 'CandidateTests/LongContentEntryUITests.swift').read_text()
                    + '\n' + (root / 'CandidateTests/SendHandoffBoundaryUITests.swift').read_text())
generator = (root / 'CandidateTests/make_entry_ui_project.py').read_text()
generator = generator.replace('work/native-entry-qa', 'work/verification/long-content-preparation-5043/ui')
generator = generator.replace('CandidateTests/NativeConversationEntryUITests.swift',
                              'work/verification/long-content-preparation-5043/ui/CombinedUITests.swift')
generator = generator.replace('BottomEntryUI', 'LongContentUI')
generator = generator.replace('com.mocca.local.native-entry-ui', 'com.mocca.local.long-content5043-ui')
exec(compile(generator, __file__, 'exec'), {'__file__': __file__})
