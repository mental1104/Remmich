import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 真实Pending Store→Repo→SDK/目录GET→独占URLSession；只用合成成员与分组，不以缓存或直接Store注入代替HTTP。
@Suite("Pending album complete ownership")
@MainActor struct PendingAlbumOwnershipTests {
    /// 首owner和非首co-owner都属于本人；editor/viewer、相似分组、空分组不能被当作待整理本人相簿。
    @Test func selectsAnyOwnerFromRealAlbumMembers() async throws {
        let fixture = PendingOwnershipFixture(); defer { fixture.close() }
        let source = fixture.repository()
        await source.configure(session: fixture.account, activeEndpoint: fixture.endpoint)
        let store = PendingAlbumsStore()
        await store.load(source: source, ownerID: pendingSelf)
        #expect(store.supported == true && store.hasLoaded && !store.isLoading && store.error == nil)
        #expect(Set(store.albums.map(\.id)) == [pendingFirstAlbum, pendingCoAlbum])
        let first = try #require(store.albums.first { $0.id == pendingFirstAlbum })
        let co = try #require(store.albums.first { $0.id == pendingCoAlbum })
        #expect(first.ownerID == pendingSelf && first.ownerName == "Synthetic self")
        #expect(first.ownerIDs == [pendingSelf])
        #expect(co.ownerID == pendingOther && co.ownerName == "Synthetic other")
        #expect(co.ownerIDs == [pendingOther, pendingSelf] && co.isOwned(by: pendingSelf.uppercased()))
        let requests = await fixture.backend.requests
        #expect(requests.count == 3 && requests.filter { $0.url.path == "/immich/api/albums" }.count == 2)
        #expect(requests.filter { $0.url.path == "/immich/api/fork/album-categories" }.count == 1)
        try fixture.assertRequests(requests)
    }

    /// 未来未知role不能被误当owner或跳过坏项假装空列表；固定SDK拒绝整份非法DTO，Store保留明确失败。
    @Test func unknownMemberRoleDoesNotGrantOwnershipOrConfirmEmpty() async throws {
        let fixture = PendingOwnershipFixture(albums: pendingAlbumsJSON(unknownRole: true)); defer { fixture.close() }
        let source = fixture.repository()
        await source.configure(session: fixture.account, activeEndpoint: fixture.endpoint)
        let store = PendingAlbumsStore()
        await store.load(source: source, ownerID: pendingSelf)
        #expect(store.albums.isEmpty && !store.hasLoaded && store.supported == nil && store.error != nil && !store.isLoading)
        let requests = await fixture.backend.requests
        #expect(requests.contains { $0.url.path == "/immich/api/albums" })
        #expect((1 ... 3).contains(requests.count))
        try fixture.assertRequests(requests)
    }

    /// 目录扩展明确缺失才能降级unsupported；403/503保持失败，不能包装成“没有待整理相簿”。
    @Test(arguments: [404, 403, 503])
    func distinguishesMissingDirectoryFromReadFailure(_ status: Int) async throws {
        let fixture = PendingOwnershipFixture(categoryStatus: status); defer { fixture.close() }
        let source = fixture.repository()
        await source.configure(session: fixture.account, activeEndpoint: fixture.endpoint)
        let store = PendingAlbumsStore()
        await store.load(source: source, ownerID: pendingSelf)
        #expect(store.albums.isEmpty && !store.isLoading)
        if status == 404 {
            #expect(store.supported == false && store.hasLoaded && store.error == nil)
        } else {
            #expect(store.supported == nil && !store.hasLoaded && store.error != nil)
        }
        try await fixture.assertRequests(fixture.backend.requests)
    }

