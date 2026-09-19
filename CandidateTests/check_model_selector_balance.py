"""Production balance lifecycle + leaf observation; fake transport, no accounts."""
from pathlib import Path
import importlib.util,subprocess,json,sys,hashlib
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(sys.argv[1]).resolve();OUT.mkdir(parents=True,exist_ok=True)
spec=importlib.util.spec_from_file_location('polish',ROOT/'CandidateTests/check_provider_editor_polish.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.OUTPUT=OUT/'lifecycle'
m.main()
s=(ROOT/'Mocca/ProviderViews.swift').read_text()
header=m.declaration(s,'private func providerSectionHeader(')
leaf=m.declaration(s,'private struct ModelSelectorProviderBalance:')
selector=m.declaration(s,'struct ModelSelectorView:')
assert 'if provider.balanceEnabled {' in header
assert header.count('ModelSelectorProviderBalance(')==1
assert 'query.result' not in selector and 'query.isFetching' not in selector
assert 'ProviderBalanceQueryState()' not in selector
assert 'AppModel' not in leaf
assert '.onDisappear { query.hide(surfaceID) }' in leaf
assert '.onChange(of: ProviderBalanceQueryKey(configuration))' in leaf
base=subprocess.check_output(['git','show','924a332:Mocca/ProviderViews.swift'],cwd=ROOT,text=True)
for marker in ['private struct ProviderBalanceQueryKey:', 'private final class ProviderBalanceQueryState']:
 current=m.declaration(s,marker).replace('ProviderBalanceResult', 'String')
 assert current==m.declaration(base,marker),marker
query=s[s.index('private struct ProviderBalanceQueryKey:'):s.index('private struct ProviderBalanceSummaryView:')]
query=query.replace('private struct ProviderBalanceQueryKey:', 'struct ProviderBalanceQueryKey:').replace('private final class ProviderBalanceQueryState','final class ProviderBalanceQueryState')
injected=leaf.replace('ModelSelectorProviderBalance','InjectedBalance').replace('@State private var query = ProviderBalanceQueryState()','let query: ProviderBalanceQueryState')
header=header.replace('ModelSelectorProviderBalance(configuration: provider)','InjectedBalance(configuration: provider, query: query)')
fixture='''
struct ProviderGlyph:View {let provider:ProviderConfiguration;let size:CGFloat;var body:some View {Circle().frame(width:size,height:size)}}
private struct Parent:View {
 let configuration:ProviderConfiguration;let query:ProviderBalanceQueryState
 var body:some View {providerSectionHeader(configuration)}
'''+header+'\n}\n'
tests='''
final class Count: @unchecked Sendable {
 private let lock=NSLock();private var n=0
 func bump(){lock.lock();n+=1;lock.unlock()}
 var value:Int {lock.lock();defer{lock.unlock()};return n}
}
@main struct VerifyLeaf {
 @MainActor static func main() async throws {
  let fetch=ControlledBalance(),provider=ProviderConfiguration(),surface=UUID()
  let q=ProviderBalanceQueryState(debounce:.zero,fetch:{try await fetch.fetch($0)})
  q.show(surface,provider:provider)
  while await fetch.total()==0 {try await Task.sleep(for:.milliseconds(2))}
  let parent=Parent(configuration:provider,query:q)
  let leaf=InjectedBalance(configuration:provider,query:q)
  let pc=Count(),lc=Count()
  withObservationTracking {_ = parent.body} onChange:{pc.bump()}
  withObservationTracking {_ = leaf.body} onChange:{lc.bump()}
  await fetch.complete(1,"12.34")
  for _ in 0..<100 {if q.result != nil {break};try await Task.sleep(for:.milliseconds(2))}
  precondition(q.result == .value("12.34"))
  precondition(pc.value==0 && lc.value==1)
  for _ in 0..<100 {_ = parent.body; q.update(surface,provider:provider)}
  let total=await fetch.total();precondition(total==1)
  q.hide(surface)
  print("PASS balance completion: parent notifications=0 leaf notifications=1; 100 equivalent updates: requests=1")
 }
}
'''
p=OUT/'Leaf.swift';p.write_text('import SwiftUI\n'+m.STUBS+query+injected+fixture+tests)
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(p),'-o',str(OUT/'leaf')],check=True)
r=subprocess.run([str(OUT/'leaf')],capture_output=True,text=True,check=True)
(OUT/'leaf-result.txt').write_text(r.stdout+r.stderr);print(r.stdout)
(OUT/'scope.json').write_text(json.dumps({'source_sha256':hashlib.sha256(s.encode()).hexdigest(),'existing_query_lifecycle_unchanged':True,'scope':'Production query and view-construction Observation fixture with fake transport. Not an iPhone FPS measurement.'},indent=2)+'\n')
