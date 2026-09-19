"""Exercise the exact store on the host, with Int payloads and real Observation."""
from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parents[1];out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
s=(root/'Mocca/AppModel.swift').read_text();start=s.index('@MainActor\nfinal class ConversationMessageStore:');opening=s.index('{',start);end=opening+1;depth=1
while depth:
    depth+=(s[end]=='{')-(s[end]=='}');end+=1
store=s[start:end]
runner=r'''
final class Counter: @unchecked Sendable {
    private let lock=NSLock(); private var n=0
    func increment(){lock.lock();defer{lock.unlock()};n+=1}
    var value:Int{lock.lock();defer{lock.unlock()};return n}
}
@main struct Runner {
    @MainActor static func main() {
        let ids=(0..<12).map {_ in UUID()}
        var expected:[UUID:[Int]]=[:]
        let store=ConversationMessageStore(snapshot:expected)
        var seed:UInt64=12345
        func next()->Int {seed=seed &* 6364136223846793005 &+ 1;return Int(seed>>32)}
        var checks=0
        for step in 0..<2400 {
            let id=ids[next()%ids.count], other=ids.first{$0 != id}!
            let keyNotice=Counter(),otherNotice=Counter(),allNotice=Counter()
            withObservationTracking {_=store[id]} onChange:{keyNotice.increment()}
            withObservationTracking {_=store[other]} onChange:{otherNotice.increment()}
            withObservationTracking {_=store.snapshot} onChange:{allNotice.increment()}
            let prior=store.snapshot
            switch step%6 {
            case 0:store[id,default:[]].append(step);expected[id,default:[]].append(step)
            case 1:store[id]=[step,step+1];expected[id]=[step,step+1]
            case 2:store[id]=nil;expected[id]=nil
            case 3:
                store[id,default:[]].sort(by:>);expected[id,default:[]].sort(by:>)
            case 4:
                let existed=expected[id] != nil
                store[id]?.append(step);expected[id]?.append(step)
                // Optional chaining may write back nil; do not require a count
                // when the key is absent. A changed present value must notify.
                if existed {precondition(keyNotice.value==1)}
            default:
                var copy=expected;copy[id]=[step]
                store.replaceAll(with:copy);expected=copy
            }
            precondition(store.snapshot==expected)
            precondition(otherNotice.value==0)
            precondition(prior[other]==store[other])
            if step%6 != 4 {precondition(keyNotice.value==1 && allNotice.value==1)}
            checks+=1
        }
        let baseline=store.snapshot
        let immutable=baseline
        let all=Counter()
        withObservationTracking {_=store.snapshot} onChange:{all.increment()}
        store.replaceAll(with:baseline)
        precondition(all.value==0)
        for id in ids {store[id,default:[]].append(9999)}
        precondition(immutable==baseline)
        store.replaceAll(with:baseline)
        precondition(store.snapshot==baseline)
        let id=ids[0]
        store[id]=[1];let first=store.revision(for:id)
        store[id]=nil;precondition(store.revision(for:id)==0)
        let missing=Counter()
        withObservationTracking {_=store[id]} onChange:{missing.increment()}
        store[id]=[1]
        precondition(missing.value==1 && store.revision(for:id) != first)
        print("PASS store dictionary-equivalence transitions=\(checks); per-key isolation, global updates, snapshot rollback, missing keys and revision identity")
    }
}
'''
p=out/'StoreTests.swift';p.write_text('import Foundation\nimport Observation\ntypealias ChatMessage = Int\n'+store+'\n'+runner)
subprocess.run(['xcrun','swiftc','-parse-as-library',str(p),'-o',str(out/'store-tests')],check=True)
result=subprocess.check_output([str(out/'store-tests')],text=True);(out/'result.txt').write_text(result);print(result,end='')