    /// 实际SDK或目录GET挂起后换号/换路由/取消；新账号空列表先发布，旧合法owner数据最后释放也不能复活。
    @Test(.timeLimit(.minutes(1)), arguments: ["albums", "fork/album-categories"], ["account", "endpoint", "cancel"])
    func retiresBothInflightReadBranches(_ heldPath: String, _ reason: String) async throws {
        let fixture = PendingOwnershipFixture(heldPath: heldPath); defer { fixture.close() }
        let current = PendingOwnershipFixture(albums: "[]", user: reason == "account" ? pendingOther : pendingSelf, token: "synthetic-current")
        defer { current.close() }
        let source = fixture.repository()
        await source.configure(session: fixture.account, activeEndpoint: fixture.endpoint)
        let store = PendingAlbumsStore()
        let old = Task { await store.load(source: source, ownerID: pendingSelf); await fixture.backend.operationFinished() }
        try await withTaskCancellationHandler {
            try #require(await fixture.backend.waitForHeld(), "The old pending GET must enter its actual URLSession gate")
            if reason == "cancel" {
                old.cancel()
            } else {
                let account = reason == "account" ? pendingAccount(endpoint: fixture.endpoint, user: pendingOther, token: "synthetic-other") : fixture.account
                let endpoint = reason == "endpoint" ? fixture.endpoint.appending(path: "retired-route") : fixture.endpoint
                await source.configure(session: account, activeEndpoint: endpoint)
                store.invalidate()
                let newSource = current.repository()
                await newSource.configure(session: current.account, activeEndpoint: current.endpoint)
                await store.load(source: newSource, ownerID: current.account.userID)
                #expect(store.hasLoaded && store.supported == true && store.albums.isEmpty && store.error == nil)
            }
            await fixture.backend.release()
            await old.value
            await fixture.backend.waitForResponderExit()
            #expect(store.albums.isEmpty && !store.isLoading && store.error == nil)
            #expect(store.hasLoaded == (reason != "cancel"))
            let oldRequests = await fixture.backend.requests
            try fixture.assertRequests(oldRequests)
            if heldPath == "fork/album-categories" {
                // 只允许并发SDK的首个albums GET；已退休的目录响应不得再发自己的第二GET。
                #expect(oldRequests.filter { $0.url.path == "/immich/api/albums" }.count <= 1)
            }
            if reason != "cancel" {
                try await current.assertRequests(current.backend.requests)
            }
        } onCancel: { old.cancel(); Task { await fixture.backend.stop() } }
        await fixture.backend.stop()
    }

    /// Codable旧摘要缺新字段仍可读；nil才兼容旧ownerID，fresh显式空集合和多owner集合各自保留语义。
    @Test(arguments: ["legacy", "empty", "co-owner"])
    func preservesLegacyCacheAndExplicitOwnerProof(_ variant: String) throws {
        let date = Date(timeIntervalSince1970: 100)
        var album = AlbumSummary(id: pendingFirstAlbum, name: "Synthetic", description: "", thumbnailAssetID: nil, assetCount: 0,
                                 updatedAt: date, createdAt: date, startDate: nil, endDate: nil, isShared: true,
                                 ownerName: "Legacy first", ownerID: variant == "co-owner" ? pendingOther : pendingSelf)
        album.ownerIDs = variant == "co-owner" ? [pendingOther, pendingSelf] : variant == "empty" ? [] : nil
        let bytes = try JSONEncoder().encode(album)
        let value = try JSONSerialization.jsonObject(with: bytes)
        var object = try #require(value as? [String: Any])
        if variant == "legacy" {
            object.removeValue(forKey: "ownerIDs")
        }
        let restored = try JSONDecoder().decode(AlbumSummary.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.ownerID == album.ownerID && restored.ownerName == album.ownerName && restored.ownerIDs == album.ownerIDs)
        #expect(restored.isOwned(by: pendingSelf) == (variant != "empty"))
        #expect(!restored.isOwned(by: ""))
    }
}

private nonisolated let pendingSelf = "11111111-1111-4111-8111-111111111111"
private nonisolated let pendingOther = "22222222-2222-4222-8222-222222222222"
private nonisolated let pendingFirstAlbum = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private nonisolated let pendingCoAlbum = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

