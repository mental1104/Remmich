#if DEBUG
    import Foundation
    import Synchronization

    /// 隔离UI宿主观察到的原始HTTP证据；只含合成计数/JSON，不从待测query生成预期值。
    nonisolated struct SavedSearchUIHTTPObservation: Sendable {
        var counts = "GET=0 POST=0 PATCH=0 DELETE=0"
        var presetBody = "{}"
        var searchBody = "{}"
        var violation = "none"
    }

    /// URLProtocol线程先捕获不可变请求，避免把URLRequest的流或可变引用跨actor传递。
    fileprivate nonisolated struct SavedSearchUIHTTPRequest: Sendable {
        let url: URL
        let method: String
        let authorization: String?
        let contentType: String?
        let body: Data

        /// request来自真实URLSession；最多64KiB合成JSON，流读取失败/超限直接拒绝。
        init(_ request: URLRequest) throws {
            guard let url = request.url, let method = request.httpMethod else { throw URLError(.badURL) }
            self.url = url; self.method = method
            authorization = request.value(forHTTPHeaderField: "Authorization")
            contentType = request.value(forHTTPHeaderField: "Content-Type")
            if let bytes = request.httpBody {
                guard bytes.count <= 64 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                body = bytes
            } else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: 4096)
                    guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                    if count == 0 {
                        break
                    }
                    guard bytes.count + count <= 64 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                body = bytes
            } else {
                body = Data()
            }
        }
    }

    /// 返回给URLSession的真实状态/响应字节；无socket、媒体下载或服务端数据库。
    fileprivate nonisolated struct SavedSearchUIHTTPReply: Sendable {
        let status: Int
        let body: Data
    }

    /// 小型有状态HTTP夹具只服务保存条件及metadata搜索；真正UI/Store/客户端负责全部业务调用。
    /// actor按顺序保存收到的请求和合成账号数据，不提供从UI绕过HTTP直接执行CRUD的方法。
    actor SavedSearchUIHTTPBackend {
        /// 服务端响应形状保留完整条件；不能在改名回执中删掉字段。
        private nonisolated struct Record: Codable, Sendable {
            let id: String
            let name: String
            let conditions: NativeSearchPresetConditions
        }

        /// 真实客户端提交的完整请求体，复用已存在的条件decoder而不从UI状态猜请求。
        private nonisolated struct WriteBody: Decodable, Sendable {
            let name: String
            let conditions: NativeSearchPresetConditions
        }

        private let host: String
        private let report: @MainActor @Sendable (SavedSearchUIHTTPObservation) -> Void
        private var records: [Record]
        private var observation = SavedSearchUIHTTPObservation()
        private var getCount = 0
        private var postCount = 0
        private var patchCount = 0
        private var deleteCount = 0

        /// host为每个进程独占.invalid地址；report只发布已收到HTTP证据，不修改查询或触发CRUD。
        init(host: String, report: @escaping @MainActor @Sendable (SavedSearchUIHTTPObservation) -> Void) {
            self.host = host; self.report = report
            var seed = NativeSearchPresetConditions()
            seed.query = .init(value: "Existing", type: .metadata)
            records = [.init(id: "88888888-8888-4888-8888-888888888888", name: "Existing", conditions: seed)]
        }

        /// request必须来自隔离会话的合成账号和精确路径；意外路由明确失败并记录，不回源。
        fileprivate func response(to request: SavedSearchUIHTTPRequest) async -> SavedSearchUIHTTPReply {
            do {
                guard request.url.scheme == "https", request.url.host == host, request.url.query == nil,
                      request.authorization == "Bearer synthetic-presets" else { throw URLError(.userAuthenticationRequired) }
                let reply: SavedSearchUIHTTPReply
                if request.url.path == "/api/search/metadata", request.method == "POST" {
                    try requireJSON(request)
                    observation.searchBody = try canonicalJSON(request.body)
                    let json = #"{"albums":{"total":0,"count":0,"items":[],"facets":[]},"assets":{"total":0,"count":0,"items":[],"facets":[],"nextCursor":null,"nextPage":null}}"#
                    reply = .init(status: 200, body: Data(json.utf8))
                } else {
                    reply = try presetResponse(to: request)
                }
                observation.counts = "GET=\(getCount) POST=\(postCount) PATCH=\(patchCount) DELETE=\(deleteCount)"
                await report(observation)
                return reply
            } catch {
                observation.violation = "Unexpected isolated HTTP request or body."
                await report(observation)
                return .init(status: 500, body: Data("{}".utf8))
            }
        }

        /// 仅允许固定登记集合及UUID资源；成功/冲突状态模拟公开合同，不替换客户端的状态确认逻辑。
        private func presetResponse(to request: SavedSearchUIHTTPRequest) throws -> SavedSearchUIHTTPReply {
            let root = "/api/fork/search-presets"
            if request.url.path == root, request.method == "GET", request.body.isEmpty {
                getCount += 1
                return try encoded(records.sorted { $0.name < $1.name }, status: 200)
            }
            if request.url.path == root, request.method == "POST" {
                postCount += 1
                let body = try decodeWrite(request)
                if records.contains(where: { $0.name.caseInsensitiveCompare(body.name) == .orderedSame }) {
                    return .init(status: 409, body: Data("{}".utf8))
                }
                // 每个场景只创建一份成功记录；第二份意外成功写入必须显式暴露，不能覆盖既有ID。
                let id = "11111111-1111-4111-8111-111111111111"
                guard !records.contains(where: { $0.id == id }) else { throw URLError(.badServerResponse) }
                let record = Record(id: id, name: body.name, conditions: body.conditions)
                records.append(record)
                return try encoded(record, status: 201)
            }
            guard request.url.path.hasPrefix(root + "/"),
                  let id = request.url.path.split(separator: "/").last.map(String.init),
                  UUID(uuidString: id) != nil, request.url.path == root + "/" + id,
                  let index = records.firstIndex(where: { $0.id == id }) else { throw URLError(.unsupportedURL) }
            if request.method == "PATCH" {
                patchCount += 1
                let body = try decodeWrite(request)
                let record = Record(id: id, name: body.name, conditions: body.conditions)
                records[index] = record
                return try encoded(record, status: 200)
            }
            if request.method == "DELETE", request.body.isEmpty {
                deleteCount += 1; records.remove(at: index)
                return .init(status: 204, body: Data())
            }
            throw URLError(.unsupportedURL)
        }

        /// request必须是JSON对象；保留实际完整body供UI测试独立解码，而不是发布条件摘要假装请求。
        private func decodeWrite(_ request: SavedSearchUIHTTPRequest) throws -> WriteBody {
            try requireJSON(request)
            let value = try JSONDecoder().decode(WriteBody.self, from: request.body)
            guard (1 ... 100).contains(value.name.utf16.count) else { throw URLError(.cannotParseResponse) }
            observation.presetBody = try canonicalJSON(request.body)
            return value
        }

        /// request必须有真实JSON内容类型与对象正文；非法shape不能变成默认成功。
        private func requireJSON(_ request: SavedSearchUIHTTPRequest) throws {
            guard request.contentType?.hasPrefix("application/json") == true,
                  try JSONSerialization.jsonObject(with: request.body) is [String: Any] else { throw URLError(.cannotParseResponse) }
        }

        /// bytes来自实际HTTP正文；只统一键顺序便于AX读取，不改字段和值。
        private func canonicalJSON(_ bytes: Data) throws -> String {
            let object = try JSONSerialization.jsonObject(with: bytes)
            return try String(decoding: JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
        }

        /// value为夹具的完整响应对象，status严格采用公开合同；返回编码失败而不伪造空列表。
        private func encoded(_ value: some Encodable, status: Int) throws -> SavedSearchUIHTTPReply {
            try .init(status: status, body: JSONEncoder().encode(value))
        }
    }

    /// 仅配置到本片显式URLSession；捕获所有请求并拒绝未知host，绝不全局注册URLProtocol或建立连接。
    final nonisolated class SavedSearchUIHTTPProtocol: URLProtocol, @unchecked Sendable {
        /// 取消标记和Task受锁保护，URLSession停止后不继续交付响应。
        private struct Loading: Sendable {
            var stopped = false
            var task: Task<Void, Never>?
        }

        private static let backends = Mutex<[String: SavedSearchUIHTTPBackend]>([:])
        private let loading = Mutex(Loading())

        /// backend只归属传入的随机host；没有修改系统/共享会话的协议列表。
        static func install(_ backend: SavedSearchUIHTTPBackend, host: String) {
            backends.withLock { $0[host] = backend }
        }

        /// host对应宿主离开时退休注册，释放其内存数据；没有持久账号资料。
        static func remove(host: String) {
            _ = backends.withLock { $0.removeValue(forKey: host) }
        }

        /// 此类只在受限会话显式配置；全部接管才能保证意外URL也不能回落网络。
        override class func canInit(with _: URLRequest) -> Bool {
            true
        }

        /// 原始请求不改写，便于测试核对前缀、方法、鉴权与JSON。
        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        /// 捕获真实字节后交actor生成响应；Task只携带不可变快照，不发送InputStream或业务UI状态。
        override func startLoading() {
            do {
                let captured = try SavedSearchUIHTTPRequest(request)
                guard let backend = Self.backends.withLock({ $0[captured.url.host ?? ""] }) else { throw URLError(.unsupportedURL) }
                let task = Task { @Sendable [weak self, backend, captured] in
                    let reply = await backend.response(to: captured)
                    guard let self, !Task.isCancelled, !loading.withLock({ $0.stopped }) else { return }
                    if let response = HTTPURLResponse(url: captured.url, statusCode: reply.status, httpVersion: nil,
                                                      headerFields: ["Content-Type": "application/json"])
                    {
                        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        if !reply.body.isEmpty {
                            client?.urlProtocol(self, didLoad: reply.body)
                        }
                        client?.urlProtocolDidFinishLoading(self)
                    } else {
                        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    }
                }
                loading.withLock {
                    $0.task = task; if $0.stopped {
                        task.cancel()
                    }
                }
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }

        /// 遵守真实URLSession取消，不为了UI迟到断言强行回调已退休客户端。
        override func stopLoading() {
            let task = loading.withLock { $0.stopped = true; return $0.task }
            task?.cancel()
        }
    }
#endif
