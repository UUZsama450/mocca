import Foundation
import Security

enum SearchServiceKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case bingLocal = "bing_local"
    case tavily
    case exa
    case zhipu
    case searxng
    case linkup
    case brave
    case metaso
    case ollama
    case jina
    case bocha
    case duckDuckGo = "duckduckgo"
    case perplexity
    case serper
    case grok
    case querit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bingLocal: "Bing (Local)"
        case .tavily: "Tavily"
        case .exa: "Exa"
        case .zhipu: "Zhipu (智谱)"
        case .searxng: "SearXNG"
        case .linkup: "LinkUp"
        case .brave: "Brave Search"
        case .metaso: "Metaso (秘塔)"
        case .ollama: "Ollama"
        case .jina: "Jina"
        case .bocha: "Bocha"
        case .duckDuckGo: "DuckDuckGo"
        case .perplexity: "Perplexity"
        case .serper: "Serper"
        case .grok: "Grok"
        case .querit: "Querit"
        }
    }

    var description: String {
        switch self {
        case .bingLocal:
            "抓取 Bing 网页搜索结果，无需 API Key，但页面结构变化时可能失效。"
        case .tavily:
            "为大语言模型优化的搜索 API，可返回相关网页与摘要。"
        case .exa:
            "具备语义理解的神经搜索引擎，适合研究和查找特定内容。"
        case .zhipu:
            "智谱 AI 的中文网页搜索服务。"
        case .searxng:
            "可连接自建 SearXNG 实例的隐私元搜索服务。"
        case .linkup:
            "提供来源可追溯答案、网页结果与 AI 摘要。"
        case .brave:
            "Brave 独立搜索引擎，注重隐私。"
        case .metaso:
            "面向中文内容优化的秘塔搜索服务。"
        case .ollama:
            "Ollama 网络搜索 API。"
        case .jina:
            "面向 AI 应用的 Jina Search API。"
        case .bocha:
            "博查 AI 全网网页搜索，支持时效与站点筛选。"
        case .duckDuckGo:
            "无需 API Key 的 DuckDuckGo 隐私搜索，可设置地区。"
        case .perplexity:
            "Perplexity Search API，支持区域与域名过滤。"
        case .serper:
            "Serper Google Search API，支持国家、语言、时间和页码过滤。"
        case .grok:
            "通过 xAI Responses API 使用 Grok 的网页和 X 搜索。"
        case .querit:
            "面向 LLM 的实时网页搜索，支持站点、时间、国家和语言过滤。"
        }
    }

    var brandAssetName: String? {
        switch self {
        case .bingLocal: "SearchBing"
        case .tavily: "SearchTavily"
        case .exa: "SearchExa"
        case .zhipu: "SearchZhipu"
        case .searxng: "SearchSearXNG"
        case .linkup: "SearchLinkUp"
        case .brave: "SearchBrave"
        case .metaso: "SearchMetaso"
        case .ollama: "SearchOllama"
        case .jina: "SearchJina"
        case .bocha: "SearchBocha"
        case .duckDuckGo: "SearchDuckDuckGo"
        case .perplexity: "SearchPerplexity"
        case .serper: "SearchSerper"
        case .grok: "ProviderGrok"
        case .querit: "SearchQuerit"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .bingLocal: "https://www.bing.com/search"
        case .tavily: "https://api.tavily.com/search"
        case .exa: "https://api.exa.ai/search"
        case .zhipu: "https://open.bigmodel.cn/api/paas/v4/web_search"
        case .searxng: ""
        case .linkup: "https://api.linkup.so/v1/search"
        case .brave: "https://api.search.brave.com/res/v1/web/search"
        case .metaso: "https://metaso.cn/api/v1/search"
        case .ollama: "https://ollama.com/api/web_search"
        case .jina: "https://s.jina.ai/"
        case .bocha: "https://api.bochaai.com/v1/web-search"
        case .duckDuckGo: "https://duckduckgo.com/html/"
        case .perplexity: "https://api.perplexity.ai/search"
        case .serper: "https://google.serper.dev/search"
        case .grok: "https://api.x.ai/v1/responses"
        case .querit: "https://api.querit.ai/v1/search"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .bingLocal, .searxng, .duckDuckGo: false
        default: true
        }
    }

    var requiresEndpoint: Bool {
        self == .searxng
    }
}

struct SearchServiceConfiguration: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var kind: SearchServiceKind
    var name: String
    var endpoint: String
    var apiKey: String
    var username: String
    var password: String
    var options: [String: String]

    init(
        id: UUID = UUID(),
        kind: SearchServiceKind,
        name: String = "",
        endpoint: String = "",
        apiKey: String = "",
        username: String = "",
        password: String = "",
        options: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.username = username
        self.password = password
        self.options = options
    }

    var resolvedName: String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? kind.title : cleaned
    }

    var resolvedEndpoint: String {
        let cleaned = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? kind.defaultEndpoint : cleaned
    }

    static var defaultTavily: SearchServiceConfiguration {
        SearchServiceConfiguration(
            id: UUID(uuidString: "00000000-0000-4000-9000-000000000001")!,
            kind: .tavily,
            endpoint: SearchServiceKind.tavily.defaultEndpoint
        )
    }

    static var defaultDuckDuckGo: SearchServiceConfiguration {
        SearchServiceConfiguration(
            id: UUID(uuidString: "00000000-0000-4000-9000-000000000002")!,
            kind: .duckDuckGo,
            endpoint: SearchServiceKind.duckDuckGo.defaultEndpoint
        )
    }

    static func initialService(legacyTavilyAPIKey: String) -> SearchServiceConfiguration {
        guard !legacyTavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultDuckDuckGo
        }
        var configuration = defaultTavily
        configuration.apiKey = legacyTavilyAPIKey
        return configuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, endpoint, apiKey, username, password, options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(SearchServiceKind.self, forKey: .kind) ?? .tavily
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? kind.defaultEndpoint
        // Decode legacy payloads for one-time migration. encode(to:) never writes secrets.
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(username, forKey: .username)
        try container.encode(options, forKey: .options)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(kind)
        hasher.combine(name)
        hasher.combine(endpoint)
        hasher.combine(apiKey)
        hasher.combine(username)
        hasher.combine(password)
        for (key, value) in options.sorted(by: { $0.key < $1.key }) {
            hasher.combine(key)
            hasher.combine(value)
        }
    }
}

