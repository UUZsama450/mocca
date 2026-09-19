"""Execute the shipping header actions/global guard with controlled UIKit receivers."""
from pathlib import Path
import subprocess
from check_drawer_close_driver_reuse import extract
root=Path(__file__).resolve().parents[1]
out=root/'work/verification/interaction-polish'; out.mkdir(parents=True,exist_ok=True)
view=(root/'Mocca/RootView.swift').read_text(); model=(root/'Mocca/AppModel.swift').read_text()
header=extract(view,r'^private struct NewChatHeaderButton\b')[0]
actions='\n'.join(extract(header,rf'^    private func {name}\b')[0].replace('private func','func') for name in ['primaryAction','openNewConversation'])
guard=extract(model,r'^    func performHaptic\b')[0]
swift='''import Foundation
var selectionEvents = 0
var impactEvents = 0
struct UISelectionFeedbackGenerator { func selectionChanged() { selectionEvents += 1 } }
struct UIImpactFeedbackGenerator { enum Style { case light, medium }; init(style: Style) {}; func impactOccurred() { impactEvents += 1 } }
enum HapticFeedbackKind { case light, medium, soft }
struct Preferences { var hapticsGlobalEnabled = true; var hapticsOnDrawer = false; var hapticsOnListItemTap = false; var hapticsOnCardTap = false }
class Model {
 var selectedConversationIsGroupChat = false
 var selectedConversationID = UUID()
 var nextID: UUID? = UUID()
 var preferences = Preferences()
 var groupOpens = 0
 func createConversation() { if let nextID { selectedConversationID = nextID } }
 func openNewGroupChatCreator() { groupOpens += 1 }
'''+guard+'''
}
enum SponsorEasterEggPersistence { static var arms = 0; static func armNextNewChat(for id: UUID) { arms += 1 } }
struct Header { let model: Model
'''+actions+'''
}
func run(_ label: String, global: Bool = true, group: Bool = false, noOp: Bool = false, blocked: Bool = false, menu: Bool = false, events: Int) {
 let m=Model(); m.preferences.hapticsGlobalEnabled=global; m.selectedConversationIsGroupChat=group
 if noOp { m.nextID=m.selectedConversationID }; if blocked { m.nextID=nil }
 let before=selectionEvents; let header=Header(model:m)
 if menu { header.openNewConversation() } else { header.primaryAction() }
 assert(selectionEvents-before==events,label)
 assert(impactEvents==0,label)
 assert(m.groupOpens == (group && !menu ? 1 : 0),label)
 print("PASS",label)
}
run("effective new or reused empty chat; scene switches off",events:1)
run("already selected empty chat",noOp:true,events:0)
run("persistence blocked",blocked:true,events:0)
run("global off",global:false,events:0)
run("long press menu action",menu:true,events:0)
run("group creator",group:true,events:0)
'''
path=out/'new-chat-haptic.swift';path.write_text(swift)
subprocess.run(['xcrun','swiftc','-swift-version','5',str(path),'-o',str(out/'new-chat-haptic')],check=True)
result=subprocess.check_output([str(out/'new-chat-haptic')],text=True)
(out/'new-chat-haptic.log').write_text(result);print(result)
