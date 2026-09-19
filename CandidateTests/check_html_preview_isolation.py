#!/usr/bin/python3
"""Synthetic, local-only macOS WebKit proof; never reads application data."""
import argparse, base64, hashlib, http.server, json, os, pathlib, re, socket, subprocess, threading, time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent / 'Mocca/MessageMarkdownView.swift')
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
ROOT = args.output.resolve()
ROOT.mkdir(parents=True, exist_ok=True)
SOURCE = args.source.resolve()
HARNESS = pathlib.Path(__file__).resolve().with_name('check_html_preview_isolation.swift')
text = SOURCE.read_text()
start = text.index('    @MainActor\n    final class Coordinator:', text.index('private struct HTMLPreviewWebView:'))
end = text.index('\nprivate struct MarkdownRenderBlock:', start)
extracted = text[start:end].rstrip()
assert extracted.endswith('}')
extracted = extracted[:-1].replace('private static ', 'static ')
production = 'import Foundation\nimport WebKit\nenum HTMLPreviewWebView {\n    static let bridgeHandlerName = "MoccaBridge"\n' + extracted + '\n}\n'
(ROOT / 'Production.swift').write_text(production)
source_hash = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
events, udp_events, event_lock = [], [], threading.Lock()
pixel = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ9kAAAAASUVORK5CYII=')

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with event_lock: events.append({'path': self.path, 'method': 'GET', 'time': time.time()})
        if self.path.endswith('.js'): body, mime = b'window.remoteScriptExecuted = true;', 'text/javascript'
        elif self.path.endswith('.css'): body, mime = b'body { --remote-css: yes; }', 'text/css'
        elif self.path.endswith('.png'): body, mime = pixel, 'image/png'
        else: body, mime = b'ok', 'text/plain'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        with event_lock: events.append({'path': self.path, 'method': 'POST', 'time': time.time()})
        self.send_response(200); self.send_header('Access-Control-Allow-Origin', '*'); self.end_headers()
    def log_message(self, *args): pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
udp_sockets, udp_ports = [], {}
def listen_udp(label, sock):
    while True:
        try: payload, address = sock.recvfrom(4096)
        except OSError: return
        with event_lock: udp_events.append({'case': label, 'bytes': len(payload), 'stun_cookie': payload[4:8].hex(), 'time': time.time()})
for label in ('rtc_control', 'rtc_private'):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('127.0.0.1', 0)); udp_sockets.append(sock)
    udp_ports[label] = sock.getsockname()[1]
    threading.Thread(target=listen_udp, args=(label, sock), daemon=True).start()

env = os.environ.copy()
env['HTML_TEST_HTTP_PORT'] = str(server.server_port)
env['HTML_TEST_UDP_PORTS'] = json.dumps(udp_ports)
def execute(tag, generated, fault=None):
    generated_path = ROOT / (tag + '-Production.swift')
    generated_path.write_text(generated)
    build = subprocess.run(['/usr/bin/swiftc', '-swift-version', '5', '-parse-as-library', '-framework', 'AppKit', '-framework', 'WebKit', str(generated_path), str(HARNESS), '-o', str(ROOT / (tag + '-harness'))], text=True, capture_output=True)
    (ROOT / (tag + '-compile.log')).write_text(build.stdout + build.stderr)
    if build.returncode: raise RuntimeError('Compilation failed: ' + str(ROOT / (tag + '-compile.log')))
    run_env = env.copy()
    run_env['HTML_TEST_OUTPUT'] = str(ROOT / (tag + '-webview-results.json'))
    if fault: run_env['HTML_TEST_FAULT'] = fault
    else: run_env.pop('HTML_TEST_FAULT', None)
    run = subprocess.run([str(ROOT / (tag + '-harness'))], env=run_env, text=True, capture_output=True, timeout=125)
    (ROOT / (tag + '-run.log')).write_text(run.stdout + run.stderr)
    if run.returncode: raise RuntimeError('Harness exited: ' + str(run.returncode))
    return json.loads((ROOT / (tag + '-webview-results.json')).read_text())

try:
    web = execute('normal', production)
    # Fault injection changes only the rule-list value in the extracted test copy.
    # Production load/error/bridge implementations remain byte-for-byte extracted.
    fault_production, replacements = re.subn(r'static let privateNetworkRules = """.*?"""', 'static let privateNetworkRules = "INVALID_TEST_RULES_JSON"', production, count=1, flags=re.S)
    assert replacements == 1
    fault_web = execute('compile-failure', fault_production, fault='compile')
finally:
    server.shutdown()
    for sock in udp_sockets: sock.close()
    (ROOT / 'http-events.json').write_text(json.dumps(events, indent=2))
    (ROOT / 'udp-events.json').write_text(json.dumps(udp_events, indent=2))

http_counts = {label: sum(e['path'].startswith('/' + label + '/') for e in events) for label in ('control', 'raw_rules', 'remove_csp', 'document_write', 'private_resources')}
udp_counts = {label: sum(e['case'] == label for e in udp_events) for label in udp_ports}
failures = list(web['failures']) + list(fault_web['failures'])
if http_counts['control'] < 4: failures.append('HTTP positive control did not exercise four resource classes')
for label in ('raw_rules', 'remove_csp', 'document_write', 'private_resources'):
    if http_counts[label] != 0: failures.append(label + ' made HTTP requests')
final_text = SOURCE.read_text()
final_start = final_text.index('    @MainActor\n    final class Coordinator:', final_text.index('private struct HTMLPreviewWebView:'))
final_end = final_text.index('\nprivate struct MarkdownRenderBlock:', final_start)
final_extracted = final_text[final_start:final_end].rstrip()[:-1].replace('private static ', 'static ')
segment_unchanged = extracted == final_extracted
if not segment_unchanged: failures.append('Extracted production segment changed during run')
report = {
    'status': ('PASS_WITH_CONFIRMED_RTC_LIMITATION' if udp_counts['rtc_private'] else 'PASS_RTC_BOUNDARY_INCONCLUSIVE') if not failures else 'FAIL',
    'scope': 'Synthetic macOS WKWebView DOM/JS/resource test. Not iOS phone acceptance and not proof of absolute network isolation.',
    'source': str(SOURCE), 'source_sha256_at_extraction': source_hash,
    'source_sha256_at_end': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
    'extracted_production_sha256': hashlib.sha256(production.encode()).hexdigest(),
    'extracted_segment_unchanged': segment_unchanged,
    'checks': web['checks'] + fault_web['checks'], 'failures': failures, 'http_request_counts': http_counts,
    'host': web['host'], 'webkit_bundle_version': web['webkit_bundle_version'],
    'fault_injection': 'Compile failure run changes only the extracted privateNetworkRules value to invalid JSON; no product file was edited.',
    'udp_packet_counts': udp_counts, 'rtc': web['rtc'],
    'rtc_interpretation': ('Private page emitted local STUN UDP despite CSP and WKContentRuleList; absolute network disconnection is disproved on this macOS host.' if udp_counts['rtc_private'] else 'No private STUN packet observed in the bounded window; this does not prove RTC isolation.'),
    'webview_results': str(ROOT / 'normal-webview-results.json'),
    'compile_failure_results': str(ROOT / 'compile-failure-webview-results.json'),
    'http_events': str(ROOT / 'http-events.json'), 'udp_events': str(ROOT / 'udp-events.json'),
}
(ROOT / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
print(json.dumps({key: value for key, value in report.items() if key != 'checks'}, indent=2, ensure_ascii=False))
print('DOM_JS_CHECKS', len(report['checks']))
raise SystemExit(0 if not failures else 1)
