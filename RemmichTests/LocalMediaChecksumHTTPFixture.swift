import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 一次固定HTTP响应；held控制在途时序，authorization核Bearer，responseJSON可按随机nonce生成查重回执，contentType保留真实流类型。
nonisolated struct ChecksumLookupExchange: Sendable {
    let method: String
    let path: String
    let status: Int
    let json: String
    var held = false
    var authorization = "Bearer checksum-owner"
    var responseJSON: (@Sendable (ChecksumLookupRequest) throws -> String)?
    var contentType = "application/json"
    /// 明确查询参数与路径分开核对；默认空数组保留所有既有无query场景。
    var query: [URLQueryItem] = []
    /// 仅磁盘multipart上传场景设置前缀；nil保持既有GET/JSON精确检查，不放宽其他用例。
    var requestContentTypePrefix: String?
}

/// 有限JSON请求快照；不把Foundation输入流跨actor共享。
nonisolated struct ChecksumLookupRequest: Sendable {
    let id = UUID()
    let method: String
    let url: URL
    let authorization: String?
    let contentType: String?
    let cookie: String?
    let body: Data?

    /// request来自本测试会话；完整读取最多100KB，未设置body的GET保持nil。
    init(_ request: URLRequest) throws {
        guard let method = request.httpMethod, let url = request.url else { throw URLError(.badURL) }
        self.method = method; self.url = url
        authorization = request.value(forHTTPHeaderField: "Authorization")
        contentType = request.value(forHTTPHeaderField: "Content-Type")
        cookie = request.value(forHTTPHeaderField: "Cookie")
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= 100_000 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            body = bytes
        } else {
            body = nil
        }
    }
}

/// 每个随机host独立的响应顺序/等待门；业务提前失败也唤醒观察者，不靠sleep推进场景。
actor ChecksumLookupHTTPScript {
    private let exchanges: [ChecksumLookupExchange]
    private var captured: [ChecksumLookupRequest] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Bool, Never>?
    private var held = false
    private var finished = false
    private var stopped = false
    private var heldRequestID: UUID?
    private var responderExits = Set<UUID>()
    private var exitObserver: CheckedContinuation<Void, Never>?

    /// exchanges是独立响应剧本，不从Store/patch反推成功值。
    init(_ exchanges: [ChecksumLookupExchange]) {
        self.exchanges = exchanges
    }

    /// request/endpoint记录实际路径、身份和body；未知多余请求直接失败，绝不访问外网。
    func response(_ request: ChecksumLookupRequest, endpoint: URL) async throws -> ChecksumLookupExchange {
        guard !stopped else { throw CancellationError() }
        let index = captured.count; captured.append(request)
        guard exchanges.indices.contains(index) else { throw URLError(.badServerResponse) }
        let exchange = exchanges[index]
        let expectedURL: URL?
        if exchange.query.isEmpty {
            // 原无query调用保留同一URL构造表达式，不经过新增的组件重写分支。
            expectedURL = endpoint.appending(path: exchange.path)
        } else {
            var expected = URLComponents(url: endpoint.appending(path: exchange.path), resolvingAgainstBaseURL: false)
            expected?.queryItems = exchange.query
            expectedURL = expected?.url
        }
        let contentTypeMatches = if let prefix = exchange.requestContentTypePrefix {
            request.contentType?.hasPrefix(prefix) == true
        } else {
            request.contentType == (request.body == nil ? nil : "application/json")
        }
        guard request.method == exchange.method, request.url == expectedURL,
              request.authorization == exchange.authorization, request.cookie == nil,
              contentTypeMatches else { throw URLError(.badServerResponse) }
        if exchange.held {
            heldRequestID = request.id
            await withCheckedContinuation { continuation in
                pending = continuation; held = true; observer?.resume(returning: true); observer = nil
            }
        }
        return exchange
    }

    /// 返回捕获值供测试独立断言，不在传输回调中伪造业务成功。
    func requests() -> [ChecksumLookupRequest] {
        captured
    }

    /// 实际请求到达门后返回true；操作若先失败返回false，避免断言无法到达时永远挂起。
    func waitForHeld() async -> Bool {
        if held {
            return true
        }
        if finished {
            return false
        }
        return await withCheckedContinuation { observer = $0 }
    }

    /// 真实操作结束时唤醒未到门的观察者，不返回任何伪造HTTP结果。
    func operationFinished() {
        finished = true; if !held {
            observer?.resume(returning: false); observer = nil
        }
    }

    /// 测试明确释放旧响应；URLProtocol仍必须遵守真实取消，不强行交付迟到字节。
    func release() {
        pending?.resume(); pending = nil
    }

    /// requestID由真实URLProtocol任务结束路径报告；只唤醒对应被hold的响应退出观察者。
    func responderExited(_ requestID: UUID) {
        responderExits.insert(requestID)
        if requestID == heldRequestID {
            exitObserver?.resume(); exitObserver = nil
        }
    }

    /// 等待实际hold响应任务结束，而非仅业务任务结束；提前失败/清理时无不可达等待。
    func waitForHeldResponderExit() async {
        guard let heldRequestID, !responderExits.contains(heldRequestID), !stopped else { return }
        await withCheckedContinuation { exitObserver = $0 }
    }

    /// 失败/超时清理同时释放响应和观察者；清理先于请求到门时也不再新建不可唤醒的continuation。
    func stop() {
        stopped = true; finished = true; observer?.resume(returning: false); observer = nil
        exitObserver?.resume(); exitObserver = nil; release()
    }
}

