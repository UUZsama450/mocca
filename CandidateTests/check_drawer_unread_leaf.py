"""Source-scoped SwiftUI/Observation and rendering comparison, not device FPS."""
from pathlib import Path
import subprocess, sys, json, hashlib
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(sys.argv[1]).resolve(); OUT.mkdir(parents=True,exist_ok=True)
BASE='021859bc9ffa84800b9e2d7fbde28f97a5c5d445'
old=subprocess.check_output(['git','show',BASE+':Mocca/RootView.swift'],cwd=ROOT,text=True)
new=(ROOT/'Mocca/RootView.swift').read_text()
def block(s,marker):
    a=s.index(marker); b=s.index('{',a); depth=0
    for i in range(b,len(s)):
        depth+=(s[i]=='{')-(s[i]=='}')
        if depth==0:return s[a:i+1]
    raise ValueError(marker)
leaf=block(new,'private struct DrawerUnreadReplyIndicator:')
parent=block(new,'private struct ConversationDrawerContent:')
assert 'unreadReplyConversationIDs' not in parent
assert new.count('model.unreadReplyConversationIDs')==1
assert parent.count('DrawerUnreadReplyIndicator(')==2
identity=block(new,'private struct ConversationDrawerRowIdentity:')
assert 'hasUnreadReply' not in identity
assert 'let isSelected: Bool' in identity and 'let title: String' in identity
assert '.id("\\(result.message.id.uuidString)-\\(isSelected)")' in parent
for marker in ['private struct ConversationDrawer:', 'private struct DrawerContentMotionModifier:',
 'private struct DrawerLiveMainPanelContent:', 'private func conversationDateGroups(',
 'private func selectConversationFromDrawer(', 'private func selectContentSearchResultFromDrawer(']:
    assert block(old,marker)==block(new,marker),marker
for path in ['Mocca/AppModel.swift','Mocca/MessageMarkdownView.swift','Mocca/ConversationStore.swift']:
    assert (ROOT/path).read_bytes()==subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT),path
oldDot=block(old,'if hasUnreadReply && !isSelected {')
# Only injection changes for explicit Observation tracking. Rendered leaf keeps @Environment.
injected=leaf.replace('DrawerUnreadReplyIndicator','InjectedIndicator').replace('@Environment(AppModel.self) private var model','let model: AppModel')
swift='''import SwiftUI
import Observation
import Foundation
@Observable final class AppModel { var unreadReplyConversationIDs = Set<UUID>() }
final class Counter: @unchecked Sendable {
 private let lock=NSLock(); private var n=0
 func increment(){lock.lock();n+=1;lock.unlock()}
 var value:Int {lock.lock();defer{lock.unlock()};return n}
}
'''+leaf+'\n'+injected+'''
private struct OldDot: View {
 let hasUnreadReply:Bool; let isSelected:Bool
 var body:some View {'''+oldDot+'''}
}
private struct Parent:View {
 let model:AppModel; let id:UUID; let selected:Bool; let baseline:Bool
 var body:some View {
   if baseline {
     OldDot(hasUnreadReply:model.unreadReplyConversationIDs.contains(id),isSelected:selected)
   } else {
     InjectedIndicator(model:model,conversationID:id,isSelected:selected)
   }
 }
}
@main struct Runner {
 @MainActor static func image<V:View>(_ view:V) -> CGImage {
   let renderer=ImageRenderer(content:view.frame(width:260,height:46).background(.white).environment(\\.colorScheme,.light).tint(.blue))
   renderer.scale=2
   return renderer.cgImage!
 }
 @MainActor static func main() throws {
   let model=AppModel(),a=UUID(),b=UUID()
   let before=Parent(model:model,id:a,selected:false,baseline:true)
   let after=Parent(model:model,id:a,selected:false,baseline:false)
   let dot=InjectedIndicator(model:model,conversationID:a,isSelected:false)
   let selectedDot=InjectedIndicator(model:model,conversationID:a,isSelected:true)
   let oldCount=Counter(),newCount=Counter(),dotCount=Counter(),selectedCount=Counter()
   for i in 0..<20 {
     withObservationTracking {_ = before.body} onChange:{oldCount.increment()}
     withObservationTracking {_ = after.body} onChange:{newCount.increment()}
     withObservationTracking {_ = dot.body} onChange:{dotCount.increment()}
     withObservationTracking {_ = selectedDot.body} onChange:{selectedCount.increment()}
     if i%2==0 {model.unreadReplyConversationIDs.insert(a)} else {model.unreadReplyConversationIDs.remove(a)}
   }
   precondition(oldCount.value==20 && newCount.value==0 && dotCount.value==20 && selectedCount.value==0)
   // Shared set deliberately still notifies other tiny dot leaves.
   let other=Counter()
   withObservationTracking {_ = dot.body} onChange:{other.increment()}
   model.unreadReplyConversationIDs.insert(b)
   precondition(other.value==1)
   var renders=0
   for selected in [false,true] {for unread in [false,true] {for spacing:CGFloat in [6,8] {
     model.unreadReplyConversationIDs = unread ? [a] : []
     let original=image(HStack(spacing:spacing){Text("聊天标题");Spacer(minLength:6);OldDot(hasUnreadReply:unread,isSelected:selected)})
     let candidate=image(HStack(spacing:spacing){Text("聊天标题");Spacer(minLength:6);DrawerUnreadReplyIndicator(conversationID:a,isSelected:selected)}.environment(model))
     precondition(original.width==candidate.width && original.height==candidate.height)
     precondition((original.dataProvider!.data! as Data)==(candidate.dataProvider!.data! as Data),"render differs")
     renders+=1
   }}}
   print("PASS baseline_parent=20 candidate_parent=0 dot=20 selected_dot=0 rendered_pairs=\\(renders)")
 }
}
'''
source=OUT/'unread.swift';source.write_text(swift)
exe=OUT/'unread'
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(source),'-o',str(exe)],check=True)
r=subprocess.run([str(exe)],check=True,capture_output=True,text=True)
print(r.stdout,end='');(OUT/'result.txt').write_text(r.stdout)
(OUT/'manifest.json').write_text(json.dumps({'baseline':BASE,'root_sha256':hashlib.sha256(new.encode()).hexdigest(),'scope':'Extracted production leaf, native macOS SwiftUI rendering, Observation construction fixtures and source ownership checks. Not full iOS hierarchy or device FPS.'},indent=2)+'\n')
