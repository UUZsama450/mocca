from pathlib import Path
import subprocess,hashlib,json,sys
candidate=Path(__file__).resolve().parents[1]
out=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else candidate/'work/verification/simple-arrow-policy'
out.mkdir(parents=True,exist_ok=True)
roots={'baseline':candidate.parent/'mocca-keyboard-modal-handoff-5035-a','candidate':candidate}
def block(s,start,end):
 a=s.index(start);return s[a:s.index(end,a)]
prefix='''import Foundation
struct Preferences { var autoScrollEnabled = true }
struct Model { var messages = [1]; var hasLaterMessages = false; var preferences = Preferences() }
enum ChatBottomTrace { static func log(_ message: @autoclosure () -> String) {} }
struct State {
 var model = Model()
 var isQuickReturnToBottomVisible = false
 var messageReplacementRequest: Int? = nil
 var hasConcreteNativeUserScrollOwnership = false
 var isFreshConversationFollowSuppressed = false
 var isUserMessageSendPositioning = false
 var isMessageTargetNavigationOwned = false
 var ownsCurrentDoubleEdgeNavigation = false
 var isPositioningCurrentConversation = false
 var autoFollowEngaged = true
 var isUserScrollActive = false
 var chatBottomTraceState: String { "controlled context" }
'''
tests='''
}
var results: [[String: Any]] = []
func check(_ name: String, _ test: () -> Bool) { results.append(["name":name,"passed":test()]) }
func observe(_ s: inout State, at: Bool = false, near: Bool = false) { s.updateQuickReturnToBottomVisibility(isAtBottom: at, isNearBottom: near) }
check("keyboard viewport while following stays hidden") { var s=State(); observe(&s); return !s.isQuickReturnToBottomVisible }
check("stream growth while following stays hidden across sixty updates") { var s=State(); for i in 0..<60 { observe(&s,at:i%3==2,near:i%3 != 0); if s.isQuickReturnToBottomVisible {return false} }; return true }
check("native finger takes ownership during streaming") { var s=State(); s.hasConcreteNativeUserScrollOwnership=true; observe(&s); return s.isQuickReturnToBottomVisible }
check("history reading remains visible during keyboard geometry changes") { var s=State(); s.autoFollowEngaged=false;s.isUserScrollActive=true;observe(&s);observe(&s,near:true);return s.isQuickReturnToBottomVisible }
check("disabled following can reveal the control") { var s=State();s.model.preferences.autoScrollEnabled=false;observe(&s);return s.isQuickReturnToBottomVisible }
check("later window remains visible even at its local bottom") { var s=State();s.model.hasLaterMessages=true;observe(&s,at:true,near:true);return s.isQuickReturnToBottomVisible }
check("accepted return preserves existing arrow until exact landing") { var s=State();s.isQuickReturnToBottomVisible=true;s.ownsCurrentDoubleEdgeNavigation=true;observe(&s);s.ownsCurrentDoubleEdgeNavigation=false;observe(&s,near:true);let held=s.isQuickReturnToBottomVisible;observe(&s,at:true,near:true);return held && !s.isQuickReturnToBottomVisible }
check("message target navigation is not bottom-follow suppression") { var s=State();s.isMessageTargetNavigationOwned=true;observe(&s);return s.isQuickReturnToBottomVisible }
check("new top-start conversation does not inherit bottom ownership") { var s=State();s.isFreshConversationFollowSuppressed=true;observe(&s);return s.isQuickReturnToBottomVisible }
check("send positioning keeps its own visibility eligibility") { var s=State();s.isUserMessageSendPositioning=true;observe(&s);return s.isQuickReturnToBottomVisible }
check("message replacement does not inherit bottom ownership") { var s=State();s.messageReplacementRequest=1;observe(&s);return s.isQuickReturnToBottomVisible }
check("near-bottom band does not reveal a previously hidden arrow") { var s=State();s.autoFollowEngaged=false;observe(&s,near:true);return !s.isQuickReturnToBottomVisible }
check("near-bottom band retains an existing arrow") { var s=State();s.isQuickReturnToBottomVisible=true;observe(&s,near:true);return s.isQuickReturnToBottomVisible }
check("follow suppression does not dismiss an existing arrow early") { var s=State();s.isQuickReturnToBottomVisible=true;observe(&s);return s.isQuickReturnToBottomVisible }
print(String(data:try! JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]),encoding:.utf8)!)
'''
report={}
for label,root in roots.items():
 source=(root/'Mocca/RootView.swift').read_text()
 owner=block(source,'    private var shouldKeepNativeBottomPosition: Bool {','    private var shouldPauseStreamingFollowOnNativeTouch: Bool {')
 visibility=block(source,'    private func updateQuickReturnToBottomVisibility(','    private func beginSystemScrollToTop(')
 path=out/(label+'-policy.swift')
 # Only access control/mutability changes are needed to invoke the value harness.
 path.write_text(prefix+owner.replace('private var','var',1)+visibility.replace('private func','mutating func',1)+tests)
 result=subprocess.run(['swift',str(path)],capture_output=True,text=True,check=True)
 cases=json.loads(result.stdout)
 report[label]={'source_root_sha256':hashlib.sha256(source.encode()).hexdigest(),'owner_sha256':hashlib.sha256(owner.encode()).hexdigest(),'visibility_sha256':hashlib.sha256(visibility.encode()).hexdigest(),'cases':cases,'passed':sum(c['passed'] for c in cases),'total':len(cases)}
assert report['baseline']['owner_sha256']==report['candidate']['owner_sha256']
assert report['baseline']['passed']==12 and report['candidate']['passed']==14,report
report['boundary']='Actual extracted product visibility function and bottom-owner predicate; dependencies supplied as state inputs. This is decision coverage, not app streaming/rendering/touch timing acceptance.'
(out/'visibility-policy-result.json').write_text(json.dumps(report,indent=2))
print(json.dumps({label:{k:r[k] for k in ['passed','total']} for label,r in report.items() if isinstance(r,dict)}))
