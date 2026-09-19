#!/usr/bin/python3
"""Run production chat streams against synthetic localhost SSE, plus extracted
attachment/presentation consumption. No provider calls, app data or device use.
"""
from pathlib import Path
import base64, hashlib, http.server, json, subprocess, threading

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'work/verification/native-image-host'
OUT.mkdir(parents=True, exist_ok=True)

def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

service = (ROOT / 'Mocca/AIChatService.swift').read_text()
app = (ROOT / 'Mocca/AppModel.swift').read_text()
store = (ROOT / 'Mocca/ConversationStore.swift').read_text()
tools = (ROOT / 'Mocca/ToolCalling.swift').read_text()
attachment = (ROOT / 'Mocca/Attachments.swift').read_text()
(OUT / 'Service.swift').write_text(service.split('@MainActor\nfinal class OCRService')[0])
support = 'import Foundation\nimport ImageIO\nimport UniformTypeIdentifiers\n'
for name in ['ToolCallInfo', 'ToolResultInfo']:
    support += block(tools, 'struct ' + name + ':') + '\n'
for name in ['ToolEvent', 'TokenUsage', 'ReasoningSegment']:
    support += block(store, 'struct ' + name + ':') + '\n'
support += '''
typealias ToolCallHandler = @Sendable (String, [String: Any], String?) async -> String
enum AppPreferences { static func loadProxySettings() -> ProxySettings { ProxySettings() } }
struct MessageAttachment: Codable {
    enum Kind: String, Codable { case image }
    var id: UUID; var kind: Kind; var localURL: URL?; var fileName: String
    var mimeType: String; var byteCount: Int64; var metadata: [String: String] = [:]
}
struct ChatMessage {
    var id = UUID(); var text = ""; var reasoningSegments: [ReasoningSegment] = []
    var attachments: [MessageAttachment] = []; var toolEvents: [ToolEvent] = []
    var tokenUsage: TokenUsage?; var updatedAt = Date(); var parts: [String] = []
}
enum AttachmentStore {
    static var root = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("attachments")
    static var failWrites = false
    static func directory() throws -> URL {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
'''
support += block(attachment, '    static func saveGeneratedImage(') + '\n}\n'
support += block(app, 'enum NativeImageReplyPresentation {') + '\n'
support += '''
enum IOSBackgroundGenerationManager {
    static let shared = IOSBackgroundGenerationManagerImpl()
    struct IOSBackgroundGenerationManagerImpl { func recordProgress(runID: UUID) {} }
}
enum StreamDeliveryTrace {
    static let isEnabled = false
    static func record(event: ChatStreamEvent, messageID: UUID) {}
    static func recordTextPipeline(messageID: UUID, detailBuild: Double) {}
}
struct AssistantFixture { var id: UUID; var streamOutput: Bool }
final class MessageHost {
    var activeStreamingMessageIDsByConversation: [UUID: UUID] = [:]
    var messagesByConversation: [UUID: [ChatMessage]] = [:]
    var conversationMessageStore: [UUID: [ChatMessage]] {
        get { messagesByConversation }
        set { messagesByConversation = newValue }
    }
    var rawStreamingTextByMessageID: [UUID: String] = [:]
    var streamDidPublishFirstVisibleTextMessageIDs = Set<UUID>()
    func startStreamingDisplayCadenceIfNeeded(conversationID: UUID, messageID: UUID) {}
    func filteredStreamingDisplayText(_ text: String) -> (text: String, codecDuration: Double, filterInputUTF16: Int) { (text, 0, text.utf16.count) }
    func scheduleStreamingTextDisplay(conversationID: UUID, messageID: UUID, targetDisplayText: String, codecDuration: Double, filterInputUTF16: Int) {}
    func scheduleStreamPersistence() {}
    static func rebuiltParts(for message: ChatMessage) -> [String] { [] }
'''
support += block(app, '    private func appendStreamingEvent(').replace('private func', 'func')
start = app.index('        var receivedContent = false')
end = app.index('        guard var completed = try await finishSuccessfulStreaming(', start)
support += '''
    func consume(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>, conversationID: UUID, assistantMessage: ChatMessage, assistant: AssistantFixture) async throws {
''' + app[start:end] + '\n}\n}\n'
(OUT / 'Support.swift').write_text(support)
pixel = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ9kAAAAASUVORK5CYII=')
requests = []
lock = threading.Lock()