struct SearchCommonOptions: Codable, Equatable, Hashable, Sendable {
    private var storedResultCount: Int
    private var storedTimeoutSeconds: Int

    var resultCount: Int {
        get { storedResultCount }
        set { storedResultCount = Self.clamp(newValue, to: 1...50) }
    }

    var timeoutSeconds: Int {
        get { storedTimeoutSeconds }
        set { storedTimeoutSeconds = Self.clamp(newValue, to: 1...30) }
    }

    init(resultCount: Int = 10, timeoutSeconds: Int = 5) {
        storedResultCount = Self.clamp(resultCount, to: 1...50)
        storedTimeoutSeconds = Self.clamp(timeoutSeconds, to: 1...30)
    }

    private enum CodingKeys: String, CodingKey {
        case resultCount, timeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            resultCount: try container.decodeIfPresent(Int.self, forKey: .resultCount) ?? 10,
            timeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 5
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resultCount, forKey: .resultCount)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum SearchSecretStore {
    private static let service = "com.uuzsama450.mocca.search"

    static func hydrate(_ configuration: SearchServiceConfiguration) -> SearchServiceConfiguration {
        var result = configuration
        let storedAPIKey = value(for: account(configuration.id, field: "apiKey"))
        let storedPassword = value(for: account(configuration.id, field: "password"))
        if !storedAPIKey.isEmpty { result.apiKey = storedAPIKey }
        if !storedPassword.isEmpty { result.password = storedPassword }
        return result
    }

    static func hydrate(_ configurations: [SearchServiceConfiguration]) -> [SearchServiceConfiguration] {
        configurations.map(hydrate)
    }

    @discardableResult
    static func persist(_ configuration: SearchServiceConfiguration) -> Bool {
        let apiKeySaved = set(
            configuration.apiKey,
            for: account(configuration.id, field: "apiKey")
        )
        let passwordSaved = set(
            configuration.password,
            for: account(configuration.id, field: "password")
        )
        return apiKeySaved && passwordSaved
    }

    @discardableResult
    static func persist(_ configurations: [SearchServiceConfiguration]) -> Bool {
        configurations.map { persist($0) }.allSatisfy { $0 }
    }

    static func remove(_ configuration: SearchServiceConfiguration) {
        remove(for: configuration.id)
    }

    static func remove(for configurationID: UUID) {
        removeValue(for: account(configurationID, field: "apiKey"))
        removeValue(for: account(configurationID, field: "password"))
    }

    private static func account(_ id: UUID, field: String) -> String {
        "\(id.uuidString).\(field)"
    }

    private static func value(for account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func set(_ value: String, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess {
            return true
        }
        guard status == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private static func removeValue(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum SearchServiceExecutor {
    static func configurationError(_ configuration: SearchServiceConfiguration) -> String? {
        configurationError(for: configuration)
    }

    static func configurationError(for configuration: SearchServiceConfiguration) -> String? {
        if configuration.kind.requiresAPIKey,
           configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ErrorLocalization.format("请填写 %@ API Key。", [configuration.kind.title])
        }
        let endpoint = configuration.resolvedEndpoint
        if endpoint.isEmpty {
            return ErrorLocalization.format("请填写 %@ 服务地址。", [configuration.kind.title])
        }
        guard let components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return ErrorLocalization.format("%@ 服务地址无效。", [configuration.kind.title])
        }
        return nil
    }

    static func search(
        query: String,
        configuration: SearchServiceConfiguration,
        common: SearchCommonOptions,
        includeImages: Bool = false,
        session: URLSession = .shared
    ) async -> String {
        await searchResponse(
            query: query,
            configuration: configuration,
            common: common,
            includeImages: includeImages,
            session: session
        ).content
    }

    static func searchResponse(
        query: String,
        configuration: SearchServiceConfiguration,
        common: SearchCommonOptions,
        includeImages: Bool = false,
        session: URLSession = .shared
    ) async -> SearchServiceResponse {
        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuery.isEmpty else {
            return SearchServiceResponse(
                content: errorJSON("搜索关键词不能为空。"),
                images: []
            )
        }

        let effective = configuration
        if let error = configurationError(effective) {
            return SearchServiceResponse(content: errorJSON(error), images: [])
        }

        // Provider implementations are filled below in the same file. Keeping this
        // public entry point stable lets persistence and settings compile independently.
        do {
            var result = try await execute(
                query: cleanedQuery,
                configuration: effective,
                common: common,
                session: session
            )
            if includeImages {
                let imageLimit = min(max(common.resultCount, 1), 6)
                if result.images.count < imageLimit {
                    let discovered = await pagePreviewImages(
                        from: result.items,
                        limit: imageLimit - result.images.count,
                        timeoutSeconds: common.timeoutSeconds,
                        session: session
                    )
                    result.images.append(contentsOf: discovered)
                }
            } else {
                result.images.removeAll(keepingCapacity: false)
            }
            return serviceResponse(result, limit: common.resultCount)
        } catch let error as SearchExecutionError {
            return SearchServiceResponse(content: errorJSON(error.message), images: [])
        } catch let error as URLError {
            return SearchServiceResponse(
                content: errorJSON("\(effective.resolvedName) 网络请求失败（\(error.code.rawValue)）。"),
                images: []
            )
        } catch is CancellationError {
            return SearchServiceResponse(content: errorJSON("搜索已取消。"), images: [])
        } catch {
            return SearchServiceResponse(
                content: errorJSON("\(effective.resolvedName) 搜索失败。"),
                images: []
            )
        }
    }
}

struct SearchServiceResponse: Sendable {
    let content: String
    let images: [SearchImageCandidate]
}

struct SearchImageCandidate: Hashable, Sendable {
    let id: String
    let title: String
    let url: String
    let sourceURL: String?
}

struct SearchImageRequest: Hashable, Sendable {
    let candidate: SearchImageCandidate
}

enum SearchImageSelectionCodec {
    struct Parsed: Sendable {
        let displayText: String
        let requests: [SearchImageRequest]
    }

    private static let openingMarker = "<ks-image>"
    private static let fullPattern = #"(?is)<ks-image>\s*(\{.*?\})\s*</ks-image>"#
    private static let fullRegex = try! NSRegularExpression(pattern: fullPattern)

    static func parse(
        _ text: String,
        candidates: [SearchImageCandidate]
    ) -> Parsed {
        // Every complete marker requires this literal byte, irrespective of
        // the regex's case folding. Keep malformed/control-looking text on
        // the existing parser path, and skip ordinary final prose entirely.
        guard text.utf8.contains(0x3C) else { return Parsed(displayText: text, requests: []) }
        let nsText = text as NSString
        let matches = fullRegex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else {
            return Parsed(displayText: text, requests: [])
        }
        let candidatesByID = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        let requests = matches.compactMap { match -> SearchImageRequest? in
            guard match.numberOfRanges > 1,
                  match.range(at: 1).location != NSNotFound else { return nil }
            let json = nsText.substring(with: match.range(at: 1))
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let candidate = candidatesByID[id],
                  seen.insert(id).inserted else { return nil }
            return SearchImageRequest(candidate: candidate)
        }
        .prefix(4)
        .map { $0 }
        let stripped = fullRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: ""
        )
        return Parsed(
            displayText: stripped,
            requests: requests
        )
    }

    static func stripForDisplay(_ text: String) -> String {
        // Most replies never contain an image-selection control block. Avoid
        // running the full regular expression over the growing stream unless
        // its opening marker is actually present. The existing parser and
        // trailing-marker behavior remain unchanged for matching input.
        guard text.range(
            of: openingMarker,
            options: .caseInsensitive
        ) != nil else {
            return text
        }
        let parsed = parse(text, candidates: []).displayText
        if let markerStart = parsed.range(
            of: openingMarker,
            options: [.caseInsensitive, .backwards]
        )?.lowerBound {
            return String(parsed[..<markerStart])
        }
        return parsed
    }
}

enum SearchImageDownloadError: LocalizedError {
    case invalidURL
    case invalidResponse
    case tooLarge
    case notImage

    var errorDescription: String? {
        switch self {
        case .invalidURL: ErrorLocalization.lookup("搜索图片地址无效")
        case .invalidResponse: ErrorLocalization.lookup("搜索图片下载失败")
        case .tooLarge: ErrorLocalization.lookup("搜索图片超过 12 MB 限制")
        case .notImage: ErrorLocalization.lookup("搜索结果返回的内容不是图片")
        }
    }
}

enum SearchImageDownloadService {
    private static let maximumByteCount = 12 * 1_024 * 1_024

    static func download(
        _ candidate: SearchImageCandidate,
        session: URLSession = .shared
    ) async throws -> GeneratedImagePayload {
        guard let url = URL(string: candidate.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SearchImageDownloadError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 24
        request.setValue("image/avif,image/webp,image/*,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        if let sourceURL = candidate.sourceURL,
           let referer = URL(string: sourceURL),
           let scheme = referer.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SearchImageDownloadError.invalidResponse
        }
        if response.expectedContentLength > Int64(maximumByteCount) {
            throw SearchImageDownloadError.tooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumByteCount))
        }
        for try await byte in bytes {
            guard data.count < maximumByteCount else {
                throw SearchImageDownloadError.tooLarge
            }
            data.append(byte)
        }
        guard !data.isEmpty else { throw SearchImageDownloadError.invalidResponse }

        let rawMIMEType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if let rawMIMEType,
           !rawMIMEType.hasPrefix("image/"),
           rawMIMEType != "application/octet-stream" {
            throw SearchImageDownloadError.notImage
        }
        return GeneratedImagePayload(
            data: data,
            mimeType: rawMIMEType ?? "image/jpeg"
        )
    }
}

private struct SearchExecutionResult {
    var answer: String?
    var items: [SearchExecutionItem]
    var images: [SearchExecutionImage] = []
}

private struct SearchExecutionItem: Sendable {
    var title: String
    var url: String
    var text: String
}

private struct SearchExecutionImage: Sendable {
    var title: String
    var url: String
    var sourceURL: String?
}

private enum SearchExecutionError: Error {
    case invalidRequest(String)
    case invalidResponse(String)
    case httpStatus(String, Int)
    case provider(String)

