import Foundation

// Test-only stand-ins for unrelated app types. SearchServices.swift is compiled
// whole and unmodified, including its real HTTP and persistence codecs.
enum ErrorLocalization {
    static func lookup(_ text: String) -> String { text }
    static func format(_ text: String, _ args: [String]) -> String {
        String(format: text, arguments: args)
    }
}
struct GeneratedImagePayload { var data: Data; var mimeType: String }

private func require(_ condition: Bool, _ label: String) {
    if !condition { fatalError("FAIL: \(label)") }
}

final class SearchMockProtocol: URLProtocol, @unchecked Sendable {
    // Each test installs its handler before awaiting its one request. There are
    // no concurrent requests, real keys, or external hosts in this harness.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main @MainActor enum SearchProviderContractTests {
    nonisolated static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func search(_ service: SearchServiceConfiguration, _ query: String = "中文 & \"search\" 😀") async throws -> [String: Any] {
            let result = await SearchServiceExecutor.search(query: query, configuration: service,
                common: .init(resultCount: 2, timeoutSeconds: 7), session: session)
            return try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
        }
        func fixture(_ text: String, status: Int = 200) {
            SearchMockProtocol.handler = { _ in (status, Data(text.utf8)) }
        }
        let response = #"{"results":[{"title":"标题","url":"https://example.com/a","summary":"长摘要","snippet":"短摘要","content":"完整正文"}]}"#
        var deepseek = SearchServiceConfiguration(kind: .deepseek, apiKey: "synthetic-key")
        SearchMockProtocol.handler = { request in
            require(request.url?.absoluteString == "https://api.deepseek.com/v1/tools/search", "official endpoint")
            require(request.httpMethod == "POST", "DeepSeek POST")
            require(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key", "Bearer")
            require(request.timeoutInterval == 7, "shared timeout")
            let object = try body(request)
            require(object["query"] as? String == "中文 & \"search\" 😀", "query preserved")
            require(object["count"] as? Int == 2 && object["need_content"] as? Bool == false, "count and content defaults")
            return (200, Data(response.utf8))
        }
        var result = try await search(deepseek)
        require((result["items"] as? [[String: Any]])?.first?["text"] as? String == "长摘要", "summary default")
        deepseek.options["needContent"] = "true"
        SearchMockProtocol.handler = { request in
            require(try body(request)["need_content"] as? Bool == true, "content opt-in")
            return (200, Data(response.utf8))
        }
        result = try await search(deepseek)
        require((result["items"] as? [[String: Any]])?.first?["text"] as? String == "完整正文", "content priority")
        fixture(#"{"results":[{"title":"a","url":"https://example.com","summary":"fallback","content":""}]}"#)
        result = try await search(deepseek)
        require((result["items"] as? [[String: Any]])?.first?["text"] as? String == "fallback", "empty body fallback")
        fixture(#"{"results":[]}"#)
        require(try await search(deepseek)["error"] == nil, "empty results valid")
        for status in [401, 402, 429, 500] {
            fixture(#"{"error":{"message":"do not expose remote secrets"}}"#, status: status)
            result = try await search(deepseek)
            require((result["error"] as? String)?.contains("HTTP \(status)") == true, "HTTP failure \(status)")
            require(!(result["error"] as? String ?? "").contains("remote secrets"), "no raw remote error")
        }
        fixture(#"{"unexpected":[]}"#)
        require(try await search(deepseek)["error"] != nil, "malformed DeepSeek payload rejected")
        SearchMockProtocol.handler = { _ in fatalError("invalid input reached network") }
        require(try await search(deepseek, String(repeating: "中", count: 129))["error"] != nil, "Unicode query bound")
        require(try await search(.init(kind: .deepseek))["error"] != nil, "missing key rejected")

        var custom = SearchServiceConfiguration(kind: .custom, endpoint: "https://example.invalid/search")
        SearchMockProtocol.handler = { request in
            require(request.httpMethod == "POST", "custom default POST")
            require(request.value(forHTTPHeaderField: "Authorization") == nil, "anonymous")
            let object = try body(request)
            require(object["query"] as? String == "中文 & \"search\" 😀" && object["count"] as? Int == 2, "custom JSON")
            return (200, Data(#"{"results":[{"title":"A","url":"https://example.com/a","content":"B"}]}"#.utf8))
        }
        result = try await search(custom)
        require((result["items"] as? [[String: Any]])?.first?["text"] as? String == "B", "custom defaults")
        custom.endpoint += "?q=stale&limit=99&language=zh"
        custom.apiKey = "custom-secret"
        custom.options = ["method":"GET", "queryField":"q", "countField":"limit", "auth":"header",
                          "keyHeader":"X-Search-Key", "resultsPath":"data.hits", "titlePath":"document.name",
                          "urlPath":"document.links.0", "textPath":"document.snippet"]
        SearchMockProtocol.handler = { request in
            require(request.httpMethod == "GET" && request.httpBody == nil, "GET without body")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            require(items.filter { $0.name == "q" }.map(\.value) == ["中文 & \"search\" 😀"], "GET encoded once and replaced")
            require(items.first { $0.name == "limit" }?.value == "2", "count replacement")
            require(items.first { $0.name == "language" }?.value == "zh", "static query retained")
            require(request.value(forHTTPHeaderField: "X-Search-Key") == "custom-secret", "custom auth header")
            return (200, Data(#"{"data":{"hits":[{"document":{"name":"Nested","links":["https://example.com/n"],"snippet":"Nested text"}}]}}"#.utf8))
        }
        result = try await search(custom)
        require((result["items"] as? [[String: Any]])?.first?["text"] as? String == "Nested text", "nested paths")
        custom.options = ["resultsPath":"$", "auth":"none"]
        SearchMockProtocol.handler = { request in
            require(request.value(forHTTPHeaderField: "Authorization") == nil, "explicit no auth")
            return (200, Data(#"[{"title":"A","url":"https://example.com","content":"root"}]"#.utf8))
        }
        require(try await search(custom)["error"] == nil, "top-level array")
        fixture(#"{"wrong":[]}"#)
        require(try await search(custom)["error"] != nil, "bad mapping is not empty success")
        fixture(#"[{"url":"javascript:bad"}]"#)
        require(try await search(custom)["error"] != nil, "bad URL mapping")
        fixture("not JSON")
        require(try await search(custom)["error"] != nil, "non-JSON rejected")
        fixture("[]")
        require(try await search(custom)["error"] == nil, "valid empty custom array")
        custom.options = ["auth":"bearer"]
        SearchMockProtocol.handler = { request in
            require(request.value(forHTTPHeaderField: "Authorization") == "Bearer custom-secret", "custom bearer")
            return (200, Data(#"{"results":[]}"#.utf8))
        }
        require(try await search(custom)["error"] == nil, "custom bearer request")
        let encoded = try JSONEncoder().encode(custom)
        require(!String(decoding: encoded, as: UTF8.self).contains("custom-secret"), "key excluded from ordinary persistence")
        let decoded = try JSONDecoder().decode(SearchServiceConfiguration.self, from: encoded)
        require(decoded.kind == .custom && decoded.options == custom.options && decoded.apiKey.isEmpty, "custom options round trip")
        let old = try JSONDecoder().decode(SearchServiceConfiguration.self, from: Data(#"{"kind":"tavily","apiKey":"legacy"}"#.utf8))
        require(old.kind == .tavily && old.apiKey == "legacy", "legacy migration preserved")
        custom.options = ["queryField":"same", "countField":"same"]
        require(SearchServiceExecutor.configurationError(custom) != nil, "duplicate parameters blocked")
        custom.options = ["auth":"header", "keyHeader":"x\r\ninjection"]
        require(SearchServiceExecutor.configurationError(custom) != nil, "invalid header blocked")
        custom.options = ["method":"DELETE"]
        require(SearchServiceExecutor.configurationError(custom) != nil, "unsupported method blocked")
        for kind: SearchServiceKind in [.tavily, .linkup] {
            for enabled in [false, true] {
                SearchMockProtocol.handler = { request in
                    let json = try body(request)
                    if kind == .tavily {
                        require(json["include_images"] as? Bool == enabled, "Tavily respects image flag")
                        require(json["include_image_descriptions"] as? Bool == enabled, "Tavily image descriptions match")
                    } else {
                        require(json["includeImages"] as? String == (enabled ? "true" : "false"), "Linkup respects image flag")
                    }
                    return (200, Data(#"{"results":[],"sources":[],"images":["https://example.invalid/cat.png"]}"#.utf8))
                }
                let result = await SearchServiceExecutor.searchResponse(query: "cat", configuration: .init(kind: kind, apiKey: "synthetic"),
                    common: .init(resultCount: 1), includeImages: enabled, session: session)
                if !enabled {
                    require(result.images.isEmpty && !result.content.contains("cat.png"), "Disabled images absent from model results")
                }
            }
        }
        print("PASS: Search request/response, image flags, errors, mappings, and persistence. No live API calls.")
    }
}
