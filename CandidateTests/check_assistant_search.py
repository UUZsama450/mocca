#!/usr/bin/python3
"""Exercise production search request/stream code against localhost fixtures.
No paid API requests; unrelated AssistantProfile dependencies use empty test types.
"""
from pathlib import Path
import http.server,json,subprocess,threading,hashlib
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'work/preview-verification/search';OUT.mkdir(parents=True,exist_ok=True)
def block(source,marker):
 start=source.index(marker);pos=source.index('{',start)+1;depth=1
 while depth:depth+=(source[pos]=='{')-(source[pos]=='}');pos+=1
 return source[start:pos]
s=(ROOT/'Mocca/AIChatService.swift').read_text();(OUT/'Service.swift').write_text(s.split('@MainActor\nfinal class OCRService')[0])
tools=(ROOT/'Mocca/ToolCalling.swift').read_text()
support='import Foundation\n'+''.join(block(tools,'struct '+n+':')+'\n' for n in ['ToolCallInfo','ToolResultInfo'])
support+='''
typealias ToolCallHandler = @Sendable (String, [String: Any], String?) async -> String
enum AppPreferences { static func loadProxySettings() -> ProxySettings { ProxySettings() } }
struct AssistantFile: Codable, Hashable, Sendable {}
struct MigrationMetadata: Codable, Hashable, Sendable {}
struct RecentMemorySettings: Codable, Hashable, Sendable { var isEnabled = false }
struct RecentMemoryState: Codable, Hashable, Sendable {}
enum AssistantFileService { static func validate(_ files: [AssistantFile]) throws {} }
'''
(OUT/'Support.swift').write_text(support)
a=(ROOT/'Mocca/AssistantModels.swift').read_text().replace('import UIKit','');a=a[:a.index('    var trimmedSystemPrompt:')]+ '}\n';(OUT/'Assistant.swift').write_text(a)
l=(ROOT/'Mocca/AppLocalization.swift').read_text();l=l[:l.index('struct AppLanguagePicker:')]+l[l.index('enum ErrorLocalization {'):];(OUT/'Localization.swift').write_text(l)
requests=[]
def delta(x):return {'choices':[{'delta':x}]}
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_POST(self):
  b=json.loads(self.rfile.read(int(self.headers['Content-Length'])));requests.append({'path':self.path,'body':b})
  source={'type':'url_citation','url':'https://example.org/source','title':'A [source]'}
  if self.path.startswith('/responses'):
   events=[{'type':'response.output_text.delta','delta':'answer'}, {'type':'response.output_text.annotation.added','annotation':source}, {'type':'response.completed','response':{'output':[{'type':'message','content':[{'type':'output_text','annotations':[source]}]}],'usage':{'input_tokens':1024,'input_tokens_details':{'cached_tokens':512},'output_tokens':1}}}]
  elif self.path.startswith('/messages'):
   events=[{'type':'content_block_start','content_block':{'type':'server_tool_use','id':'srv_1','name':'web_search'}},{'type':'content_block_stop'},{'type':'content_block_delta','delta':{'type':'text_delta','text':'answer'}},{'type':'content_block_delta','delta':{'type':'citations_delta','citation':dict(source,type='web_search_result_location')}},{'type':'message_stop'}]
  elif self.path.startswith('/models/'):
   events=[{'candidates':[{'content':{'parts':[{'text':'answer'}]},'groundingMetadata':{'groundingChunks':[{'web':{'uri':source['url'],'title':source['title']}}]}}]}]
  else:
   if b['model']=='mixed' and not any(m['role']=='tool' for m in b['messages']):
    events=[delta({'tool_calls':[{'index':0,'id':'call_1','type':'function','function':{'name':'calculate','arguments':'{}'}}]})]
   else:events=[delta({'content':'answer'}),delta({'annotations':[{'type':'url_citation','url_citation':source}]}),delta({'annotations':[{'type':'url_citation','url_citation':source}]})]
  if b.get('model')=='failed':events=[{'type':'response.failed','response':{'error':{'message':'fixture search unavailable'}}}]
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  for e in events:self.wfile.write(('data: '+json.dumps(e)+'\n\n').encode());self.wfile.flush()
  self.wfile.write(b'data: [DONE]\n\n')
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
try:
 files=[ROOT/'Mocca/ProviderModels.swift',OUT/'Service.swift',OUT/'Support.swift',OUT/'Localization.swift',OUT/'Assistant.swift',Path(__file__).with_suffix('.swift')]
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',*map(str,files),'-o',str(OUT/'runner')],check=True)
 result=subprocess.run([str(OUT/'runner'),str(server.server_port)],text=True,capture_output=True);print(result.stdout+result.stderr);(OUT/'results.log').write_text(result.stdout+result.stderr);result.check_returncode()
 for request in requests:
  b=request['body'];tools=b.get('tools',[]);model=b.get('model','gemini')
  if model in ['router-chat','router-responses','mixed']:assert any(t.get('type')=='openrouter:web_search' and t['parameters']['engine']=='native' for t in tools)
  if model in ['responses','failed']:assert any(t.get('type')=='web_search' for t in tools)
  if model=='claude':assert any(t.get('type')=='web_search_20250305' for t in tools)
  if request['path'].startswith('/models/'):assert any('google_search' in t for t in tools)
  assert b.get('session_id')=='fixture-session' if model.startswith('router') or model=='mixed' else True
 for model in ['anthropic/claude-sonnet-5.5','openai/gpt-5.1']:
  pair=[r['body'] for r in requests if r['body'].get('model')==model]
  assert len(pair)==2 and 'cache_control' not in pair[0]
  assert pair[1].get('cache_control')==({'type':'ephemeral'} if model.startswith('anthropic/') else None)
 (OUT/'requests.json').write_text(json.dumps(requests,indent=2))
 (OUT/'report.json').write_text(json.dumps({'status':'PASS','requests':len(requests),'source_sha256':hashlib.sha256(s.encode()).hexdigest(),'limits':'Localhost production transport; AssistantProfile init/decoder extracted with unrelated empty dependency types; not provider availability or pricing verification.'},indent=2))
 print('PASS request contracts:',len(requests))
finally:server.shutdown()