    var message: String {
        switch self {
        case .invalidRequest(let provider): "\(provider) 请求地址无效。"
        case .invalidResponse(let provider): "\(provider) 返回了无法识别的数据。"
        case .httpStatus(let provider, let status): "\(provider) 返回 HTTP \(status)。"
        case .provider(let message): message
        }
    }
}

private extension SearchServiceExecutor {
    static func execute(
        query: String,
        configuration: SearchServiceConfiguration,
        common: SearchCommonOptions,
        session: URLSession
    ) async throws -> SearchExecutionResult {
        switch configuration.kind {
        case .bingLocal:
            return try await bingSearch(query, configuration, common, session)
        case .tavily:
            return try await tavilySearch(query, configuration, common, session)
        case .exa:
            return try await exaSearch(query, configuration, common, session)
        case .zhipu:
            return try await zhipuSearch(query, configuration, common, session)
        case .searxng:
            return try await searXNGSearch(query, configuration, common, session)
        case .linkup:
            return try await linkUpSearch(query, configuration, common, session)
        case .brave:
            return try await braveSearch(query, configuration, common, session)
        case .metaso:
            return try await metasoSearch(query, configuration, common, session)
        case .ollama:
            return try await ollamaSearch(query, configuration, common, session)
        case .jina:
            return try await jinaSearch(query, configuration, common, session)
        case .bocha:
            return try await bochaSearch(query, configuration, common, session)
        case .duckDuckGo:
            return try await duckDuckGoSearch(query, configuration, common, session)
        case .perplexity:
            return try await perplexitySearch(query, configuration, common, session)
        case .serper:
            return try await serperSearch(query, configuration, common, session)
        case .grok:
            return try await grokSearch(query, configuration, common, session)
        case .querit:
            return try await queritSearch(query, configuration, common, session)
        }
    }

    // MARK: - Providers

