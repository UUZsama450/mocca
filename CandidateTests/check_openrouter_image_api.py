#!/usr/bin/python3
"""Compile production transports and exercise Images/chat routing on localhost.

No provider credentials, paid calls, app-container access, or phone installation.
All responses and image bytes are synthetic fixtures. The document reader,
settings, localization and attachment value type use isolated test adapters.
"""
from pathlib import Path
import base64
import hashlib
import http.server
import json
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'work/verification/openrouter-images'
HOST = OUT / 'host'
HOST.mkdir(parents=True, exist_ok=True)

def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

paths = {name: ROOT / ('Mocca/' + name + '.swift') for name in
         ['AIChatService', 'ProviderModels', 'ProviderViews', 'GenerationFeatures', 'ToolCalling', 'Attachments', 'AppModel']}
source = {name: path.read_text() for name, path in paths.items()}
(HOST / 'Service.swift').write_text(source['AIChatService'])
generation = source['GenerationFeatures']
(HOST / 'ImageService.swift').write_text('import Foundation\n' + generation[
    generation.index('struct ExternalImageModel:'):generation.index('struct IOSBackgroundGenerationSettings:')])
support = 'import Foundation\nimport ImageIO\nimport UniformTypeIdentifiers\n'
for name in ['ToolCallInfo', 'ToolResultInfo']:
    support += block(source['ToolCalling'], 'struct ' + name + ':') + '\n'
support += '''
typealias ToolCallHandler = @Sendable (String, [String: Any], String?) async -> String
enum AppPreferences { static func loadProxySettings() -> ProxySettings { ProxySettings() } }
enum ErrorLocalization {
    static func lookup(_ s: String) -> String { s }
    static func format(_ s: String, _ args: [String]) -> String { String(format: s, arguments: args) }
}
typealias L10n = ErrorLocalization
enum DocumentReadError: Error { case detail(String) }
actor DocumentAttachmentReader {
    static let shared = DocumentAttachmentReader()
    func imageSourceKey(_ attachment: MessageAttachment) -> String { attachment.localURL!.path }
    func image(_ attachment: MessageAttachment) throws -> ChatRequestImage {
        ChatRequestImage(mimeType: attachment.mimeType ?? "image/png", base64Data: try Data(contentsOf: attachment.localURL!).base64EncodedString())
    }
    func ocrCacheKey(image: ChatRequestImage, provider: ProviderConfiguration, modelID: String, prompt: String) -> String {
        modelID + prompt + image.base64Data
    }
    func ocrCacheKey(source: String, provider: ProviderConfiguration, modelID: String, prompt: String) -> String {
        modelID + prompt + source
    }
}
struct MessageAttachment: Sendable {
    enum Kind: Sendable { case image }
    var id: UUID; var kind: Kind; var localURL: URL?; var fileName: String?
    var mimeType: String?; var byteCount: Int64; var metadata: [String: String]
}
enum AttachmentStore {
    static func directory() throws -> URL {
        let url = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
'''
support += block(source['Attachments'], '    static func saveGeneratedImage(') + '\n}\n'
support += 'enum CatalogMerge {\n' + block(source['ProviderViews'], '    private func merging(').replace(
    'private func merging', 'static func merging') + '\n}\n'
support += '''
struct ResolvedChatModelContext {
    var provider: ProviderConfiguration
    var model: ModelConfiguration
}
struct TextModelResolver {
    var contexts: [String: ResolvedChatModelContext]
    func resolvedChatModel(for selection: ModelSelection?) -> ResolvedChatModelContext? {
        selection.flatMap { contexts[$0.modelID] }
    }
'''
support += block(source['AppModel'], '    private func firstResolvedChatModel(').replace('private func', 'func') + '\n}\n'
(HOST / 'Support.swift').write_text(support)

