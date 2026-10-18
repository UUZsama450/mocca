"""Reuse the existing disposable full-app XCTest host; never touch phone data."""
from pathlib import Path
import subprocess,sys,re
root=Path(__file__).resolve().parents[1];out=Path(sys.argv[1]).resolve()
if not out.exists():
 subprocess.run([sys.executable,str(root/'CandidateTests/prepare_review_correctness_host.py'),str(out)],check=True)
else:
 assert 'com.mocca.lab.replysegments' in (out/'Mocca.xcodeproj/project.pbxproj').read_text()
p=out/'Mocca/AppModel.swift';s=(root/'Mocca/AppModel.swift').read_text()+'\n'+(root/'CandidateTests/ReviewCorrectnessTestHooks.swift').read_text()
s=s.replace('static let testBundleID = "com.mocca.lab.streamheight5157"','static let testBundleID = "com.mocca.lab.replysegments"')
# The fixture still uses the production composer, provider stream, and renderer.
anchor='        conversationMessageStore[fixtureID] = fixture.messages'
assert s.count(anchor)==1
s=s.replace(anchor,anchor+'''
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-replySegmentsFixture") {
            preferences.chatSegmentedReply = !arguments.contains("-segmentsOff")
            preferences.replySegmentLimit = arguments.contains("-segmentsUnlimited") ? 0 : 3
            preferences.autoGenerateTitle = false
            preferences.showModelIcon = true
            preferences.showModelName = false
            preferences.showModelTimestamp = false
            preferences.assistantChatBubbleStyle = arguments.contains("-segmentsPlain") ? .defaultStyle : .appleGlass
            preferences.assistantChatBubbleOpacity = arguments.contains("-segmentsPlain") ? 0.11 : 1
            if arguments.contains("-groupSegmentsFixture") {
                let secondID = UUID(uuidString: "50770000-0000-4000-9000-000000000002")!
                let first = AssistantProfile(id: currentAssistantID, name: "群聊甲", chatModel: selectedModel)
                let second = AssistantProfile(id: secondID, name: "群聊乙", chatModel: selectedModel)
                assistants = [first, second]
                conversations[0].groupAssistantIDs = [first.id.uuidString, second.id.uuidString]
                preferences.groupChatAutoGenerateTitle = false
                preferences.groupChatForceAssistantBubble = !arguments.contains("-segmentsPlain")
                preferences.groupChatBubbleStyle = .defaultStyle
                preferences.groupChatBubbleOpacity = 0.25
                preferences.groupAssistantBubbleColors = [first.id.uuidString: 0xffef8eb7, second.id.uuidString: 0xff6aa9ef]
                groupReplyRoundsByConversation[fixtureID] = 0
                if let row = conversationMessageStore[fixtureID]?.firstIndex(where: { $0.role == .assistant }) {
                    conversationMessageStore[fixtureID]![row].text = "旧第一句。旧第二句！\\n\\n旧第二段。"
                }
            }
        }
''')
for name in ['StreamingRecoveryModelHooks.swift','ReplySegmentationTestHooks.swift']:
 s+='\n'+(root/'CandidateTests'/name).read_text()
p.write_text(s)
p=out/'Mocca.xcodeproj/project.pbxproj';s=p.read_text().replace('com.uuzsama450.mocca.review5047qa','com.mocca.lab.replysegments');p.write_text(s)
(out/'Slice1UITests/Slice1UITests.swift').write_text((root/'CandidateTests/ReplySegmentationTests.swift').read_text())
print(out)

# Accessibility-only segment IDs in the disposable host for live UI assertions.
p=out/'Mocca/RootView.swift'
if p.is_symlink(): p.unlink()
source=(root/'Mocca/RootView.swift').read_text()
def annotate_segment(match):
    indent = match.group(1)
    return match.group(0) + '\n' + indent + '.accessibilityIdentifier("replySegment.\\(message.id).\\(segmentIndex)")'
source, count = re.subn(r'(?m)^([ ]+)segmentCount: segments.count\n[ ]+\)', annotate_segment, source)
assert count == 2
p.write_text(source)
