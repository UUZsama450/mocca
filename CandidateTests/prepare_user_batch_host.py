"""Extend the existing isolated segmentation host; hooks never ship in the app."""
from pathlib import Path
import subprocess, sys
root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
subprocess.run([sys.executable, str(root/'CandidateTests/prepare_reply_segmentation_host.py'), str(out)], check=True)
p = out/'Mocca/AppModel.swift'
s = p.read_text().replace('    private(set) var userBatchSendTokens:',
    '    var batchQACapturesRequests = false\n    var batchQARequests: [[ChatMessage]] = []\n    private(set) var userBatchSendTokens:', 1)
start = s.index('    private func startAssistantStream(')
pos = s.index('        let reactionContext', start)
s = s[:pos] + '''        if batchQACapturesRequests {
            batchQACapture(requestMessages, placeholder: preparedInitialAssistantMessage, chat: conversationID,
                provider: provider, selection: selection, assistant: assistant)
            return
        }
''' + s[pos:]
s = s.replace('            preferences.chatSegmentedReply = !arguments.contains("-segmentsOff")',
    '            preferences.batchUserMessages = arguments.contains("-batchSendFixture")\n            preferences.showUserAvatar = true\n            preferences.chatSegmentedReply = !arguments.contains("-segmentsOff")', 1)
p.write_text(s + '\n' + (root/'CandidateTests/UserBatchTestHooks.swift').read_text())
p = out/'Slice1UITests/Slice1UITests.swift'
s = p.read_text() + '\n' + (root/'CandidateTests/UserBatchTests.swift').read_text()
s += '\n' + (root/'CandidateTests/GroupChatLookupTests.swift').read_text().replace('com.mocca.lab.groupreusehost', 'com.mocca.lab.replysegments')
p.write_text(s)
p = out/'Mocca/ConversationStore.swift'
p.write_text((root/'Mocca/ConversationStore.swift').read_text() +
    '\nextension ConversationStore { func reviewFailCommits(_ enabled: Bool) { records.failBeforeCommitForTesting = enabled } }\n')
