import Foundation

/// 人物专用窄通道；沿用既有Bearer、禁cookie/cache/redirect规则，绝不向浏览SDK放开任意写操作。
final nonisolated class PeopleMutationClient: Sendable {
    private let apiURL: URL
    private let token: String
    private let userID: String
    private let session: URLSession

    /// apiURL/token/userID来自原仓库当前已认证会话；configuration仅用于隔离URLProtocol契约测试。
    init(apiURL: URL, token: String, userID: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.apiURL = apiURL
        self.token = token
        self.userID = userID
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: LibraryMutationClient.NoRedirect(), delegateQueue: nil)
    }

    /// 仓库消失时关闭未结束的人物请求，不留下独立于账号生命周期的前台会话。
    deinit { session.invalidateAndCancel() }

    /// 账号/端点切换立即关闭原HTTP任务；迟到值还必须经过仓库代际检查。
    func cancel() {
        session.invalidateAndCancel()
    }

    /// id是待确认人物；每次GET都真正访问前台，不能根据本地卡片猜测当前状态。
    func person(_ id: String) async throws -> ManagedPerson {
        try await decodePerson(send("GET", ["people", validID(id)]), expectedID: id)
    }

    /// name仅更新当前账号记录，保留其他共享用户和生日；200且回执值一致才确认接收。
    func rename(_ id: String, name: String) async throws {
        struct Body: Encodable { let name: String; let userId: String }
        let body = try JSONEncoder().encode(Body(name: name, userId: validID(userID)))
        let response = try await decodePerson(send("PUT", ["people", validID(id)], body: body), expectedID: id)
        guard response.name == name else { throw LibraryWriteError.malformedResponse }
    }

    /// hidden只改变人物显示，不改资产visibility；仅发送isHidden字段并校验回执。
    func setHidden(_ id: String, hidden: Bool) async throws {
        struct Body: Encodable { let isHidden: Bool }
        let body = try JSONEncoder().encode(Body(isHidden: hidden))
        let response = try await decodePerson(send("PUT", ["people", validID(id)], body: body), expectedID: id)
        guard response.isHidden == hidden else { throw LibraryWriteError.malformedResponse }
    }

    /// 有向两人合并，target为首项；精确匹配全部独立回执，部分成功/不明回执均不能宣称完成或自动重试。
    func merge(targetID: String, sourceID: String) async throws {
        let target = try validID(targetID)
        let source = try validID(sourceID)
        guard target.lowercased() != source.lowercased() else { throw LibraryWriteError.invalidID }
        struct Body: Encodable { let ids: [String] }
        struct Receipt: Decodable { let id: UUID; let success: Bool; let error: String?; let errorMessage: String? }
        let body = try JSONEncoder().encode(Body(ids: [target, source]))
        let data = try await send("POST", ["people", "merge"], body: body)
        let results = try JSONDecoder().decode([Receipt].self, from: data)
        let expected = Set([UUID(uuidString: target)!, UUID(uuidString: source)!])
        guard results.count == 2, Set(results.map(\.id)) == expected else { throw LibraryWriteError.malformedResponse }
        guard results.allSatisfy({ $0.success && $0.error == nil && $0.errorMessage == nil }) else { throw PeopleManagementError.incompleteMerge }
    }

    /// data为已完成真实请求；只消费所需人物字段，服务器其他字段原样保留在服务端。
    private func decodePerson(_ data: Data, expectedID: String) throws -> ManagedPerson {
        struct Response: Decodable { let id: UUID; let name: String; let isHidden: Bool }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.id == UUID(uuidString: expectedID) else { throw LibraryWriteError.malformedResponse }
        return .init(id: response.id.uuidString.lowercased(), name: response.name, isHidden: response.isHidden)
    }

    /// value必须为真实UUID，路径不接受任意片段；保留调用者形式，回执以UUID比较大小写。
    private func validID(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw LibraryWriteError.invalidID }
        return value
    }

    /// method/path只由本类型固定操作提供，200以外全部失败；不重试、不重定向、不打印响应正文。
    private func send(_ method: String, _ path: [String], body: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard ["http", "https"].contains(apiURL.scheme), apiURL.host != nil,
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
        guard response.statusCode == 200 else {
            if (200 ..< 300).contains(response.statusCode) {
                throw LibraryWriteError.malformedResponse
            }
            throw LibraryWriteError.http(response.statusCode)
        }
        return data
    }
}
