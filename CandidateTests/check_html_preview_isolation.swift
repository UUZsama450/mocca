import AppKit
import WebKit

struct HTMLBridgeRequest { let id: Int; let method: String }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    func open(_ url: URL) { }
}
@MainActor final class NavigationSpy: NSObject, WKNavigationDelegate {
    let coordinator: HTMLPreviewWebView.Coordinator
    init(_ coordinator: HTMLPreviewWebView.Coordinator) { self.coordinator = coordinator }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        print("NAV url=\(action.request.url?.absoluteString ?? "nil") main=\(String(describing: action.targetFrame?.isMainFrame)) type=\(action.navigationType.rawValue)")
        coordinator.webView(webView, decidePolicyFor: action) { policy in
            print("POLICY \(policy.rawValue)"); decisionHandler(policy)
        }
    }
}

@MainActor final class Harness {
    var checks: [[String: Any]] = []
    var failures: [String] = []
    var rtc: [String: Any] = [:]
    var receivedRequests: [HTMLBridgeRequest] = []
    var retained: [(WKWebView, HTMLPreviewWebView.Coordinator)] = []
    let httpPort = ProcessInfo.processInfo.environment["HTML_TEST_HTTP_PORT"]!
    let output = ProcessInfo.processInfo.environment["HTML_TEST_OUTPUT"]!
    let ports = try! JSONSerialization.jsonObject(with: ProcessInfo.processInfo.environment["HTML_TEST_UDP_PORTS"]!.data(using: .utf8)!) as! [String: Int]

    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func quote(_ string: String) -> String { String(data: try! JSONSerialization.data(withJSONObject: [string]), encoding: .utf8)!.dropFirst().dropLast().description }
    func js(_ view: WKWebView, _ source: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(source) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value ?? NSNull()) }
            }
        }
    }
    func verify(_ name: String, _ passed: Bool, _ detail: Any = "") {
        checks.append(["name": name, "passed": passed, "detail": detail])
        if !passed { failures.append(name) }
        print("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
        fflush(stdout)
    }
    func fresh(privateMode: Bool) -> (WKWebView, HTMLPreviewWebView.Coordinator) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let coordinator = HTMLPreviewWebView.Coordinator(onBridgeRequest: { [weak self] request in self?.receivedRequests.append(request) }, currentChatBridgeEnabled: privateMode)
        if privateMode { configuration.userContentController.add(coordinator, name: HTMLPreviewWebView.bridgeHandlerName) }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 392, height: 700), configuration: configuration)
        view.navigationDelegate = coordinator
        retained.append((view, coordinator))
        return (view, coordinator)
    }
    func make(_ source: String, privateMode: Bool, wrap: Bool = true) async throws -> WKWebView {
        let (view, coordinator) = fresh(privateMode: privateMode)
        let signature = UUID().uuidString
        coordinator.lastLoadSignature = signature
        coordinator.load(wrap ? HTMLPreviewWebView.sandboxedDocument(from: source, currentChatBridgeEnabled: privateMode) : source, in: view, signature: signature)
        for _ in 0..<100 {
            if (!privateMode || coordinator.privateNetworkIsolationReady),
               let ready = try? await js(view, "window.fixtureReady === true && document.readyState === 'complete'"),
               ready as? Bool == true { return view }
            await pause(0.05)
        }
        throw NSError(domain: "FixtureLoad", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for synthetic page"])
    }
    func dispose() {
        for (view, coordinator) in retained {
            coordinator.lastLoadSignature = ""
            coordinator.privateNetworkIsolationReady = false
            view.stopLoading()
            view.configuration.userContentController.removeScriptMessageHandler(forName: HTMLPreviewWebView.bridgeHandlerName)
            view.navigationDelegate = nil
        }
        retained.removeAll()
        receivedRequests.removeAll()
    }
    let body = #"""
    <button id="button" onclick="document.getElementById('result').textContent='clicked'">Click</button><p id="result">initial</p>
    <canvas id="canvas" width="8" height="8"></canvas>
    <svg id="svg" width="100" height="30" xmlns="http://www.w3.org/2000/svg"><rect id="rect" x="0" width="10" height="10"><animate attributeName="x" from="0" to="40" dur="4s" fill="freeze"/></rect></svg>
    <script>const ctx=document.getElementById('canvas').getContext('2d');ctx.fillStyle='rgb(255,0,0)';ctx.fillRect(0,0,8,8);window.fixtureReady=true;</script>
    """#

    func compatibility() async throws {
        let full = "<!doctype html><html lang='zh-Hans' dir='rtl'><head><title>Original title</title><style>#result { color: rgb(7, 8, 9); } body { background-color: rgb(11, 12, 13); }</style></head><body id='original-body' class='kept' data-state='original'>" + body + "</body></html>"
        let fixtures = [
            ("full", full),
            ("fragment", "<style>#result{color:rgb(7,8,9)}</style>" + body),
            ("comment_fake_head", "<!-- <head> fake opening -->" + full),
            ("script_fake_head", "<script>window.rawTextSentinel = '<head>'; </script>" + full),
            ("comment_fake_html", "<!-- <html data-fake='yes'> -->" + full)
        ]
        for privateMode in [false, true] {
            for (name, source) in fixtures {
                let label = "\(privateMode ? "private" : "standard").\(name)"
                let view = try await make(source, privateMode: privateMode)
                let result = try await js(view, #"""
                (()=>{
                  document.getElementById('button').click();
                  const svg=document.getElementById('svg');svg.pauseAnimations();svg.setCurrentTime(2);
                  const image=Array.from(document.getElementById('canvas').getContext('2d').getImageData(1,1,1,1).data);
                  const policy=document.querySelector('meta[http-equiv="Content-Security-Policy"]');
                  return {title:document.title,lang:document.documentElement.lang,dir:document.documentElement.dir,
                    bodyID:document.body.id,bodyClass:document.body.className,bodyData:document.body.dataset.state,
                    color:getComputedStyle(document.getElementById('result')).color,background:getComputedStyle(document.body).backgroundColor,
                    clicked:document.getElementById('result').textContent,pixel:image,svgX:document.getElementById('rect').x.animVal.value,
                    cspInHead:!!policy && policy.parentElement === document.head,bridge:typeof window.mocca,
                    bridgeFrozen:typeof window.mocca !== 'undefined' && Object.isFrozen(window.mocca),mode:document.compatMode};
                })()
                """#) as! [String: Any]
                verify(label + ".csp_in_real_head", result["cspInHead"] as? Bool == true)
                verify(label + ".bridge_mode", result["bridge"] as? String == (privateMode ? "object" : "undefined"))
                verify(label + ".css", result["color"] as? String == "rgb(7, 8, 9)", result["color"] ?? NSNull())
                verify(label + ".click", result["clicked"] as? String == "clicked")
                verify(label + ".canvas", result["pixel"] as? [Int] == [255,0,0,255])
                verify(label + ".svg_animation", abs((result["svgX"] as? Double ?? -1) - 20) < 0.1, result["svgX"] ?? NSNull())
                if name != "fragment" {
                    verify(label + ".original_html_attrs", result["lang"] as? String == "zh-Hans" && result["dir"] as? String == "rtl")
                    verify(label + ".original_body_attrs", result["bodyID"] as? String == "original-body" && result["bodyClass"] as? String == "kept" && result["bodyData"] as? String == "original")
                    verify(label + ".original_head_title", result["title"] as? String == "Original title")
                    verify(label + ".original_head_style", result["background"] as? String == "rgb(11, 12, 13)")
                }
                dispose()
            }
        }
    }

    func resourcePayload(_ label: String) -> String {
        let base = "http://127.0.0.1:\(httpPort)/\(label)/"
        return "<html><head><link rel='stylesheet' href='\(base)style.css'><script src='\(base)external.js'></script></head><body><img src='\(base)image.png'><script>fetch('\(base)fetch').catch(()=>{});navigator.sendBeacon('\(base)beacon','synthetic');window.fixtureReady=true;</script></body></html>"
    }
    func networking() async throws {
        _ = try await make(resourcePayload("control"), privateMode: false, wrap: false)
        await pause(0.5); dispose()
        _ = try await make(resourcePayload("raw_rules"), privateMode: true, wrap: false)
        await pause(0.5); dispose()
        let remove = try await make("<p>Synthetic</p><script>window.fixtureReady=true;</script>", privateMode: true)
        _ = try await js(remove, "document.querySelectorAll('meta[http-equiv=\"Content-Security-Policy\"]').forEach(x=>x.remove());const box=document.createElement('div');box.innerHTML=\(quote(resourcePayload("remove_csp")));document.body.append(box);fetch('http://127.0.0.1:\(httpPort)/remove_csp/fetch').catch(()=>{});true")
        await pause(0.5); dispose()
        let rewrite = try await make("<p>Synthetic</p><script>window.fixtureReady=true;</script>", privateMode: true)
        _ = try await js(rewrite, "document.open();document.write(\(quote(resourcePayload("document_write"))));document.close();true")
        await pause(0.5)
        let cspCount = try await js(rewrite, "document.querySelectorAll('meta[http-equiv=\"Content-Security-Policy\"]').length")
        verify("document_write.removes_csp_dom", (cspCount as? Int) == 0, cspCount)
        dispose()
        _ = try await make(resourcePayload("private_resources"), privateMode: true)
        await pause(0.5); dispose()
    }

    func localImages() async throws {
        let view = try await make("<p>Synthetic images</p><script>window.fixtureReady=true;</script>", privateMode: true)
        let spy = NavigationSpy(retained.last!.1)
        view.navigationDelegate = spy
        _ = try await js(view, #"""
        window.imageChecks={};
        function testImage(name,url){const img=new Image();img.onload=()=>window.imageChecks[name]=img.naturalWidth>0;img.onerror=()=>window.imageChecks[name]=false;img.src=url;document.body.append(img);}
        testImage('data','data:image/svg+xml,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4" fill="red"/></svg>'));
        testImage('blob',URL.createObjectURL(new Blob(['<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4" fill="blue"/></svg>'],{type:'image/svg+xml'})));
        true;
        """#)
        await pause(0.5)
        let imageChecks = try await js(view, "window.imageChecks") as! [String: Bool]
        verify("private.data_image", imageChecks["data"] == true)
        verify("private.blob_image", imageChecks["blob"] == true)
        _ = try await js(view, "location.hash='fixture-fragment';true")
        await pause(0.5)
        let fragmentURL = try await js(view, "location.href")
        verify("private.fragment_navigation", fragmentURL as? String == "about:blank#fixture-fragment", fragmentURL)
        _ = try await js(view, "location.href='data:text/html,REPLACED';true")
        await pause(0.2)
        verify("private.data_document_blocked", try await js(view, "window.fixtureReady === true") as? Bool == true)
        _ = try await js(view, "location.href=URL.createObjectURL(new Blob(['REPLACED'],{type:'text/html'}));true")
        await pause(0.2)
        verify("private.blob_document_blocked", try await js(view, "window.fixtureReady === true") as? Bool == true)
        dispose()
    }
    func bridgeAndLifecycle() async throws {
        let view = try await make("<p>Synthetic bridge</p><script>window.fixtureReady=true;</script>", privateMode: true)
        let coordinator = retained.last!.1
        _ = try await js(view, "window.mocca.getCurrentChat();true")
        await pause(0.1)
        verify("bridge.ready_main_frame", receivedRequests.count == 1 && receivedRequests.first?.method == "getCurrentChat")
        coordinator.privateNetworkIsolationReady = false
        _ = try await js(view, "window.mocca.getCurrentChat();true")
        await pause(0.1)
        verify("bridge.not_ready_rejected", receivedRequests.count == 1)
        coordinator.privateNetworkIsolationReady = true
        coordinator.currentChatBridgeEnabled = false
        _ = try await js(view, "window.mocca.getCurrentChat();true")
        await pause(0.1)
        verify("bridge.disabled_mode_rejected", receivedRequests.count == 1)
        coordinator.currentChatBridgeEnabled = true
        let childSent = try await js(view, #"""
        (()=>{const iframe=document.createElement('iframe');document.body.append(iframe);
        iframe.contentWindow.eval('window.webkit.messageHandlers.MoccaBridge.postMessage(JSON.stringify({id:999,method:"getCurrentChat"}))');return true;})()
        """#)
        await pause(0.1)
        verify("bridge.subframe_message_rejected", childSent as? Bool == true && receivedRequests.count == 1)
        dispose()

        let (replacement, replacementCoordinator) = fresh(privateMode: true)
        replacementCoordinator.lastLoadSignature = "A"
        replacementCoordinator.load(HTMLPreviewWebView.sandboxedDocument(from: "<script>window.webkit.messageHandlers.MoccaBridge.postMessage(JSON.stringify({id:900,method:'getCurrentChat'}));window.token='A';</script>", currentChatBridgeEnabled: true), in: replacement, signature: "A")
        replacementCoordinator.lastLoadSignature = "B"
        replacementCoordinator.load(HTMLPreviewWebView.sandboxedDocument(from: "<script>window.token='B';window.fixtureReady=true;</script>", currentChatBridgeEnabled: true), in: replacement, signature: "B")
        for _ in 0..<100 {
            if (try? await js(replacement, "window.token")) as? String == "B" { break }
            await pause(0.05)
        }
        verify("load.latest_signature_wins", try await js(replacement, "window.token") as? String == "B")
        verify("load.stale_document_never_bridges", receivedRequests.isEmpty)
        dispose()

        let (cancelled, cancelledCoordinator) = fresh(privateMode: true)
        cancelledCoordinator.lastLoadSignature = "C"
        cancelledCoordinator.load(HTMLPreviewWebView.sandboxedDocument(from: "<script>window.fixtureReady=true;</script>", currentChatBridgeEnabled: true), in: cancelled, signature: "C")
        // Match the production dismantle invalidation without importing UIKit.
        cancelledCoordinator.lastLoadSignature = ""
        cancelledCoordinator.privateNetworkIsolationReady = false
        cancelled.stopLoading()
        cancelled.configuration.userContentController.removeScriptMessageHandler(forName: HTMLPreviewWebView.bridgeHandlerName)
        cancelled.navigationDelegate = nil
        await pause(0.5)
        verify("load.cancel_signature_stays_not_ready", !cancelledCoordinator.privateNetworkIsolationReady)
        verify("load.cancel_signature_skips_untrusted_document", try await js(cancelled, "window.fixtureReady === undefined") as? Bool == true)
        dispose()
    }
    func compileFailure() async throws {
        let (view, coordinator) = fresh(privateMode: true)
        coordinator.lastLoadSignature = "FAILURE"
        coordinator.load(HTMLPreviewWebView.sandboxedDocument(from: "<script>window.fixtureReady=true;window.mocca.getCurrentChat();</script>", currentChatBridgeEnabled: true), in: view, signature: "FAILURE")
        for _ in 0..<100 {
            if (try? await js(view, "document.body && document.body.textContent.includes('无法启用')")) as? Bool == true { break }
            await pause(0.05)
        }
        verify("compile_failure.trusted_error_page", try await js(view, "document.body && document.body.textContent.includes('无法启用')") as? Bool == true)
        verify("compile_failure.not_ready", !coordinator.privateNetworkIsolationReady)
        verify("compile_failure.untrusted_document_not_loaded", try await js(view, "window.fixtureReady === undefined && window.mocca === undefined") as? Bool == true)
        _ = try await js(view, "window.webkit.messageHandlers.MoccaBridge.postMessage(JSON.stringify({id:800,method:'getCurrentChat'}));true")
        await pause(0.1)
        verify("compile_failure.bridge_rejected", receivedRequests.isEmpty)
        dispose()
    }
    func rtcCheck(_ label: String, privateMode: Bool) async throws {
        let view = try await make("<p>Local synthetic RTC probe</p><script>window.fixtureReady=true;</script>", privateMode: privateMode, wrap: privateMode)
        let code = """
        window.rtcProbe={available:typeof RTCPeerConnection,started:false,candidates:[],errors:[]};
        if(typeof RTCPeerConnection === 'function'){
          try{
            window.pc=new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:\(ports[label]!)'}],iceCandidatePoolSize:0});
            pc.onicecandidate=e=>{if(e.candidate)rtcProbe.candidates.push(e.candidate.type);};
            pc.onicecandidateerror=e=>rtcProbe.errors.push({code:e.errorCode,text:e.errorText});
            pc.createDataChannel('synthetic');
            pc.createOffer().then(o=>pc.setLocalDescription(o)).then(()=>{rtcProbe.started=true;}).catch(e=>rtcProbe.errors.push(String(e)));
          }catch(e){rtcProbe.errors.push(String(e));}
        }
        true;
        """
        _ = try await js(view, code)
        await pause(5)
        rtc[label] = try await js(view, "rtcProbe")
        _ = try await js(view, "if(window.pc)pc.close();true")
        print("RTC \(label): \(rtc[label]!)"); fflush(stdout)
        dispose()
    }
    func run() async {
        do {
            if ProcessInfo.processInfo.environment["HTML_TEST_FAULT"] == "compile" {
                try await compileFailure()
            } else {
            try await compatibility()
            try await networking()
            try await localImages()
            try await bridgeAndLifecycle()
            try await rtcCheck("rtc_control", privateMode: false)
            try await rtcCheck("rtc_private", privateMode: true)
            }
        } catch {
            failures.append(String(describing: error))
            print("ERROR \(error)")
        }
        dispose()
        let report: [String: Any] = ["checks": checks, "failures": failures, "rtc": rtc,
            "host": ProcessInfo.processInfo.operatingSystemVersionString,
            "webkit_bundle_version": Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") ?? "unavailable"]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: output))
        NSApplication.shared.terminate(nil)
    }
}

@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let harness = Harness()
        Task { @MainActor in await harness.run() }
        app.run()
    }
}
