"""Check production preference reducers; no UIKit layout or phone UI is simulated."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
text = (root / 'Mocca/RootView.swift').read_text()
def declaration(token):
    start = text.index(token); opening = text.index('{', start); depth = 1; i = opening + 1
    while depth:
        depth += (text[i] == '{') - (text[i] == '}'); i += 1
    return text[start:i]
source = '''import Foundation
import CoreGraphics
protocol PreferenceKey {}
'''
for name in ['ConversationPositionRequestKey', 'ConversationBottomAnchorID', 'ConversationBottomAnchorFrame', 'ConversationMessageFrameSnapshot', 'MessageFramePreferenceKey', 'ConversationBottomAnchorFramePreferenceKey']:
    source += declaration('private struct ' + name + ':') + '\n'
source += '''
@main struct Checks {
 static func main() {
  var count = 0
  func check(_ yes: Bool, _ label: String) { precondition(yes, label); count += 1; print("PASS \\(label)") }
  let first = UUID(), second = UUID(), conversation = UUID(), epoch = UUID(), nextEpoch = UUID()
  let anchor = ConversationBottomAnchorID(positionRequest: .init(conversationID: conversation, request: 1), messageIDs: [first, second])
  let frame = CGRect(x: 0, y: 50, width: 300, height: 500)
  var value: ConversationMessageFrameSnapshot?
  let a = ConversationMessageFrameSnapshot(anchorID: anchor, frames: [first: frame], layoutRequestID: epoch)
  let b = ConversationMessageFrameSnapshot(anchorID: anchor, frames: [second: frame], layoutRequestID: epoch)
  MessageFramePreferenceKey.reduce(value: &value) { a }
  MessageFramePreferenceKey.reduce(value: &value) { b }
  check(value?.frames.count == 2 && value?.layoutRequestID == epoch, "same layout epoch merges message frames")
  MessageFramePreferenceKey.reduce(value: &value) { nil }
  check(value?.frames.count == 2, "empty contribution does not drop current rows")
  let newer = ConversationMessageFrameSnapshot(anchorID: anchor, frames: [first: frame], layoutRequestID: nextEpoch)
  MessageFramePreferenceKey.reduce(value: &value) { newer }
  check(value?.frames.count == 1 && value?.layoutRequestID == nextEpoch, "same message IDs do not merge different layout epochs")
  let idle = ConversationMessageFrameSnapshot(anchorID: anchor, frames: [second: frame])
  MessageFramePreferenceKey.reduce(value: &value) { idle }
  check(value?.frames.count == 1 && value?.layoutRequestID == nil, "old idle epoch cannot inherit new request token")
  MessageFramePreferenceKey.reduce(value: &value) { newer }
  check(value?.frames[second] == nil, "old idle row is absent from current fold acknowledgement")
  let switched = ConversationBottomAnchorID(positionRequest: .init(conversationID: UUID(), request: 2), messageIDs: [second])
  MessageFramePreferenceKey.reduce(value: &value) { .init(anchorID: switched, frames: [second: frame], layoutRequestID: nextEpoch) }
  check(value?.anchorID == switched && value?.frames[first] == nil, "conversation switch does not merge frames")
  var bottom: ConversationBottomAnchorFrame?
  ConversationBottomAnchorFramePreferenceKey.reduce(value: &bottom) { .init(anchorID: anchor, frame: frame, layoutRequestID: epoch) }
  check(bottom?.layoutRequestID == epoch, "bottom retains its measured epoch")
  ConversationBottomAnchorFramePreferenceKey.reduce(value: &bottom) { .init(anchorID: anchor, frame: frame, layoutRequestID: nextEpoch) }
  check(bottom?.layoutRequestID == nextEpoch, "same-size bottom still publishes changed epoch")
  check(a != newer, "same-size message geometry still publishes changed epoch")
  print("PASS \\(count) production layout-snapshot checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='mocca-layout-epochs-') as directory:
    swift=Path(directory)/'Checks.swift'; exe=Path(directory)/'checks'
    swift.write_text(source)
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6',str(swift),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
