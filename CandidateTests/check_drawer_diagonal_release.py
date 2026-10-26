#!/usr/bin/python3
"""Execute unchanged extracted production drag/settle bodies with curved paths.

Controlled touch samples and display cadence; not real recognizer delivery or FPS.
"""
from pathlib import Path
import hashlib,json,subprocess
from check_drawer_ready_gesture_ownership import make_harness
from check_drawer_close_driver_reuse import method
ROOT=Path(__file__).resolve().parents[1]
BASE='970ef4b7ea81f82a4846bc5a10f621ae36f1d65d'
OUT=ROOT/'work/verification/drawer-diagonal-release'
RUNNER=r'''
struct Sample: Codable {
 let key: String
 let y: Double
 let owned: Bool
 let held: Double
 let open: Bool
 let endpoint: Double
 let clean: Bool
}
@main struct Runner {
 @MainActor static func main() async throws {
  var results:[Sample]=[]
  for registered in [false,true] {
   for opening in [false,true] {
    for width:CGFloat in [300,420] {
     for pair:(CGFloat,CGFloat) in [(250,250),(90,330),(50,50),(-50,-90),(18,330),(19,330),(0,0)] {
      for y:CGFloat in [0,300,-300] {
       let sign:CGFloat=opening ? 1 : -1
       let base:CGFloat=opening ? 0 : 1
       let h=Harness(presented: !opening,registered:registered,progress:base)
       h.onChanged(DragValue(24*sign),drawerWidth:width,baseProgress:base)
       h.onChanged(DragValue(pair.0*sign,y,predicted:pair.1*sign),drawerWidth:width,baseProgress:base)
       let owned=h.drawerGestureLocked == true && h.isDrawerGestureActive
       let held=h.drawerPresentationProgressTracker.resolved(fallback: -1)
       h.onEnded(DragValue(pair.0*sign,y,predicted:pair.1*sign),drawerWidth:width,baseProgress:base)
       try await Task.sleep(for:.milliseconds(35));h.deliverChanges()
       CADisplayLink.links.last?.fire(at:100.8)
       let endpoint=h.drawerPresentationProgressTracker.resolved(fallback: -1)
       let clean=h.drawerGestureLocked == nil && !h.isDrawerGestureActive && h.drawerDragActivationTranslationX == 0 && h.drawerSettleDriver.activeTargetProgress == nil && !DrawerViewportRefreshFreeze.isActive && h.list.isScrollEnabled && (!registered || h.chat.isScrollEnabled == !h.model.isDrawerPresented)
       results.append(Sample(key:"owned-\(registered)-\(opening)-\(width)-\(pair.0)-\(pair.1)",y:Double(y),owned:owned,held:Double(held),open:h.model.isDrawerPresented,endpoint:Double(endpoint),clean:clean))
       h.disappear()
      }
     }
    }
   }
   for kind in ["vertical","diagonal-unclaimed","tiny","wrong-opening","text-selection","composer-selection","horizontal-scroll","inactive"] {
    let h=Harness(presented:false,registered:registered,progress:0)
    var v=DragValue(24)
    switch kind {
    case "vertical":v=DragValue(3,35)
    case "diagonal-unclaimed":v=DragValue(24,24)
    case "tiny":v=DragValue(5,1)
    case "wrong-opening":v=DragValue(-50)
    case "text-selection":DrawerTextSelectionInteractionGate.ownsCurrentTouch=true
    case "composer-selection":h.model.isComposerFocused=true;ComposerTextSelectionInteractionGate.ownsCurrentTouch=true
    case "horizontal-scroll":DrawerHorizontalScrollGate.ownsCurrentTouch=true
    default:h.scenePhase = .inactive
    }
    h.onChanged(v,baseProgress:0)
    if kind == "vertical" {h.onChanged(DragValue(250,50),baseProgress:0)}
    let owned=h.drawerGestureLocked == true
    h.onEnded(v,baseProgress:0)
    results.append(Sample(key:"rejected-\(registered)-\(kind)",y:0,owned:owned,held:Double(h.drawerPresentationProgressTracker.resolved(fallback: -1)),open:h.model.isDrawerPresented,endpoint:Double(h.drawerPresentationProgressTracker.resolved(fallback: -1)),clean:h.drawerGestureLocked == nil && !h.isDrawerGestureActive && CADisplayLink.links.isEmpty))
    h.disappear()
   }
  }
  print(String(decoding:try JSONEncoder().encode(results),as:UTF8.self))
 }
}
'''
def main():
 OUT.mkdir(parents=True,exist_ok=True)
 current=(ROOT/'Mocca/RootView.swift').read_text()
 baseline=subprocess.check_output(['git','show',BASE+':Mocca/RootView.swift'],cwd=ROOT,text=True)
 # Product changes are restricted to release admission; all per-frame work,
 # recognizer admission, animations, text rendering and other gestures are exact.
 expected=baseline.replace('''            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let didOwnDrawerGesture''','''            .onEnded { value in
                let dx = value.translation.width
                let didOwnDrawerGesture''').replace('''                guard drawerGestureLocked == true,
                      drawerDragProgress != nil,
                      abs(dx) > max(drawerGestureIntentDistance, abs(dy) * drawerGestureAxisRatio) else {''','''                // Direction was decided when this touch took ownership. Keep
                // following that horizontal gesture even if its path later curves.
                guard drawerGestureLocked == true,
                      drawerDragProgress != nil,
                      abs(dx) > drawerGestureIntentDistance else {''')
 assert current==expected
 runs={}
 for label,root in [('baseline',baseline),('candidate',current)]:
  sources={n:(ROOT/f'Mocca/{n}.swift').read_text() for n in ['MessageMarkdownView','AppModel']}
  source,provenance=make_harness(root,sources['MessageMarkdownView'],sources['AppModel'])
  swift=OUT/(label+'.swift');swift.write_text(source+RUNNER);binary=OUT/label
  with (OUT/(label+'-compile.log')).open('w') as log:subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(swift),'-o',str(binary)],stdout=log,stderr=subprocess.STDOUT,check=True)
  result=subprocess.run([str(binary)],capture_output=True,text=True,check=True,timeout=90)
  runs[label]=json.loads(result.stdout)
  (OUT/(label+'.json')).write_text(json.dumps({'provenance':provenance,'rows':runs[label]},indent=2)+'\n')
  print(label,len(runs[label]),'paths executed',flush=True)
 baseline_flat={r['key']:r for r in runs['baseline'] if r['y']==0}
 failures=[];baseline_reproductions=[]
 for label,rows in runs.items():
  for row in rows:
   reference=baseline_flat[row['key']]
   same=all(row[k]==reference[k] for k in ['owned','held','open','endpoint','clean'])
   if label=='candidate' and not same:failures.append(row)
   if label=='baseline' and not same:baseline_reproductions.append(row)
   assert row['clean'],row
   assert row['owned']==row['key'].startswith('owned'),row
 assert baseline_reproductions and not failures
 report={'status':'PASS','baseline':BASE,'rootSHA256':hashlib.sha256(current.encode()).hexdigest(),'pathsPerVersion':len(runs['candidate']),'baselineCurvedReleaseDifferences':len(baseline_reproductions),'candidateDifferencesFromStraightBaseline':len(failures),'perFrameAndAdmissionSourceUnchanged':True,'limits':__doc__}
 (OUT/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