def image(data=pixel, mime='image/png'):
    return {'type': 'image_url', 'image_url': {'url': 'data:' + mime + ';base64,' + base64.b64encode(data).decode()}}

def delta(value): return {'choices': [{'delta': value}]}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with lock: requests.append(body)
        scenario = body['model'].split('/')[-1]
        usage = {'usage': {'prompt_tokens': 1903, 'completion_tokens': 7062, 'total_tokens': 8965}, 'choices': []}
        chunks = []
        if scenario == 'image': chunks = [delta({'content': None, 'images': [image()]})]
        elif scenario == 'text': chunks = [delta({'content': '你好，示例'})]
        elif scenario == 'mixed': chunks = [delta({'content': '鹦鹉', 'images': [image()]})]
        elif scenario == 'large': chunks = [delta({'images': [image(pixel + bytes(262144))]})]
        elif scenario == 'duplicate': chunks = [delta({'images': [image()]}), {'choices': [{'message': {'images': [image()]}}]}]
        elif scenario == 'multiple': chunks = [delta({'images': [image(), image(pixel + b'a'), image(pixel + b'b')]})]
        elif scenario == 'corrupt': chunks = [delta({'images': [image(b'not an image')]})]
        elif scenario == 'malformed': chunks = [delta({'images': [{'image_url': {'url': 'data:image/png;base64,???'}}]})]
        elif scenario == 'remote': chunks = [delta({'images': [{'image_url': {'url': 'https://example.invalid/x.png'}}]})]
        elif scenario == 'error': chunks = [{'error': {'message': 'synthetic provider failure'}}]
        elif scenario == 'tool':
            if not any(m['role'] == 'tool' for m in body['messages']):
                chunks = [{'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': 'fixture', 'type': 'function', 'function': {'name': 'fixture', 'arguments': '{}'}}]}, 'finish_reason': 'tool_calls'}]}]
            else: chunks = [delta({'images': [image()]})]
        elif scenario == 'responses':
            item = {'type': 'image_generation_call', 'id': 'fixture-image', 'result': base64.b64encode(pixel).decode(), 'output_format': 'png'}
            chunks = [{'type': 'response.output_item.added', 'item': {'type': 'image_generation_call', 'id': 'fixture-image'}}, {'type': 'response.output_item.done', 'item': item}, {'type': 'response.completed', 'response': {'output': [item]}}]
        chunks.append(usage)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
            self.wfile.flush()
        self.wfile.write(b'data: [DONE]\n\n')

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
localization = (ROOT / 'Mocca/AppLocalization.swift').read_text()
# Transport tests need production localization helpers, not UI declarations.
localization = localization[:localization.index('struct AppLanguagePicker:')] + localization[localization.index('enum ErrorLocalization {'):]
(OUT / 'Localization.swift').write_text(localization)
sources = [ROOT / 'Mocca/ProviderModels.swift', OUT / 'Service.swift', OUT / 'Support.swift', OUT / 'Localization.swift', Path(__file__).with_suffix('.swift')]
try:
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', *map(str, sources), '-o', str(OUT / 'runner')], check=True)
    result = subprocess.run([str(OUT / 'runner'), str(server.server_port), str(OUT)], text=True, capture_output=True)
    (OUT / 'results.log').write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr)
    result.check_returncode()
    # The live wire requests use production model capabilities and body merging.
    assert all(r.get('modalities') == ['text', 'image'] for r in requests if r['model'].startswith('fixture-image/') and not r['model'].endswith('/responses'))
    assert all(r.get('modalities') == ['text'] for r in requests if r['model'] == 'custom-image/text')
    (OUT / 'report.json').write_text(json.dumps({'status': 'PASS', 'synthetic_http_requests': len(requests), 'source_hashes': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT / 'Mocca/AIChatService.swift', ROOT / 'Mocca/AppModel.swift', ROOT / 'Mocca/Attachments.swift']}, 'limits': 'Synthetic localhost transport; extracted storage/presentation host; no iOS UI or paid provider request.'}, indent=2))
finally:
    server.shutdown()
