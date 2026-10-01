import Foundation
import SwiftUI

enum MCPTransportType: String, Codable, CaseIterable, Identifiable, Sendable {
    case http
    case sse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .http: "Streamable HTTP"
        case .sse: "SSE"
        }
    }
}

enum MCPConnectionStatus: String, Codable, Sendable {
    case idle
    case connecting
    case connected
    case error

    var title: String {
        switch self {
        case .idle: "未连接"
        case .connecting: "连接中"
        case .connected: "已连接"
        case .error: "错误"
        }
    }
}

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var anyValue: Any {
        switch self {
        case let .string(value): value
        case let .number(value):
            value.rounded() == value ? Int(value) : value
        case let .bool(value): value
        case let .object(value): value.mapValues(\.anyValue)
        case let .array(value): value.map(\.anyValue)
        case .null: NSNull()
        }
    }

    var objectValue: [String: Any]? {
        guard case let .object(value) = self else { return nil }
        return value.mapValues(\.anyValue)
    }

    static func fromAny(_ value: Any?) -> JSONValue {
        guard let value else { return .null }
        if value is NSNull { return .null }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Int { return .number(Double(value)) }
        if let value = value as? Double { return .number(value) }
        if let value = value as? Float { return .number(Double(value)) }
        if let value = value as? String { return .string(value) }
        if let value = value as? [Any] { return .array(value.map(Self.fromAny)) }
        if let value = value as? [String: Any] { return .object(value.mapValues(Self.fromAny)) }
        return .string(String(describing: value))
    }
}

struct MCPParamSpec: Codable, Hashable, Sendable {
    var name: String
    var required: Bool
    var type: String?
    var defaultValue: JSONValue?
}

struct MCPToolConfig: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    var enabled: Bool
    var name: String
    var description: String?
    var params: [MCPParamSpec]
    var schema: JSONValue?
    var needsApproval: Bool

    init(
        enabled: Bool = true,
        name: String,
        description: String? = nil,
        params: [MCPParamSpec] = [],
        schema: JSONValue? = nil,
        needsApproval: Bool = false
    ) {
        self.enabled = enabled
        self.name = name
        self.description = description
        self.params = params
        self.schema = schema
        self.needsApproval = needsApproval
    }

    var schemaObject: [String: Any]? {
        schema?.objectValue
    }
}

struct MCPServerConfig: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var enabled: Bool
    var name: String
    var transport: MCPTransportType
    var url: String
    var headers: [String: String]
    var tools: [MCPToolConfig]

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        name: String = "MCP",
        transport: MCPTransportType = .http,
        url: String = "",
        headers: [String: String] = [:],
        tools: [MCPToolConfig] = []
    ) {
        self.id = id
        self.enabled = enabled
        self.name = name
        self.transport = transport
        self.url = url
        self.headers = headers
        self.tools = tools
    }

    func hasSameConnection(as other: MCPServerConfig) -> Bool {
        id == other.id && enabled == other.enabled && transport == other.transport
            && normalizedURLString == other.normalizedURLString && headers == other.headers
    }

    var normalizedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "MCP" : trimmed
    }

    var normalizedURLString: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MCPServerRuntimeState: Codable, Hashable, Sendable {
    var status: MCPConnectionStatus = .idle
    var error: String?
}

struct ToolInvocationContext: Hashable, Sendable {
    let conversationID: UUID
    let runID: UUID
    let messageID: UUID
    let persistenceEpoch: UInt64
}

enum ToolApprovalDecision: String, Sendable {
    case approved
    case denied = "approval_denied"
    case busy = "approval_busy"
    case expired = "request_expired"

    var explanation: String {
        switch self {
        case .approved: "Approved."
        case .denied: "The user denied this tool call."
        case .busy: "Another tool approval is open. This call was not executed; retry after that approval finishes."
        case .expired: "The generation was stopped or changed. This call was not executed."
        }
    }
}

struct MCPApprovalRequest: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case mcp, calendar }
    let id: UUID
    let kind: Kind
    let context: ToolInvocationContext
    let conversationTitle: String
    let toolName: String
    let argumentsPreview: String

    var title: String { kind == .mcp ? "MCP 工具调用" : "日历工具调用" }
}

/// Every closure captures the displayed request, never a mutable global slot.
struct ToolApprovalAlertModifier: ViewModifier {
    let model: AppModel
    let request: MCPApprovalRequest?

