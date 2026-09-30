"""Isolated full-product XCTest host; instrumentation and private hooks stay in its copies."""
from pathlib import Path
import hashlib, json, shutil, subprocess, sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
refresh = '--refresh' in sys.argv[2:]
if refresh:
    assert out.is_relative_to(root / 'work/verification/completion-work')
    assert (out / 'source-provenance.json').is_file()
else:
    subprocess.run(['/usr/bin/python3', str(root / 'CandidateTests/prepare_conversation_lookup_test_host.py'), str(out)], check=True)
folder = out / 'Mocca'
if not refresh:
    assert folder.is_symlink()
    folder.unlink()
    folder.mkdir()
originals = {}
for child in (root / 'Mocca').iterdir():
    if child.name in ['AppModel.swift', 'ConversationStore.swift', 'GenerationFeatures.swift']:
        text = child.read_text()
        originals[child.name] = hashlib.sha256(child.read_bytes()).hexdigest()
        if child.name == 'AppModel.swift':
            marker = '        let identity = ConversationSaveIdentity.capture(request.snapshot)\n'
            assert text.count(marker) == 1
            text = text.replace(marker, '''        let captureStarted = CFAbsoluteTimeGetCurrent()
''' + marker + '''        CompletionWorkProbe.shared.record("identityCaptures")
        if Thread.isMainThread { CompletionWorkProbe.shared.record("mainIdentityCaptures") }
        CompletionWorkProbe.shared.record("identityMilliseconds", (CFAbsoluteTimeGetCurrent() - captureStarted) * 1000)
''')
            marker = '            prepared.executor.enqueueSave(prepared.request) { outcome in\n'
            assert text.count(marker) == 1
            text = text.replace(marker, '            CompletionWorkProbe.shared.record("submissions")\n' + marker)
            # Exercise the actual newly-awaiting post-image journal call and
            # cancellation cleanup without issuing an AI/provider request.
            start = text.index('        _ = await IOSBackgroundGenerationManager.shared.stageCompletedMessageWithoutBlockingMain(')
            end = text.index('        let notificationBody = ', start)
            tail = text[start:end]
            text += '\n' + (root / 'CandidateTests/CompletionWorkTestHooks.swift').read_text()
            text += '\nextension AppModel {\n    func completionRestage(_ completed: ChatMessage) async throws {\n'
            text += '        let assistantMessage = completed\n' + tail + '    }\n}\n'
        elif child.name == 'ConversationStore.swift':
            marker = '        private var lastCompletedMessage: ChatMessage?\n'
            assert text.count(marker) == 1
            text = text.replace(marker, marker + '''        private var completionFailNextWriteForTesting = false
        private var completionWriteGateForTesting: CompletionWorkGate?
''')
            marker = '            let request = CompletionRequest(message)\n'
            assert text.count(marker) == 1
            text = text.replace(marker, '            CompletionWorkProbe.shared.record("journalSubmissions")\n' + marker)
            start = text.index('        private func writeRecord(')
            end = text.index('    static func makeWriter(', start)
            region = text[start:end]
            marker = '            try fileHandle.truncate(atOffset: 0)\n'
            assert region.count(marker) == 1
            region = region.replace(marker, marker + '''            if let gate = completionWriteGateForTesting {
                completionWriteGateForTesting = nil
                gate.entered.signal(); gate.release.wait()
            }
            if completionFailNextWriteForTesting {
                completionFailNextWriteForTesting = false
                throw CocoaError(.fileWriteOutOfSpace)
            }
''')
            marker = '            _ = try fileHandle.seekToEnd()\n'
            assert region.count(marker) == 1
            region = region.replace(marker, marker + '''            CompletionWorkProbe.shared.record("journalWrites")
            if Thread.isMainThread { CompletionWorkProbe.shared.record("mainJournalWrites") }
''')
            text = text[:start] + region + text[end:]
            text += '''
extension ConversationStore {
    func completionFailCommits(_ value: Bool) { records.failBeforeCommitForTesting = value }
}
extension PendingGenerationCompletionJournal.Writer {
    func completionFailNextWrite() {
        queue.sync { completionFailNextWriteForTesting = true }
    }
    func completionHoldNextTruncate(_ gate: CompletionWorkGate) {
        queue.sync { completionWriteGateForTesting = gate }
    }
    func completionHoldQueue(_ gate: CompletionWorkGate) {
        queue.async { gate.entered.signal(); gate.release.wait() }
    }
}
'''
        else:
            text += '\n' + (root / 'CandidateTests/CompletionJournalTestHooks.swift').read_text()
        (folder / child.name).write_text(text)
    elif child.name in ['Assets.xcassets', 'AppIcon.icon']:
        if not refresh:
            shutil.copytree(child, folder / child.name)
    else:
        if not refresh:
            (folder / child.name).symlink_to(child, target_is_directory=child.is_dir())
project = out / 'Mocca.xcodeproj/project.pbxproj'
project.write_text(project.read_text().replace('com.uuzsama450.mocca.migration', 'com.mocca.completion-work.qa'))
tests = ['CompletionWorkTests.swift', 'StorageNoopRemovalTests.swift', 'RecordStorageTests.swift']
(out / 'Slice1UITests/Slice1UITests.swift').write_text('\n'.join((root / 'CandidateTests' / name).read_text() for name in tests))
(out / 'source-provenance.json').write_text(json.dumps({'productCopies': originals, 'tests': tests,
    'scope': __doc__, 'phoneAction': False}, indent=2) + '\n')
print(out)