pixel = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ9kAAAAASUVORK5CYII=')
usage = {'prompt_tokens': 31, 'completion_tokens': 196, 'total_tokens': 227}
requests = []
catalog = [
    {'id': 'openai/gpt-image-2', 'name': 'GPT Image 2', 'architecture': {'input_modalities': ['text', 'image'], 'output_modalities': ['image']}, 'endpoints': ['/api/v1/images']},
    {'id': 'fixture/catalog-image', 'architecture': {'input_modalities': ['text'], 'output_modalities': ['text', 'image']}, 'endpoints': ['/api/v1/images']},
    {'id': 'fixture/chat-image', 'architecture': {'input_modalities': ['text'], 'output_modalities': ['image']}, 'endpoints': ['/api/v1/chat/completions', '/api/v1/images']},
]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def json_response(self, status, obj):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        try:
            self.wfile.write(json.dumps(obj).encode())
        except (BrokenPipeError, ConnectionResetError):
            pass
    def do_GET(self):
        requests.append({'method': 'GET', 'path': self.path})
        self.json_response(200, {'data': catalog})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        scenario = self.headers.get('X-Scenario', 'default')
        requests.append({'method': 'POST', 'path': self.path, 'scenario': scenario, 'body': body,
                         'custom_header': self.headers.get('X-Image-Test'),
                         'authorization': self.headers.get('Authorization')})
        if self.path == '/images':
            if scenario == 'quota':
                self.json_response(403, {'error': {'message': 'fixture key limit', 'code': 403}})
            elif scenario == 'server-error':
                self.json_response(200, {'error': {'message': 'fixture image error'}})
            elif scenario in ['empty', 'usage-only']:
                self.json_response(200, {'data': [], 'usage': usage})
            elif scenario == 'invalid-base64':
                self.json_response(200, {'data': [{'b64_json': '???'}]})
            elif scenario == 'empty-base64':
                self.json_response(200, {'data': [{'b64_json': ''}]})
            else:
                if scenario == 'cancel': time.sleep(0.5)
                data = pixel
                rows = [{'b64_json': base64.b64encode(data).decode(), 'media_type': 'image/png'}
                        for _ in range(body.get('n', 1))]
                self.json_response(200, {'data': rows, 'usage': usage})
        elif self.path == '/chat/completions':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            if scenario == 'text':
                delta = {'content': 'text reply'}
            else:
                delta = {'images': [{'image_url': {'url': 'data:image/png;base64,' + base64.b64encode(pixel).decode()}}]}
            event = {'choices': [{'delta': delta}]}
            self.wfile.write(('data: ' + json.dumps(event) + '\n\ndata: [DONE]\n\n').encode())
        elif self.path == '/responses':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            events = [
                {'type': 'response.output_item.added', 'item': {'type': 'image_generation_call', 'id': 'image'}},
                {'type': 'response.output_item.done', 'item': {'type': 'image_generation_call', 'id': 'image', 'result': base64.b64encode(pixel).decode(), 'output_format': 'png'}}
            ]
            for event in events:
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')
        else:
            self.json_response(404, {'error': {'message': 'unexpected endpoint'}})

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
sources = [paths['ProviderModels'], HOST / 'Service.swift', HOST / 'ImageService.swift', HOST / 'Support.swift', Path(__file__).with_suffix('.swift')]
try:
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', *map(str, sources), '-o', str(HOST / 'runner')], capture_output=True, text=True)
    (OUT / 'build.log').write_text(build.stdout + build.stderr)
    if build.returncode:
        print(build.stdout + build.stderr)
        raise SystemExit(build.returncode)
    run = subprocess.run([str(HOST / 'runner'), str(server.server_port), str(OUT)], capture_output=True, text=True)
    (OUT / 'tests.log').write_text(run.stdout + run.stderr)
    print(run.stdout + run.stderr)
    run.check_returncode()
    image_requests = [r for r in requests if r['path'] == '/images']
    assert image_requests
    for request in image_requests:
        body = request['body']
        assert body.get('prompt')
        assert body['prompt'] != 'text-only task must not generate an image'
        assert 'Process the attached image using the recognition instructions' not in body['prompt']
        assert not set(body).intersection({'messages', 'input', 'modalities', 'stream_options', 'tools', 'tool_choice', 'temperature', 'top_p', 'max_tokens'})
        # Existing assistant image service omits stream, new direct route forces false.
        assert body.get('stream', False) is False
    for request in [r for r in requests if r.get('scenario') == 'custom']:
        body = request['body']
        assert request['custom_header'] == 'model-value'
        assert body['quality'] == 'low' and body['n'] == 2
        assert body['provider'] == {'only': ['openai']}
        assert len(body['input_references']) == 2
        assert 'blue kitten' in body['prompt'] and 'white kitten' in body['prompt'] and 'watercolor' in body['prompt']
        assert 'tool output ignored' not in body['prompt']
    report = {'status': 'PASS', 'requests': requests, 'fixture_image_bytes': len(pixel),
              'source_hashes': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths.values()},
              'limits': 'Production transports, catalog merge and attachment save, isolated localhost. No new paid requests; no phone/UI acceptance.'}
    (OUT / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print('PASS: wire format, model overrides, image references, and provider routing assertions')
finally:
    server.shutdown()