    func body(content: Content) -> some View {
        content.alert(request?.title ?? L10n.lookup("工具调用"), isPresented: Binding(
            get: { request != nil },
            set: { presented in
                if !presented, let request {
                    model.resolveToolApproval(id: request.id, decision: .denied)
                }
            }
        ), presenting: request) { request in
            Button(L10n.lookup("拒绝"), role: .destructive) {
                model.resolveToolApproval(id: request.id, decision: .denied)
            }
            Button(L10n.lookup("允许")) {
                model.resolveToolApproval(id: request.id, decision: .approved)
            }
        } message: { request in
            Text("\(request.conversationTitle)\n\(request.toolName)\n\n\(request.argumentsPreview)")
        }
    }
}

enum MCPPersistence {
    private static let serversKey = "mcp_servers_v1"
    private static let timeoutKey = "mcp_request_timeout_seconds_v1"

    static func loadServers() -> [MCPServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: serversKey) else { return [] }
        return (try? JSONDecoder().decode([MCPServerConfig].self, from: data)) ?? []
    }

    static func saveServers(_ servers: [MCPServerConfig]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: serversKey)
    }

    static func loadTimeoutSeconds() -> Int {
        let value = UserDefaults.standard.integer(forKey: timeoutKey)
        return value > 0 ? value : 30
    }

    static func saveTimeoutSeconds(_ value: Int) {
        UserDefaults.standard.set(max(3, value), forKey: timeoutKey)
    }
}

enum MCPClientError: LocalizedError {
    case invalidURL
    case disabled
    case httpStatus(Int, String)
    case invalidResponse
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: ErrorLocalization.lookup("MCP 服务器地址无效")
        case .disabled: ErrorLocalization.lookup("MCP 服务器未启用")
        case let .httpStatus(code, body): "MCP HTTP \(code)：\(body)"
        case .invalidResponse: ErrorLocalization.lookup("MCP 服务器返回了无法识别的数据")
        case let .rpcError(message): message
        }
    }
}

