"""Synthetic full-model host: suppress only network launch; preserve send/save code."""
from pathlib import Path
import subprocess, sys
root=Path(__file__).resolve().parents[1]
out=Path(sys.argv[1]).resolve()
subprocess.run(['/usr/bin/python3',str(root/'CandidateTests/prepare_review_correctness_host.py'),str(out)],check=True)
p=out/'Mocca/AppModel.swift';s=p.read_text()
# Match a mature store: the independent backup already contains the history.
s=s.replace('        try store.save(snapshot)\n', '        try store.save(snapshot)\n        try store.save(snapshot)\n', 1)
# Real cold init adopts the loaded arrays; avoid keeping an equal but separately
# built fixture graph through replaceAll's equality no-op.
s=s.replace('        messagesByConversation = snapshot.messagesByConversation\n', '        messagesByConversation = [:]\n', 1)
# Test-only cumulative checkpoints around the unchanged send operations.
s=s.replace('final class AppModel {','final class AppModel {\n    @ObservationIgnored var firstSendLastStages: [String: Double] = [:]',1)
start=s.index('    func sendDraft(for conversationID: UUID) -> Bool {');end=s.index('    private func ',start)
body=s[start:end]
body=body.replace('        guard selectedConversationID == conversationID else { return false }','        let traceStart = CFAbsoluteTimeGetCurrent()\n        firstSendLastStages = [:]\n        guard selectedConversationID == conversationID else { return false }',1)
for label,point in [('preparation','        performGenerateHaptic()'),('user_append','        let requestMessages = selectedContextMessages(for: conversationID)'),('context','        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {'),('staged','        guard saveImmediately() else {'),('saved','        setComposerDraftText("", for: conversationID)')]:
    assert point in body,label
    body=body.replace(point,'        firstSendLastStages["'+label+'"] = (CFAbsoluteTimeGetCurrent() - traceStart) * 1000\n'+point,1)
s=s[:start]+body+s[end:]
marker='    private func startAssistantStream('
start=s.index(marker);opening=s.index('{',start);depth=1;end=opening+1
while depth:
    depth+=(s[end]=='{')-(s[end]=='}');end+=1
s=s[:opening+1]+'\n        // Test-only: no model requests or post-send tasks.\n'+s[end-1:]
p.write_text(s+'\n'+(root/'CandidateTests/FirstSendTestHooks.swift').read_text())
(out/'Slice1UITests/Slice1UITests.swift').write_text('\n'.join((root/'CandidateTests'/f).read_text() for f in ['RecordStorageTests.swift','ReviewCorrectnessTests.swift','FirstSendTests.swift','FirstSendStorageSafetyTests.swift','LegacyGuardReuseTests.swift']))
