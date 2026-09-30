#!/usr/bin/python3
"""Run the production image-dismiss event policy with synthetic gesture states.
This verifies callback decisions, not UIKit recognizer arbitration on a phone.
"""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1];out=root/'work/preview-verification/image-dismiss';out.mkdir(exist_ok=True,parents=True)
s=(root/'Mocca/Attachments.swift').read_text();start=s.index('        @objc func handleDismissPan(');end=s.index('\n        func gestureRecognizerShouldBegin',start);function=s[start:end].replace('@objc ','')
source='''import Foundation
final class ScrollView {}
struct UIPanGestureRecognizer {
    enum State: CaseIterable { case possible, began, changed, ended, cancelled, failed }
    var state: State
    var offset: CGFloat
    var speed: CGFloat
    func translation(in: ScrollView) -> CGPoint { CGPoint(x: 0, y: offset) }
    func velocity(in: ScrollView) -> CGPoint { CGPoint(x: 0, y: speed) }
}
final class Harness {
    var scrollView: ScrollView? = ScrollView()
    var changed: CGFloat?
    var ended: (CGFloat, CGFloat)?
    func onDismissChanged(_ value: CGFloat) { changed = value }
    func onDismissEnded(_ translation: CGFloat, _ velocity: CGFloat) { ended = (translation, velocity) }
'''+function+'''
}
for state in UIPanGestureRecognizer.State.allCases {
    let h = Harness()
    h.handleDismissPan(.init(state: state, offset: 180, speed: 900))
    switch state {
    case .possible: precondition(h.ended == nil && h.changed == nil)
    case .began, .changed: precondition(h.changed == 180 && h.ended == nil)
    case .ended: precondition(h.ended!.0 == 180 && h.ended!.1 == 900)
    case .cancelled, .failed: precondition(h.ended!.0 == 0 && h.ended!.1 == 0)
    }
}
let detached = Harness(); detached.scrollView = nil
detached.handleDismissPan(.init(state: .ended, offset: 180, speed: 900))
precondition(detached.ended == nil)
let upward = Harness(); upward.handleDismissPan(.init(state: .changed, offset: -80, speed: -900))
precondition(upward.changed == 0)
print("PASS: 8 image-dismiss event-policy scenarios")
'''
f=out/'main.swift';f.write_text(source);subprocess.run(['xcrun','swiftc',str(f),'-o',str(out/'runner')],check=True);subprocess.run([str(out/'runner')],check=True)