@MainActor
enum MCPHTTPClient {
    static func listTools(server: MCPServerConfig, timeoutSeconds: Int) async throws -> [MCPToolConfig] {
        var sessionID: String?
        _ = try await sendRPC(
            method: "initialize",
            params: [
                "protocolVersion": "2025-03-26",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "Mocca", "version": "1.0.0"]
            ],
            id: 1,
            server: server,
            sessionID: &sessionID,
            timeoutSeconds: timeoutSeconds
        )
        try? await sendNotification(
            method: "notifications/initialized",
            server: server,
            sessionID: sessionID,
            timeoutSeconds: timeoutSeconds
        )
        let result = try await sendRPC(
            method: "tools/list",
            params: nil,
            id: 2,
            server: server,
            sessionID: &sessionID,
            timeoutSeconds: timeoutSeconds
        )
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap(parseTool)
    }

    static func callTool(
        server: MCPServerConfig,
        toolName: String,
        arguments: [String: Any],
        timeoutSeconds: Int
    ) async throws -> String {
        var sessionID: String?
        _ = try await sendRPC(
            method: "initialize",
            params: [
                "protocolVersion": "2025-03-26",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "Mocca", "version": "1.0.0"]
            ],
            id: 1,
            server: server,
            sessionID: &sessionID,
            timeoutSeconds: timeoutSeconds
        )
        try? await sendNotification(
            method: "notifications/initialized",
            server: server,
            sessionID: sessionID,
            timeoutSeconds: timeoutSeconds
        )
        let result = try await sendRPC(
            method: "tools/call",
            params: [
                "name": toolName,
                "arguments": arguments
            ],
            id: 2,
            server: server,
            sessionID: &sessionID,
            timeoutSeconds: timeoutSeconds
        )
        return renderToolResult(result)
    }

    private static func sendNotification(
        method: String,
        server: MCPServerConfig,
        sessionID: String?,
        timeoutSeconds: Int
    ) async throws {
        var ignoredSessionID = sessionID
        _ = try await postJSON(
            [
                "jsonrpc": "2.0",
                "method": method
            ],
            server: server,
            sessionID: &ignoredSessionID,
            timeoutSeconds: timeoutSeconds,
            allowsEmptyResponse: true
        )
    }

    private static func sendRPC(
        method: String,
        params: [String: Any]?,
        id: Int,
        server: MCPServerConfig,
        sessionID: inout String?,
        timeoutSeconds: Int
    ) async throws -> [String: Any] {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        let response = try await postJSON(
            payload,
            server: server,
            sessionID: &sessionID,
            timeoutSeconds: timeoutSeconds,
            allowsEmptyResponse: false
        )
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "MCP JSON-RPC error"
            throw MCPClientError.rpcError(message)
        }
        guard let result = response["result"] as? [String: Any] else {
            throw MCPClientError.invalidResponse
        }
        return result
    }

    private static func postJSON(
        _ payload: [String: Any],
        server: MCPServerConfig,
        sessionID: inout String?,
        timeoutSeconds: Int,
        allowsEmptyResponse: Bool
    ) async throws -> [String: Any] {
        guard server.enabled else { throw MCPClientError.disabled }
        guard let url = URL(string: server.normalizedURLString), !server.normalizedURLString.isEmpty else {
            throw MCPClientError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(max(3, timeoutSeconds)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in server.headers where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPClientError.invalidResponse }
        if let value = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !value.isEmpty {
            sessionID = value
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MCPClientError.httpStatus(http.statusCode, body)
        }
        if data.isEmpty, allowsEmptyResponse {
            return [:]
        }
        guard !data.isEmpty else { throw MCPClientError.invalidResponse }
        return try parseResponseData(data)
    }

    private static func parseResponseData(_ data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidResponse
        }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let jsonText = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard jsonText != "[DONE]", let jsonData = jsonText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }
            return object
        }
        throw MCPClientError.invalidResponse
    }

    private static func parseTool(_ raw: [String: Any]) -> MCPToolConfig? {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        let schemaAny = raw["inputSchema"] as? [String: Any]
        let schema = schemaAny.map(JSONValue.fromAny)
        var params: [MCPParamSpec] = []
        if let properties = schemaAny?["properties"] as? [String: Any] {
            let required = Set((schemaAny?["required"] as? [Any] ?? []).map { String(describing: $0) })
            params = properties.map { key, value in
                let object = value as? [String: Any]
                let typeValue = object?["type"]
                let type: String?
                if let rawType = typeValue as? String {
                    type = rawType
                } else if let rawTypes = typeValue as? [Any] {
                    type = rawTypes.map { String(describing: $0) }.joined(separator: "|")
                } else {
                    type = nil
                }
                return MCPParamSpec(
                    name: key,
                    required: required.contains(key),
                    type: type,
                    defaultValue: JSONValue.fromAny(object?["default"])
                )
            }
            .sorted { $0.name < $1.name }
        }
        return MCPToolConfig(
            name: name,
            description: raw["description"] as? String,
            params: params,
            schema: schema
        )
    }

    private static func renderToolResult(_ result: [String: Any]) -> String {
        if let content = result["content"] as? [[String: Any]] {
            let rendered = content.compactMap { item -> String? in
                if let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
                if let uri = item["uri"] as? String, !uri.isEmpty {
                    return "resource: \(uri)"
                }
                if let data = item["data"] as? String, !data.isEmpty {
                    let mime = item["mimeType"] as? String ?? "image/*"
                    return "[image:\(mime);base64,\(data)]"
                }
                return nil
            }
            .joined(separator: "\n")
            if !rendered.isEmpty { return rendered }
        }
        if let text = result["text"] as? String { return text }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: result)
    }
}

struct MCPSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editingServer: MCPServerConfig?
    @State private var isAddingServer = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                Stepper("请求超时：\(model.mcpRequestTimeoutSeconds) 秒", value: $model.mcpRequestTimeoutSeconds, in: 3...120, step: 3)
                    .onChange(of: model.mcpRequestTimeoutSeconds) { _, value in
                        MCPPersistence.saveTimeoutSeconds(value)
                    }
            }

            Section(L10n.lookup("服务器")) {
                if model.mcpServers.isEmpty {
                    ContentUnavailableView(L10n.lookup("还没有 MCP 服务器"), systemImage: "terminal", description: Text(L10n.lookup("添加 Streamable HTTP 或 SSE 服务器")))
                } else {
                    ForEach(model.mcpServers) { server in
                        Button {
                            editingServer = server
                        } label: {
                            MCPServerRow(server: server)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        model.deleteMCPServers(at: offsets)
                    }
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle("MCP")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingServer = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingServer) {
            NavigationStack {
                MCPServerEditorView(server: MCPServerConfig()) { server, refreshTools in
                    model.upsertMCPServer(server, refreshTools: refreshTools)
                }
            }
        }
        .sheet(item: $editingServer) { server in
            NavigationStack {
                MCPServerEditorView(server: server) { updated, refreshTools in
                    model.upsertMCPServer(updated, refreshTools: refreshTools)
                }
            }
        }
    }
}

private struct MCPServerRow: View {
    @Environment(AppModel.self) private var model
    let server: MCPServerConfig