/// 每例自己的真实manager和随机.invalid host，仅会话内安装协议，不改变生产构造或全局URLSession。
@MainActor struct ChecksumLookupHTTPFixture {
    let endpoint: URL
    let manager: LibraryManagementController
    let script: ChecksumLookupHTTPScript

    /// exchanges是固定有限HTTP序列；真实客户端继续执行Bearer、JSON、状态与取消检查。
    init(exchanges: [ChecksumLookupExchange]) {
        endpoint = URL(string: "https://checksum-\(UUID().uuidString.lowercased()).invalid/api")!
        script = ChecksumLookupHTTPScript(exchanges)
        ChecksumLookupURLProtocol.install(script, endpoint: endpoint)
        manager = LibraryManagementController(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChecksumLookupURLProtocol.self]
            return configuration
        })
        manager.configure(session: checksumLookupSession(endpoint: endpoint), endpoint: endpoint)
    }

    /// 先取消本会话，再移除私有host；清理不接触任何真实账号或其他并行测试。
    func close() {
        manager.configure(session: nil, endpoint: nil)
        ChecksumLookupURLProtocol.remove(endpoint: endpoint)
        Task { await script.stop() }
    }
}

/// 本会话HTTP响应器；Mutex保护取消/任务安装竞争，未知host也被拦截，不回落真实网络。
private final nonisolated class ChecksumLookupURLProtocol: URLProtocol, @unchecked Sendable {
    /// 一个随机host的脚本与API根。
    private struct Entry: Sendable { let script: ChecksumLookupHTTPScript; let endpoint: URL }
    /// URLSession取消和异步响应任务的线程间同步状态。
    private struct Loading: Sendable { var stopped = false; var task: Task<Void, Never>? }
    private static let scripts = Mutex<[String: Entry]>([:])
    private let loading = Mutex(Loading())

    /// script/endpoint只装入本类私有表，不使用进程全局URLProtocol注册。
    static func install(_ script: ChecksumLookupHTTPScript, endpoint: URL) {
        scripts.withLock { $0[endpoint.host!] = .init(script: script, endpoint: endpoint) }
    }

    /// 仅移除本测试endpoint，保留其他并行fixture。
    static func remove(endpoint: URL) {
        _ = scripts.withLock { $0.removeValue(forKey: endpoint.host!) }
    }

    /// 所有请求都由该协议接管，错误host必须失败。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 原样保留生产请求，不由fixture修正错误body或路径。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 捕获请求并异步回传固定响应；实际取消后不再交付字节，异常使真正URLSession失败。
    override func startLoading() {
        do {
            let capturedRequest = try ChecksumLookupRequest(request)
            guard let entry = Self.scripts.withLock({ $0[capturedRequest.url.host ?? ""] }) else { throw URLError(.badURL) }
            let task = Task { @Sendable [weak self, entry, capturedRequest] in
                defer { Task { @Sendable [script = entry.script, requestID = capturedRequest.id] in await script.responderExited(requestID) } }
                do {
                    let exchange = try await entry.script.response(capturedRequest, endpoint: entry.endpoint)
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    guard let response = HTTPURLResponse(url: capturedRequest.url, statusCode: exchange.status, httpVersion: nil,
                                                         headerFields: ["Content-Type": exchange.contentType]) else { throw URLError(.badServerResponse) }
                    let json = try exchange.responseJSON?(capturedRequest) ?? exchange.json
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(json.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            loading.withLock {
                $0.task = task; if $0.stopped {
                    task.cancel()
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// 取消真实在途响应任务；gate仍由测试释放，不能把迟到成功注入新账号。
    override func stopLoading() {
        let task = loading.withLock { $0.stopped = true; return $0.task }
        task?.cancel()
    }
}

/// endpoint/user/token均为合成值；配置真实账号/路由代际，不访问Keychain或私人账号。
nonisolated func checksumLookupSession(endpoint: URL, user: String = "99999999-9999-4999-8999-999999999999", token: String = "checksum-owner") -> AccountSession {
    .init(apiURL: endpoint, accessToken: token, userID: user, userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}
