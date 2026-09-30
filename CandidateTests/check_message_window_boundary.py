"""Verify the actual boundary accessor reads at most two projection entries.
The projection/window are controlled; this does not benchmark cache lookup or UI.
"""
from pathlib import Path
import json, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
out=root/'work/verification/continuous-history/boundary';out.mkdir(parents=True,exist_ok=True)
source=(root/'Mocca/AppModel.swift').read_text()
start=source.index('    var messageWindowBoundary:');end=source.index('{',start)+1;depth=1
while depth:
 depth+=(source[end]=='{')-(source[end]=='}');end+=1
accessor=source[start:end]
swift=r'''
import Foundation
struct Message { let id = UUID() }
struct Item { let message = Message() }
final class Counter { var reads = 0 }
struct Projection {
 let items: [Item]; let counter: Counter
 subscript(_ index: Int) -> Item { counter.reads += 1; return items[index] }
}
struct Window { let startIndex: Int; let count: Int; var endIndex: Int { startIndex + count } }
final class Fixture {
 let selectedConversationID = UUID()
 let projection: Projection
 let window: Window
 init(_ items: [Item], _ window: Window) {
  projection = Projection(items: items, counter: Counter()); self.window = window
 }
 func selectedMessageProjection(for _: UUID) -> Projection { projection }
 func messageWindow(for _: UUID, projection _: Projection) -> Window { window }
// ACCESSOR
}
@main struct Checks {
 static func main() throws {
  var cases = 0
  for total in [0,12,360,10000] {
   let items = (0..<total).map { _ in Item() }
   let windows = [Window(startIndex: 0, count: 0)] + (total > 0 ? [
    Window(startIndex: 0, count: min(12,total)),
    Window(startIndex: total/2, count: min(360,total-total/2)),
    Window(startIndex: total-1, count: 1)
   ] : [])
   for w in windows {
    let f=Fixture(items,w), b=f.messageWindowBoundary
    precondition(b.count == w.count)
    precondition(b.firstID == (w.count == 0 ? nil : items[w.startIndex].message.id))
    precondition(b.lastID == (w.count == 0 ? nil : items[w.endIndex-1].message.id))
    precondition(f.projection.counter.reads == (w.count == 0 ? 0 : 2))
    cases += 1
   }
  }
  print("{\"cases\":\(cases),\"max_projection_element_reads\":2,\"failed\":0}")
 }
}
'''.replace('// ACCESSOR',accessor)
with tempfile.TemporaryDirectory(prefix='mocca-paging-boundary-') as tmp:
 p=Path(tmp);(p/'host.swift').write_text(swift)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6',str(p/'host.swift'),'-o',str(p/'host')],check=True)
 result=json.loads(subprocess.check_output([str(p/'host')],text=True))
(out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