    var body: some View {
        let state = model.mcpRuntimeStates[server.id] ?? MCPServerRuntimeState()
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.normalizedName)
                    .foregroundStyle(.primary)
                Text(server.normalizedURLString.isEmpty ? server.transport.title : server.normalizedURLString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = state.error, state.status == .error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(L10n.lookup(state.status.title))
                    .font(.caption)
                    .foregroundStyle(state.status == .connected ? .green : state.status == .error ? .red : .secondary)
                Text("\(server.tools.filter(\.enabled).count)/\(server.tools.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MCPServerEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MCPServerConfig
    @State private var headersText: String
    @State private var isRefreshing = false
    let onSave: (MCPServerConfig, Bool) -> Void

    init(server: MCPServerConfig, onSave: @escaping (MCPServerConfig, Bool) -> Void) {
        _draft = State(initialValue: server)
        _headersText = State(initialValue: server.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.lookup("启用"), isOn: $draft.enabled)
                TextField(L10n.lookup("名称"), text: $draft.name)
                Picker(L10n.lookup("传输"), selection: $draft.transport) {
                    ForEach(MCPTransportType.allCases) { transport in
                        Text(L10n.lookup(transport.title)).tag(transport)
                    }
                }
                TextField(L10n.lookup("服务器地址"), text: $draft.url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } footer: {
                Text(L10n.lookup("移动端优先支持 Streamable HTTP。SSE 服务器如果也接受 JSON-RPC POST，可在这里使用。"))
            }

            Section {
                NativeMultilineTextEditor(
                    text: $headersText,
                    font: .monospacedBody,
                    autocapitalizationType: .none,
                    autocorrectionType: .no
                )
                    .frame(minHeight: 90)
            } header: {
                Text(L10n.lookup("自定义 Header"))
            } footer: {
                Text(L10n.lookup("每行一个 Header，格式为 Key: Value。"))
            }

            Section {
                Button {
                    save(refreshTools: false)
                    isRefreshing = true
                    Task {
                        await model.refreshMCPTools(serverID: draft.id)
                        isRefreshing = false
                    }
                } label: {
                    Label(isRefreshing ? L10n.lookup("同步中") : L10n.lookup("同步工具"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isRefreshing)
            }

            Section(L10n.lookup("工具")) {
                if draft.tools.isEmpty {
                    Text(L10n.lookup("同步后会显示服务器工具"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(draft.tools.indices, id: \.self) { index in
                        MCPToolEditorRow(tool: $draft.tools[index])
                    }
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(draft.normalizedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.lookup("取消")) { dismiss() }
                    .foregroundStyle(.primary)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.lookup("保存")) {
                    save()
                    dismiss()
                }
                    .foregroundStyle(.primary)
            }
        }
    }

    private func save(refreshTools: Bool = true) {
        draft.headers = parseHeaders(headersText)
        onSave(draft, refreshTools)
    }

    private func parseHeaders(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
}

private struct MCPToolEditorRow: View {
    @Binding var tool: MCPToolConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $tool.enabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name)
                    if let description = tool.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            Toggle("调用前询问", isOn: $tool.needsApproval)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

struct MCPServerSelectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let assistantID: UUID

    private var selectedIDs: Set<UUID> {
        Set(model.assistantProfile(id: assistantID.uuidString)?.mcpServerIDs ?? [])
    }

    private var connectedServers: [MCPServerConfig] {
        model.mcpServers.filter {
            $0.enabled && (model.mcpRuntimeStates[$0.id]?.status == .connected || !$0.tools.isEmpty)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if connectedServers.isEmpty {
                        ContentUnavailableView(L10n.lookup("没有可用 MCP 服务器"), systemImage: "terminal", description: Text(L10n.lookup("先在设置里添加并同步服务器工具")))
                    } else {
                        Button(L10n.lookup("全选")) {
                            model.setMCPServers(connectedServers.map(\.id), forAssistantID: assistantID)
                        }
                        Button(L10n.lookup("清空"), role: .destructive) {
                            model.setMCPServers([], forAssistantID: assistantID)
                        }
                    }
                }

                Section(L10n.lookup("服务器")) {
                    ForEach(connectedServers) { server in
                        let isSelected = selectedIDs.contains(server.id)
                        Toggle(isOn: Binding(
                            get: { isSelected },
                            set: { model.toggleMCPServer(server.id, enabled: $0, forAssistantID: assistantID) }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.normalizedName)
                                Text(L10n.format("%@/%@ 个工具", [String(server.tools.filter(\.enabled).count), String(server.tools.count)]))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .settingsGroupedPageStyle()
            .navigationTitle(L10n.lookup("MCP 服务器"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("完成")) { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}