/// endpoint/user/token均合成；所有请求走测试URLProtocol，不配置Keychain、持久传输或真实服务器。
private nonisolated func pendingAccount(endpoint: URL, user: String = pendingSelf, token: String = "synthetic-pending") -> AccountSession {
    .init(apiURL: endpoint, accessToken: token, userID: user, userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// role/id/name是独立官方成员JSON；不会根据待测筛选结果修改响应或省略required user字段。
private nonisolated func pendingMember(_ id: String, role: String, name: String) -> String {
    #"{"role":"\#(role)","user":{"id":"\#(id)","name":"\#(name)","email":"synthetic@example.invalid","avatarColor":"primary","profileChangedAt":"2026-11-01T00:00:00Z","profileImagePath":""}}"#
}

/// unknownRole仅破坏一个明确成员角色，其他数据仍完整；包含本人首/非首owner、editor/viewer和分组边界。
private nonisolated func pendingAlbumsJSON(unknownRole: Bool = false) -> String {
    let selfOwner = pendingMember(pendingSelf, role: unknownRole ? "future-owner" : "owner", name: "Synthetic self")
    let otherOwner = pendingMember(pendingOther, role: "owner", name: "Synthetic other")
    let examples: [(String, String, [String])] = [
        (pendingFirstAlbum, "待整理", [selfOwner]),
        (pendingCoAlbum, " \n待整理\t ", [otherOwner, selfOwner]),
        ("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "待整理", [otherOwner, pendingMember(pendingSelf, role: "editor", name: "Synthetic self")]),
        ("dddddddd-dddd-4ddd-8ddd-dddddddddddd", "待整理", [otherOwner, pendingMember(pendingSelf, role: "viewer", name: "Synthetic self")]),
        ("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "待整理-2026", [selfOwner]),
        ("ffffffff-ffff-4fff-8fff-ffffffffffff", "", [selfOwner]),
    ]
    return "[" + examples.map { id, group, members in
        // group通过独立JSON编码处理控制字符，保证测试的是trim而不是非法JSON的解码失败。
        let encodedGroup = String(decoding: try! JSONEncoder().encode(group), as: UTF8.self)
        return #"{"id":"\#(id)","albumName":"Synthetic \#(id)","description":"","albumThumbnailAssetId":null,"assetCount":0,"createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-02T00:00:00Z","shared":true,"hasSharedLink":false,"isActivityEnabled":false,"albumUsers":[\#(members.joined(separator: ","))],"customGroupName":\#(encodedGroup)}"#
    }.joined(separator: ",") + "]"
}

/// 本例独占repo与有限HTTP来源；同一URLSession既供SDK GET，也供原Fork目录GET，不全局注册或回源。
@MainActor private final class PendingOwnershipFixture {
    let endpoint: URL
    let account: AccountSession
    let backend: PendingOwnershipBackend
    private let network: URLSession

    /// albums是固定JSON，categoryStatus区分扩展缺失/错误，heldPath只挂起一次；user/token固定独立预期身份。
    init(albums: String = pendingAlbumsJSON(), categoryStatus: Int = 200, heldPath: String? = nil,
         user: String = pendingSelf, token: String = "synthetic-pending")
    {
        endpoint = URL(string: "https://pending-\(UUID().uuidString.lowercased()).example.invalid/immich/api")!
        account = pendingAccount(endpoint: endpoint, user: user, token: token)
        backend = PendingOwnershipBackend(albums: albums, categoryStatus: categoryStatus, heldPath: heldPath)
        PendingOwnershipProtocol.install(backend, host: endpoint.host!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingOwnershipProtocol.self]; configuration.urlCache = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        network = URLSession(configuration: configuration, delegate: LibraryMutationClient.NoRedirect(), delegateQueue: nil)
    }

    /// 只复用原repo的既有readLoader依赖；返回真实URLSession数据/状态，不直接返回相簿或选择结果。
    func repository() -> ImmichTimelineRepository {
        let network = network
        return .init(readLoader: { request, operation in
            guard ["getAllAlbums", "forkAlbumDirectory"].contains(operation) else { throw URLError(.unsupportedURL) }
            let (data, response) = try await network.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        })
    }

    /// requests均为实际URLSession输出；只允许两种GET、完整代理前缀和合成Bearer，不允许媒体/写入/分页。
    func assertRequests(_ requests: [PendingOwnershipRequest]) throws {
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.method == "GET" && request.bodyAbsent && request.authorization == "Bearer \(account.accessToken)")
            #expect(request.url.host == endpoint.host && request.url.query == nil && request.url.fragment == nil)
            #expect(["/immich/api/albums", "/immich/api/fork/album-categories"].contains(request.url.path))
        }
    }

    /// 停止仅本例会话并移除host；任何失败/取消均释放旧响应门，不影响默认生产网络或其它测试。
    func close() {
        network.invalidateAndCancel(); PendingOwnershipProtocol.remove(host: endpoint.host!)
        Task { await backend.stop() }
    }
}

/// 捕获真实GET的身份与路径；不跨actor传URLRequest流或可变框架对象。
private nonisolated struct PendingOwnershipRequest: Sendable {
    let id = UUID()
    let method: String?
    let url: URL
    let authorization: String?
    let bodyAbsent: Bool

    /// request为URLSession实际输入；无URL直接失败，正文只能验证不存在而不能替被测请求清除。
    init(_ request: URLRequest) throws {
        url = try #require(request.url); method = request.httpMethod
        authorization = request.value(forHTTPHeaderField: "Authorization")
        bodyAbsent = request.httpBody == nil && request.httpBodyStream == nil
    }
}

/// 合成HTTP状态与原始JSON，不伪装成已经通过SDK或Store校验的领域对象。
private nonisolated struct PendingOwnershipReply: Sendable { let status: Int; let json: String }

/// 两路GET可并发，响应按实际路径匹配；只挂起首个匹配请求，迟到回应故意不合作取消。
private actor PendingOwnershipBackend {
    private let albums: String
    private let categoryStatus: Int
    private var heldPath: String?
    private(set) var requests: [PendingOwnershipRequest] = []
    private var heldID: UUID?
    private var gate: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var exit: CheckedContinuation<Void, Never>?
    private var exited = false
    private var finished = false

    /// albums/categoryStatus是固定响应，heldPath只决定在哪条实际GET上暂停，不控制业务成功状态。
    init(albums: String, categoryStatus: Int, heldPath: String?) {
        self.albums = albums; self.categoryStatus = categoryStatus; self.heldPath = heldPath
    }

    /// request为SDK或Fork实际GET；未知路径失败且不访问网络，hold在数据已捕获之后发生。
    func response(_ request: PendingOwnershipRequest) async throws -> PendingOwnershipReply {
        requests.append(request)
        let reply: PendingOwnershipReply
        switch request.url.path {
        case "/immich/api/albums": reply = .init(status: 200, json: albums)
        case "/immich/api/fork/album-categories": reply = .init(status: categoryStatus, json: #"{"categories":[],"groups":[]}"#)
        default: operationFinished(); throw URLError(.unsupportedURL)
        }
        if let heldPath, request.url.path == "/immich/api/" + heldPath {
            self.heldPath = nil; heldID = request.id
            await withCheckedContinuation { gate = $0; waiter?.resume(returning: true); waiter = nil }
        }
        return reply
    }

    /// 原调用已退出也必须通知测试，避免失败前置条件时永远等不到门。
    func operationFinished() {
        finished = true; waiter?.resume(returning: false); waiter = nil
    }

    /// 返回是否已进入实际门；若调用已经失败，false让测试传播失败而非靠sleep猜测。
    func waitForHeld() async -> Bool {
        if gate != nil {
            return true
        }
        if finished {
            return false
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// 显式释放唯一挂起响应，SDK/Repo/Store负责之后的取消及代际验证。
    func release() {
        gate?.resume(); gate = nil
    }

    /// id是协议Task实际退出的请求；只唤醒被挂起的旧请求，不能误用另一并发GET的退出。
    func responderExited(_ id: UUID) {
        guard heldID == id else { return }; exited = true; exit?.resume(); exit = nil
    }

    /// 旧Task取消可能早于响应器退场；两者都完成后才检查迟到结果未发布。
    func waitForResponderExit() async {
        guard !exited else { return }; await withCheckedContinuation { exit = $0 }
    }

    /// 测试结束或超时释放全部本例continuation，无持久服务或后台重试。
    func stop() {
        operationFinished(); release(); exit?.resume(); exit = nil
    }
}

/// 仅装入本例独占URLSession的协议；Mutex保护注册与取消，不注册全局protocol或访问真实服务器。
private final nonisolated class PendingOwnershipProtocol: URLProtocol, @unchecked Sendable {
    private static let backends = Mutex<[String: PendingOwnershipBackend]>([:])
    private let state = Mutex<(stopped: Bool, task: Task<Void, Never>?)>((false, nil))

    /// host为随机.invalid，backend为其固定字节来源；其它并行测试不共享响应内容。
    static func install(_ backend: PendingOwnershipBackend, host: String) {
        backends.withLock { $0[host] = backend }
    }

    /// 只移除本例host；不改变其它URLSession或后台传输。
    static func remove(host: String) {
        _ = backends.withLock { $0.removeValue(forKey: host) }
    }

    /// 接管配置会话所有host，未知host在startLoading中失败，绝不回落socket。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 保留SDK请求原样，不能替用例修正路径或鉴权。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 捕获Sendable请求后异步返回原始HTTP；真实URLSession取消后禁止调用成功/失败delegate。
    override func startLoading() {
        do {
            let captured = try PendingOwnershipRequest(request)
            let backend = try #require(Self.backends.withLock { $0[captured.url.host ?? ""] })
            let task = Task { @Sendable [weak self, backend, captured] in
                defer { Task { await backend.responderExited(captured.id) } }
                do {
                    let reply = try await backend.response(captured)
                    guard let self, !Task.isCancelled, !self.state.withLock({ $0.stopped }) else { return }
                    let response = try #require(HTTPURLResponse(url: captured.url, statusCode: reply.status, httpVersion: nil,
                                                                headerFields: ["Content-Type": "application/json"]))
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(reply.json.utf8)); client?.urlProtocolDidFinishLoading(self)
                } catch {
                    guard let self, !Task.isCancelled, !self.state.withLock({ $0.stopped }) else { return }
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            state.withLock {
                $0.task = task; if $0.stopped {
                    task.cancel()
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// 停止只取消此协议Task；非合作后台门由测试显式释放，生产取消逻辑不被夹具替代。
    override func stopLoading() {
        state.withLock { $0.stopped = true; $0.task?.cancel() }
    }
}
