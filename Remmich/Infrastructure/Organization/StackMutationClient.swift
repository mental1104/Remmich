import Foundation

/// 官方stack专用窄通道，复用现有Bearer/禁缓存cookie重定向规则；不暴露资产删除或任意写路径。
final nonisolated class StackMutationClient: Sendable {
    private let apiURL: URL
    private let token: String
    private let session: URLSession

    /// apiURL/token来自原仓库已验证会话；configuration仅替换测试HTTP来源，不替换任何契约验证。
    init(apiURL: URL, token: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.apiURL = apiURL
        self.token = token
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: LibraryMutationClient.NoRedirect(), delegateQueue: nil)
    }

    /// 原仓库释放后不留下脱离账号生命周期的HTTP会话。
    deinit { session.invalidateAndCancel() }
    /// 账号/端点改变关闭实际任务，原仓库仍负责拒绝已完成解码的旧代际值。
    func cancel() {
        session.invalidateAndCancel()
    }

    /// id须仍为本人、未删除、timeline图片且不属任何stack；防止创建时隐式合并其他堆叠或移动其成员。
    func requireUnstackedPhoto(_ id: String, ownerID: String) async throws {
        struct ExistingStack: Decodable { let id: UUID }
        struct Asset: Decodable { let id: UUID; let ownerId: UUID; let isTrashed: Bool; let visibility: String; let type: String; let stack: ExistingStack? }
        let data = try await send("GET", ["assets", validID(id)], status: 200)
        let asset = try JSONDecoder().decode(Asset.self, from: data)
        guard asset.id == UUID(uuidString: id), asset.ownerId == UUID(uuidString: ownerID),
              !asset.isTrashed, asset.visibility == "timeline", asset.type == "IMAGE", asset.stack == nil
        else { throw NativeStackError.invalidSelection }
    }

    /// assetIDs顺序决定新主图；expectedMembers是预检后同意的可见成员集合，201逐项匹配后返回新stack UUID。
    func create(assetIDs: [String], expectedMembers: Set<String>) async throws -> String {
        guard assetIDs.count >= 2, Set(assetIDs.map { $0.lowercased() }).count == assetIDs.count else { throw NativeStackError.invalidSelection }
        struct Body: Encodable { let assetIds: [String] }
        let body = try JSONEncoder().encode(Body(assetIds: assetIDs.map(validID)))
        let data = try await send("POST", ["stacks"], body: body, status: 201)
        return try verify(data, id: nil, primary: assetIDs[0], members: expectedMembers)
    }

    /// expected固定预检后的原stack，assetID须为已存在成员；只发送primaryAssetId并精确核对200响应。
    func primary(_ expected: ManagedNativeStack, assetID: String) async throws {
        struct Body: Encodable { let primaryAssetId: String }
        let body = try JSONEncoder().encode(Body(primaryAssetId: validID(assetID)))
        let data = try await send("PUT", ["stacks", validID(expected.id)], body: body, status: 200)
        _ = try verify(data, id: expected.id, primary: assetID, members: Set(expected.assets.map(\.id)))
    }

    /// id/assetID限定一项非主图成员；204仅确认写入，随后原仓库重新读取验证，不删除资产。
    func remove(_ id: String, assetID: String) async throws {
        _ = try await send("DELETE", ["stacks", validID(id), "assets", validID(assetID)], status: 204)
    }

    /// id为用户明确确认的整个stack；只删除堆叠关系，绝不调用DELETE/assets。
    func dissolve(_ id: String) async throws {
        _ = try await send("DELETE", ["stacks", validID(id)], status: 204)
    }

    /// data为官方完整stack回执；id可为新创建未知ID，主图/所有可见成员必须完全匹配，重复身份拒绝。
    private func verify(_ data: Data, id: String?, primary: String, members: Set<String>) throws -> String {
        struct Asset: Decodable { let id: UUID }
        struct Receipt: Decodable { let id: UUID; let primaryAssetId: UUID; let assets: [Asset] }
        let value = try JSONDecoder().decode(Receipt.self, from: data)
        let ids = value.assets.map { $0.id.uuidString.lowercased() }
        guard id.map({ UUID(uuidString: $0) == value.id }) ?? true,
              value.primaryAssetId == UUID(uuidString: primary), ids.count == Set(ids).count,
              Set(ids) == Set(members.map { $0.lowercased() }) else { throw NativeStackError.unconfirmed }
        return value.id.uuidString.lowercased()
    }

    /// value只接受UUID并规范化路径；绝不将外部字符串当相对路由。
    private func validID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value) else { throw LibraryWriteError.invalidID }
        return uuid.uuidString.lowercased()
    }

    /// method/path/status均由上方固定操作提供；只接受精确状态、无重定向/重试，不展示服务器原始正文。
    private func send(_ method: String, _ path: [String], body: Data? = nil, status: Int) async throws -> Data {
        try Task.checkCancellation()
        guard ["https", "http"].contains(apiURL.scheme), apiURL.host != nil,
              apiURL.user == nil, apiURL.password == nil, apiURL.query == nil, apiURL.fragment == nil,
              !token.contains("\r"), !token.contains("\n") else { throw LibraryWriteError.unavailable }
        var request = URLRequest(url: path.reduce(apiURL) { $0.appendingPathComponent($1) })
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw LibraryWriteError.malformedResponse }
        guard response.statusCode == status else {
            if (200 ..< 300).contains(response.statusCode) {
                throw NativeStackError.unconfirmed
            }
            throw LibraryWriteError.http(response.statusCode)
        }
        return data
    }
}