    static func bingSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let data = try await performGETRequest(
            endpoint: configuration.resolvedEndpoint,
            queryItems: [URLQueryItem(name: "q", value: query)],
            headers: [
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
                "Accept-Language": option(configuration, "acceptLanguage", default: "en-US,en;q=0.9")
            ],
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchExecutionError.invalidResponse(configuration.resolvedName)
        }
        let items = bingItems(html).prefix(common.resultCount).map { $0 }
        if items.isEmpty, bingChallengePage(html) {
            throw SearchExecutionError.provider(
                "\(configuration.resolvedName) 要求完成网页验证，暂时无法搜索。"
            )
        }
        return SearchExecutionResult(
            answer: nil,
            items: items
        )
    }

    static func tavilySearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let body: [String: Any] = [
            "query": query,
            "max_results": common.resultCount,
            "include_images": true,
            "include_image_descriptions": true,
        ]
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: body,
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        return SearchExecutionResult(
            answer: string(object["answer"]),
            items: resultItems(
                object["results"],
                titleKeys: ["title"],
                urlKeys: ["url"],
                textKeys: ["content"]
            ),
            images: imageItems(object["images"])
                + imagesFromResults(object["results"])
        )
    }

    static func exaSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: [
                "query": query,
                "numResults": common.resultCount,
                "contents": ["text": true]
            ],
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        return SearchExecutionResult(
            answer: nil,
            items: resultItems(
                object["results"],
                titleKeys: ["title"],
                urlKeys: ["url"],
                textKeys: ["text"]
            ),
            images: imagesFromResults(object["results"])
        )
    }

    static func zhipuSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: [
                "search_query": query,
                "search_engine": "search_std",
                "count": common.resultCount
            ],
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        return SearchExecutionResult(
            answer: nil,
            items: resultItems(
                object["search_result"],
                titleKeys: ["title"],
                urlKeys: ["link"],
                textKeys: ["content"]
            ),
            images: imagesFromResults(object["search_result"])
        )
    }

    static func searXNGSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        guard var endpoint = URL(string: configuration.resolvedEndpoint) else {
            throw SearchExecutionError.invalidRequest(configuration.resolvedName)
        }
        if !endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("search") {
            endpoint.appendPathComponent("search")
        }
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json")
        ]
        if let engines = nonemptyOption(configuration, "engines") {
            queryItems.append(URLQueryItem(name: "engines", value: engines))
        }
        if let language = nonemptyOption(configuration, "language") {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        var headers: [String: String] = [:]
        if !configuration.username.isEmpty && !configuration.password.isEmpty {
            let credentials = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(credentials)"
        }
        let data = try await performGETRequest(
            endpoint: endpoint.absoluteString,
            queryItems: queryItems,
            headers: headers,
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        return SearchExecutionResult(
            answer: nil,
            items: Array(resultItems(
                object["results"],
                titleKeys: ["title"],
                urlKeys: ["url"],
                textKeys: ["content"]
            ).prefix(common.resultCount)),
            images: imageItems(object["results"], allowPlainURL: false)
                + imagesFromResults(object["results"])
        )
    }

    static func linkUpSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: [
                "q": query,
                "depth": "standard",
                "outputType": "sourcedAnswer",
                "includeImages": "true"
            ],
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        let rawSources = object["sources"] ?? object["results"]
        return SearchExecutionResult(
            answer: string(object["answer"]),
            items: Array(resultItems(
                rawSources,
                titleKeys: ["name", "title"],
                urlKeys: ["url"],
                textKeys: ["snippet", "content"]
            ).prefix(common.resultCount)),
            images: imageItems(object["images"])
                + imageItems(rawSources, allowPlainURL: false)
                + imagesFromResults(rawSources)
        )
    }

    static func braveSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let data = try await performGETRequest(
            endpoint: configuration.resolvedEndpoint,
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "count", value: String(common.resultCount))
            ],
            headers: [
                "Accept": "application/json",
                "X-Subscription-Token": configuration.apiKey
            ],
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        let web = object["web"] as? [String: Any]
        return SearchExecutionResult(
            answer: nil,
            items: resultItems(
                web?["results"],
                titleKeys: ["title"],
                urlKeys: ["url"],
                textKeys: ["description"]
            ),
            images: imagesFromResults(web?["results"])
        )
    }

    static func metasoSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: [
                "Authorization": "Bearer \(configuration.apiKey)",
                "Accept": "application/json"
            ],
            body: [
                "q": query,
                "scope": "webpage",
                "size": common.resultCount,
                "includeSummary": false
            ],
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        return SearchExecutionResult(
            answer: nil,
            items: resultItems(
                object["webpages"],
                titleKeys: ["title"],
                urlKeys: ["link"],
                textKeys: ["snippet"]
            )
        )
    }

    static func ollamaSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: ["query": query, "max_results": min(common.resultCount, 10)],
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        return SearchExecutionResult(
            answer: nil,
            items: resultItems(
                object["results"],
                titleKeys: ["title"],
                urlKeys: ["url"],
                textKeys: ["content"]
            )
        )
    }

    static func jinaSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: [
                "Authorization": "Bearer \(configuration.apiKey)",
                "Accept": "application/json"
            ],
            body: ["q": query],
            timeout: max(common.timeoutSeconds, 15),
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        return SearchExecutionResult(
            answer: nil,
            items: Array(resultItems(
                object["data"] ?? object["results"],
                titleKeys: ["title"],
                urlKeys: ["url"],
                textKeys: ["description", "content"]
            ).prefix(common.resultCount))
        )
    }

    static func bochaSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        var body: [String: Any] = [
            "query": query,
            "summary": boolOption(configuration, "summary", default: true),
            "count": common.resultCount
        ]
        for key in ["freshness", "include", "exclude"] {
            if let value = nonemptyOption(configuration, key) { body[key] = value }
        }
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: body,
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        if let code = integer(object["code"]), code != 200 {
            throw SearchExecutionError.provider("\(configuration.resolvedName) 返回服务错误（\(code)）。")
        }
        let payload = object["data"] as? [String: Any]
        let webPages = payload?["webPages"] as? [String: Any]
        return SearchExecutionResult(
            answer: nil,
            items: Array(resultItems(
                webPages?["value"],
                titleKeys: ["name", "title"],
                urlKeys: ["url"],
                textKeys: ["summary", "snippet"]
            ).prefix(common.resultCount))
        )
    }

    static func duckDuckGoSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let data = try await performGETRequest(
            endpoint: configuration.resolvedEndpoint,
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "kl", value: option(configuration, "region", default: "us-en")),
                URLQueryItem(name: "p", value: "0")
            ],
            headers: [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
            ],
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchExecutionError.invalidResponse(configuration.resolvedName)
        }
        return SearchExecutionResult(
            answer: nil,
            items: Array(duckDuckGoItems(html).prefix(common.resultCount))
        )
    }

    static func perplexitySearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        var body: [String: Any] = [
            "query": query,
            "max_results": min(common.resultCount, 20)
        ]
        if let country = nonemptyOption(configuration, "country") { body["country"] = country }
        let domains = listOption(configuration, "searchDomainFilter")
        if !domains.isEmpty { body["search_domain_filter"] = domains }
        if let tokens = intOption(configuration, "maxTokensPerPage"), tokens > 0 {
            body["max_tokens_per_page"] = tokens
        }
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: body,
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        let flattened = flattenResultArray(object["results"])
        return SearchExecutionResult(
            answer: nil,
            items: Array(resultItems(
                flattened,
                titleKeys: ["title"],
                urlKeys: ["url"],
                textKeys: ["snippet", "text"]
            ).prefix(common.resultCount))
        )
    }

    static func serperSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        var body: [String: Any] = ["q": query]
        for key in ["gl", "hl", "tbs"] {
            if let value = nonemptyOption(configuration, key) { body[key] = value }
        }
        if let page = intOption(configuration, "page"), page > 1 { body["page"] = page }
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: ["X-API-KEY": configuration.apiKey],
            body: body,
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        return SearchExecutionResult(
            answer: nil,
            items: Array(resultItems(
                object["organic"],
                titleKeys: ["title"],
                urlKeys: ["link"],
                textKeys: ["snippet"]
            ).prefix(common.resultCount)),
            images: imageItems(object["images"])
                + imagesFromResults(object["organic"])
        )
    }

    static func grokSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        let model = option(configuration, "model", default: "grok-4.3")
        let systemPrompt = option(
            configuration,
            "systemPrompt",
            default: "You are a helpful search assistant. Search the web to find accurate and up-to-date information for the user's query. Provide a comprehensive answer with citations."
        )
        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": query]
            ],
            "tools": [["type": "web_search"], ["type": "x_search"]],
            "store": false,
            "stream": false
        ]
        if let effort = nonemptyOption(configuration, "reasoningEffort") {
            body["reasoning"] = ["effort": effort]
        } else if model == "grok-4.3" {
            body["reasoning"] = ["effort": "none"]
        }
        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: body,
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        let parsed = grokOutput(object, limit: common.resultCount)
        return SearchExecutionResult(answer: parsed.answer, items: parsed.items)
    }

    static func queritSearch(
        _ query: String,
        _ configuration: SearchServiceConfiguration,
        _ common: SearchCommonOptions,
        _ session: URLSession
    ) async throws -> SearchExecutionResult {
        var body: [String: Any] = ["query": query, "count": common.resultCount]
        let sitesInclude = listOption(configuration, "sitesInclude")
        let sitesExclude = listOption(configuration, "sitesExclude")
        var filters: [String: Any] = [:]
        if !sitesInclude.isEmpty || !sitesExclude.isEmpty {
            var sites: [String: Any] = [:]
            if !sitesInclude.isEmpty { sites["include"] = sitesInclude }
            if !sitesExclude.isEmpty { sites["exclude"] = sitesExclude }
            filters["sites"] = sites
        }
        if let timeRange = nonemptyOption(configuration, "timeRange") {
            filters["timeRange"] = ["date": timeRange]
        }
        let countries = listOption(configuration, "countries")
        if !countries.isEmpty { filters["geo"] = ["countries": ["include": countries]] }
        let languages = listOption(configuration, "languages")
        if !languages.isEmpty { filters["languages"] = ["include": languages] }
        if !filters.isEmpty { body["filters"] = filters }

        let data = try await performJSONRequest(
            endpoint: configuration.resolvedEndpoint,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: body,
            timeout: common.timeoutSeconds,
            provider: configuration.resolvedName,
            session: session
        )
        let object = try jsonObject(data, provider: configuration.resolvedName)
        if let code = integer(object["error_code"]), code != 200 {
            throw SearchExecutionError.provider("\(configuration.resolvedName) 返回服务错误（\(code)）。")
        }
        let resultsObject = object["results"] as? [String: Any]
        let raw = resultsObject?["result"] ?? object["results"]
        let values = raw as? [Any] ?? []
        let items = values.compactMap { value -> SearchExecutionItem? in
            guard let item = value as? [String: Any] else { return nil }
            let url = firstString(item, keys: ["url", "link"])
            let base = firstString(item, keys: ["snippet", "text"])
            var snippets: [String] = []
            let rawSnippets = (item["snippets"] as? [Any]) ?? (item["sentence"] as? [Any]) ?? []
            snippets.append(contentsOf: rawSnippets.compactMap(string))
            let cleanedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
            let extraSnippets = snippets
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != cleanedBase }
            let combined = ([cleanedBase] + extraSnippets)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            return SearchExecutionItem(
                title: firstString(item, keys: ["title"]).isEmpty ? url : firstString(item, keys: ["title"]),
                url: url,
                text: combined
            )
        }
        return SearchExecutionResult(answer: nil, items: Array(items.prefix(common.resultCount)))
    }

    // MARK: - HTTP

    static func performJSONRequest(
        endpoint: String,
        headers: [String: String],
        body: [String: Any],
        timeout: Int,
        provider: String,
        session: URLSession
    ) async throws -> Data {
        guard let url = URL(string: endpoint) else {
            throw SearchExecutionError.invalidRequest(provider)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request, provider: provider, session: session)
    }

    static func performGETRequest(
        endpoint: String,
        queryItems: [URLQueryItem],
        headers: [String: String],
        timeout: Int,
        provider: String,
        session: URLSession
    ) async throws -> Data {
        guard var components = URLComponents(string: endpoint) else {
            throw SearchExecutionError.invalidRequest(provider)
        }
        components.queryItems = (components.queryItems ?? []) + queryItems
        guard let url = components.url else {
            throw SearchExecutionError.invalidRequest(provider)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(timeout)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try await perform(request, provider: provider, session: session)
    }

    static func perform(
        _ request: URLRequest,
        provider: String,
        session: URLSession
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SearchExecutionError.invalidResponse(provider)
        }
        guard http.statusCode == 200 else {
            throw SearchExecutionError.httpStatus(provider, http.statusCode)
        }
        return data
    }

    static func pagePreviewImages(
        from items: [SearchExecutionItem],
        limit: Int,
        timeoutSeconds: Int,
        session: URLSession
    ) async -> [SearchExecutionImage] {
        guard limit > 0, !items.isEmpty else { return [] }
        let fetchCount = min(items.count, min(max(limit + 2, 4), 8))
        let indexedItems = Array(items.prefix(fetchCount).enumerated())

        return await withTaskGroup(
            of: (Int, SearchExecutionImage?).self,
            returning: [SearchExecutionImage].self
        ) { group in
            for (index, item) in indexedItems {
                group.addTask {
                    let image = await pagePreviewImage(
                        for: item,
                        timeoutSeconds: timeoutSeconds,
                        session: session
                    )
                    return (index, image)
                }
            }

            var resolved: [(Int, SearchExecutionImage)] = []
            for await (index, image) in group {
                if let image { resolved.append((index, image)) }
            }

            var seen = Set<String>()
            return resolved
                .sorted { $0.0 < $1.0 }
                .compactMap { _, image in
                    guard seen.insert(image.url).inserted else { return nil }
                    return image
                }
                .prefix(limit)
                .map { $0 }
        }
    }

    static func pagePreviewImage(
        for item: SearchExecutionItem,
        timeoutSeconds: Int,
        session: URLSession
    ) async -> SearchExecutionImage? {
        guard let pageURL = URL(string: normalizeURL(item.url)),
              let scheme = pageURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        var request = URLRequest(url: pageURL)
        request.timeoutInterval = TimeInterval(min(max(timeoutSeconds, 2), 8))
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            if let mimeType = http.mimeType?.lowercased(),
               mimeType != "text/html" && mimeType != "application/xhtml+xml" {
                return nil
            }

            let maximumHTMLByteCount = 768 * 1_024
            var data = Data()
            data.reserveCapacity(96 * 1_024)
            for try await byte in bytes {
                if data.count >= maximumHTMLByteCount { break }
                data.append(byte)
            }
            guard let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1),
                  let rawImageURL = pagePreviewImageURL(in: html) else { return nil }
            let baseURL = http.url ?? pageURL
            guard let imageURL = URL(string: htmlDecode(rawImageURL), relativeTo: baseURL)?.absoluteURL,
                  let imageScheme = imageURL.scheme?.lowercased(),
                  imageScheme == "http" || imageScheme == "https" else { return nil }
            return SearchExecutionImage(
                title: item.title,
                url: imageURL.absoluteString,
                sourceURL: baseURL.absoluteString
            )
        } catch {
            return nil
        }
    }

    static func pagePreviewImageURL(in html: String) -> String? {
        let patterns = [
            #"<meta\b[^>]*(?:property|name)\s*=\s*[\"'](?:og:image(?::url)?|twitter:image(?::src)?)[\"'][^>]*content\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#,
            #"<meta\b[^>]*content\s*=\s*[\"']([^\"']+)[\"'][^>]*(?:property|name)\s*=\s*[\"'](?:og:image(?::url)?|twitter:image(?::src)?)[\"'][^>]*>"#,
            #"<link\b[^>]*rel\s*=\s*[\"']image_src[\"'][^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#,
            #"<link\b[^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*rel\s*=\s*[\"']image_src[\"'][^>]*>"#
        ]
        for pattern in patterns {
            if let match = firstMatch(pattern, in: html), !match.isEmpty {
                return match
            }
        }
        return nil
    }

    // MARK: - JSON parsing

    static func jsonObject(_ data: Data, provider: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchExecutionError.invalidResponse(provider)
        }
        return object
    }

    static func resultItems(
        _ raw: Any?,
        titleKeys: [String],
        urlKeys: [String],
        textKeys: [String]
    ) -> [SearchExecutionItem] {
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { value in
            guard let item = value as? [String: Any] else { return nil }
            if string(item["type"])?.lowercased() == "image" {
                return nil
            }
            return SearchExecutionItem(
                title: firstString(item, keys: titleKeys),
                url: firstString(item, keys: urlKeys),
                text: firstString(item, keys: textKeys)
            )
        }
    }

    static func imageItems(
        _ raw: Any?,
        sourceURL: String? = nil,
        fallbackTitle: String = "",
        allowPlainURL: Bool = true
    ) -> [SearchExecutionImage] {
        guard let raw, !(raw is NSNull) else { return [] }
        if let value = string(raw) {
            guard allowPlainURL else { return [] }
            return [SearchExecutionImage(
                title: fallbackTitle,
                url: value,
                sourceURL: sourceURL
            )]
        }
        if let values = raw as? [Any] {
            return values.flatMap {
                imageItems(
                    $0,
                    sourceURL: sourceURL,
                    fallbackTitle: fallbackTitle,
                    allowPlainURL: allowPlainURL
                )
            }
        }
        guard let object = raw as? [String: Any] else { return [] }

        let type = string(object["type"])?.lowercased()
        let title = firstString(object, keys: ["description", "title", "name"])
        let resolvedTitle = title.isEmpty ? fallbackTitle : title
        let pageURL = firstString(object, keys: ["source_url", "sourceUrl", "page_url", "pageUrl", "link"])
        let resolvedSourceURL = pageURL.isEmpty ? sourceURL : pageURL
        var images: [SearchExecutionImage] = []

        for key in [
            "img_src", "image_url", "imageUrl", "thumbnail_src",
            "thumbnailUrl", "thumbnail", "image", "src"
        ] {
            guard let value = object[key] else { continue }
            images.append(contentsOf: imageItems(
                value,
                sourceURL: resolvedSourceURL ?? firstString(object, keys: ["url"]),
                fallbackTitle: resolvedTitle,
                allowPlainURL: true
            ))
        }

        if images.isEmpty,
           (allowPlainURL || type == "image"),
           let url = string(object["url"]),
           !url.isEmpty {
            images.append(SearchExecutionImage(
                title: resolvedTitle,
                url: url,
                sourceURL: resolvedSourceURL
            ))
        }
        return images
    }

    static func imagesFromResults(_ raw: Any?) -> [SearchExecutionImage] {
        guard let values = raw as? [Any] else { return [] }
        return values.flatMap { value -> [SearchExecutionImage] in
            guard let object = value as? [String: Any] else { return [] }
            let sourceURL = firstString(object, keys: ["url", "link"])
            let title = firstString(object, keys: ["title", "name"])
            var images = imageItems(
                object,
                sourceURL: sourceURL.isEmpty ? nil : sourceURL,
                fallbackTitle: title,
                allowPlainURL: false
            )
            for key in ["images", "image_results", "imageResults"] {
                images.append(contentsOf: imageItems(
                    object[key],
                    sourceURL: sourceURL.isEmpty ? nil : sourceURL,
                    fallbackTitle: title,
                    allowPlainURL: true
                ))
            }
            return images
        }
    }

    static func flattenResultArray(_ raw: Any?) -> [Any] {
        guard let values = raw as? [Any] else { return [] }
        return values.flatMap { value -> [Any] in
            if let nested = value as? [Any] { return nested }
            return [value]
        }
    }

    static func grokOutput(
        _ object: [String: Any],
        limit: Int
    ) -> (answer: String?, items: [SearchExecutionItem]) {
        var answer: String?
        var citations: [(url: String, title: String)] = []

        if let rawCitations = object["citations"] as? [Any] {
            citations.append(contentsOf: rawCitations.compactMap(citation))
        }
        if let outputs = object["output"] as? [Any] {
            for rawOutput in outputs {
                guard let output = rawOutput as? [String: Any],
                      string(output["type"]) == "message" else { continue }
                if let role = string(output["role"]), role != "assistant" { continue }
                guard let contents = output["content"] as? [Any] else { continue }
                for rawContent in contents {
                    guard let content = rawContent as? [String: Any] else { continue }
                    if answer == nil,
                       (string(content["type"]) == nil || string(content["type"]) == "output_text"),
                       let text = string(content["text"]), !text.isEmpty {
                        answer = text
                    }
                    if let annotations = content["annotations"] as? [Any] {
                        citations.append(contentsOf: annotations.compactMap(citation))
                    }
                }
            }
        }

        var seen = Set<String>()
        let items = citations.compactMap { citation -> SearchExecutionItem? in
            let url = normalizeURL(citation.url)
            guard !url.isEmpty, seen.insert(url).inserted else { return nil }
            return SearchExecutionItem(
                title: citation.title.isEmpty ? url : citation.title,
                url: url,
                text: ""
            )
        }
        return (answer, Array(items.prefix(limit)))
    }

    static func citation(_ raw: Any) -> (url: String, title: String)? {
        if let url = string(raw), !url.isEmpty { return (url, "") }
        guard let object = raw as? [String: Any],
              string(object["type"]) == "url_citation" else { return nil }
        guard let url = string(object["url"]), !url.isEmpty else { return nil }
        return (url, string(object["title"]) ?? "")
    }

    static func firstString(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = string(object[key]), !value.isEmpty { return value }
        }
        return ""
    }

    static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    // MARK: - Options

    static func nonemptyOption(_ configuration: SearchServiceConfiguration, _ key: String) -> String? {
        guard let value = configuration.options[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func option(
        _ configuration: SearchServiceConfiguration,
        _ key: String,
        default defaultValue: String
    ) -> String {
        nonemptyOption(configuration, key) ?? defaultValue
    }

    static func boolOption(
        _ configuration: SearchServiceConfiguration,
        _ key: String,
        default defaultValue: Bool
    ) -> Bool {
        guard let raw = nonemptyOption(configuration, key)?.lowercased() else { return defaultValue }
        switch raw {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return defaultValue
        }
    }

    static func intOption(_ configuration: SearchServiceConfiguration, _ key: String) -> Int? {
        nonemptyOption(configuration, key).flatMap(Int.init)
    }

    static func listOption(_ configuration: SearchServiceConfiguration, _ key: String) -> [String] {
        guard let raw = nonemptyOption(configuration, key) else { return [] }
        return raw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - HTML parsing

    static func bingItems(_ html: String) -> [SearchExecutionItem] {
        htmlBlocks(
            html,
            openingPattern: #"<li\b[^>]*class\s*=\s*[\"'][^\"']*\bb_algo\b[^\"']*[\"'][^>]*>"#
        ).compactMap { block in
            guard let heading = firstMatch(#"<h2\b[^>]*>(.*?)</h2>"#, in: block),
                  let anchor = firstMatch(#"<a\b[^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#, in: heading, groups: [1, 2]),
                  anchor.count == 2 else { return nil }
            let snippet = firstMatch(
                #"<(?:p|div)\b[^>]*class\s*=\s*[\"'][^\"']*(?:b_caption|b_algoSlug)[^\"']*[\"'][^>]*>(.*?)</(?:p|div)>"#,
                in: block
            ) ?? ""
            return SearchExecutionItem(
                title: plainText(anchor[1]),
                url: htmlDecode(anchor[0]),
                text: plainText(snippet)
            )
        }
    }

    static func bingChallengePage(_ html: String) -> Bool {
        let lowercased = html.lowercased()
        return lowercased.contains("one last step")
            || lowercased.contains("turnstile")
            || lowercased.contains("cf-chl-")
    }

    static func duckDuckGoItems(_ html: String) -> [SearchExecutionItem] {
        htmlBlocks(
            html,
            openingPattern: #"<div\b[^>]*class\s*=\s*[\"'][^\"']*\bresult\b[^\"']*[\"'][^>]*>"#
        ).compactMap { block in
            guard let anchor = firstMatch(
                #"<a\b[^>]*class\s*=\s*[\"'][^\"']*\bresult__a\b[^\"']*[\"'][^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#,
                in: block,
                groups: [1, 2]
            ) ?? firstMatch(
                #"<a\b[^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*class\s*=\s*[\"'][^\"']*\bresult__a\b[^\"']*[\"'][^>]*>(.*?)</a>"#,
                in: block,
                groups: [1, 2]
            ), anchor.count == 2 else { return nil }
            let visibleURL = firstMatch(
                #"<[^>]*class\s*=\s*[\"'][^\"']*\bresult__url\b[^\"']*[\"'][^>]*>(.*?)</[^>]+>"#,
                in: block
            )
            let snippet = firstMatch(
                #"<[^>]*class\s*=\s*[\"'][^\"']*\bresult__snippet\b[^\"']*[\"'][^>]*>(.*?)</[^>]+>"#,
                in: block
            ) ?? ""
            let href = htmlDecode(anchor[0])
            return SearchExecutionItem(
                title: plainText(anchor[1]),
                url: href.isEmpty ? plainText(visibleURL ?? "") : href,
                text: plainText(snippet)
            )
        }
    }

    static func htmlBlocks(_ html: String, openingPattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: openingPattern,
            options: [.caseInsensitive]
        ) else { return [] }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = expression.matches(in: html, range: fullRange)
        return matches.enumerated().compactMap { index, match in
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : fullRange.length
            guard end > start,
                  let range = Range(NSRange(location: start, length: end - start), in: html) else { return nil }
            return String(html[range])
        }
    }

    static func firstMatch(
        _ pattern: String,
        in source: String,
        groups: [Int] = [1]
    ) -> [String]? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = expression.firstMatch(in: source, range: range) else { return nil }
        return groups.map { group in
            guard group < match.numberOfRanges,
                  match.range(at: group).location != NSNotFound,
                  let valueRange = Range(match.range(at: group), in: source) else { return "" }
            return String(source[valueRange])
        }
    }

    static func firstMatch(_ pattern: String, in source: String) -> String? {
        firstMatch(pattern, in: source, groups: [1])?.first
    }

    static func plainText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        return htmlDecode(withoutTags)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func htmlDecode(_ source: String) -> String {
        var value = source
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")
        ]
        for (entity, replacement) in named {
            value = value.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        guard let expression = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) else { return value }
        let matches = expression.matches(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ).reversed()
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: value),
                  let numberRange = Range(match.range(at: 1), in: value) else { continue }
            let raw = String(value[numberRange])
            let radix = raw.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(raw.dropFirst()) : raw
            guard let scalarValue = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(scalarValue) else { continue }
            value.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return value
    }

    // MARK: - Result serialization

    static func serviceResponse(
        _ result: SearchExecutionResult,
        limit: Int
    ) -> SearchServiceResponse {
        var object: [String: Any] = [:]
        if let answer = result.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            object["answer"] = answer
        }
        object["items"] = result.items.prefix(limit).enumerated().map { index, item in
            [
                "title": item.title,
                "url": normalizeURL(item.url),
                "text": item.text,
                "id": String(UUID().uuidString.prefix(6)),
                "index": index + 1
            ] as [String: Any]
        }

        var seenImageURLs = Set<String>()
        let imageLimit = min(max(limit, 1), 6)
        let images = result.images.compactMap { image -> SearchImageCandidate? in
            let url = normalizeURL(image.url)
            guard isHTTPURL(url), seenImageURLs.insert(url).inserted else { return nil }
            let sourceURL = image.sourceURL.map(normalizeURL).flatMap {
                isHTTPURL($0) ? $0 : nil
            }
            return SearchImageCandidate(
                id: UUID().uuidString.lowercased(),
                title: image.title.trimmingCharacters(in: .whitespacesAndNewlines),
                url: url,
                sourceURL: sourceURL
            )
        }
        .prefix(imageLimit)
        .map { $0 }

        if !images.isEmpty {
            object["images"] = images.map { image in
                var value: [String: Any] = [
                    "id": image.id,
                    "url": image.url,
                ]
                if !image.title.isEmpty { value["title"] = image.title }
                if let sourceURL = image.sourceURL { value["source_url"] = sourceURL }
                return value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let output = String(data: data, encoding: .utf8) else {
            return SearchServiceResponse(content: "{\"items\":[]}", images: [])
        }
        return SearchServiceResponse(content: output, images: images)
    }

    static func isHTTPURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return false }
        return true
    }

    static func errorJSON(_ message: String) -> String {
        let object = ["error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let output = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Search failed\"}"
        }
        return output
    }

    static func normalizeURL(_ raw: String) -> String {
        var value = htmlDecode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let components = URLComponents(string: value),
           let redirected = bingRedirectTarget(from: components) {
            value = redirected
        } else if let components = URLComponents(string: value),
                  let host = components.host?.lowercased(),
                  host.hasSuffix("duckduckgo.com"),
                  let redirected = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
                  !redirected.isEmpty {
            value = redirected.removingPercentEncoding ?? redirected
        } else if value.hasPrefix("/l/") || value.hasPrefix("//duckduckgo.com/l/") {
            let absolute = value.hasPrefix("//") ? "https:\(value)" : "https://duckduckgo.com\(value)"
            if let components = URLComponents(string: absolute),
               let redirected = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
               !redirected.isEmpty {
                value = redirected.removingPercentEncoding ?? redirected
            }
        }
        if value.hasPrefix("//") { return "https:\(value)" }
        guard !value.isEmpty else { return "" }
        if URLComponents(string: value)?.scheme == nil { return "https://\(value)" }
        return value
    }

    private static func bingRedirectTarget(from components: URLComponents) -> String? {
        guard let host = components.host?.lowercased(),
              (host == "bing.com" || host.hasSuffix(".bing.com")),
              components.path == "/ck/a",
              let wrapped = components.queryItems?.first(where: { $0.name == "u" })?.value,
              wrapped.hasPrefix("a1") else { return nil }

        var encoded = String(wrapped.dropFirst(2))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: encoded),
              let target = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              isHTTPURL(target) else { return nil }
        return target
    }
}
