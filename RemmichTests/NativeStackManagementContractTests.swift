import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 原repo/SDK/真实URLSession请求契约，使用独立合成HTTP来源，不连接图库或生产服务。
@Suite("Native stack HTTP contracts")
struct NativeStackManagementContractTests {
    /// 从Store真实fresh空列表到逐张预检、POST、单stack确认、最终列表；顺序明确决定代表图。
    @Test @MainActor func createsThroughTheRealFreshFlow() async throws {
        let endpoint = stackEndpoint()
        let value = stackJSON(stackID, primary: stackB, assets: [stackB, stackA])
        let fixture = StackHTTPFixture(routes: [
            "GET /prefix/api/stacks": [.init(json: "[]"), .init(json: "[\(value)]")],
            "GET /prefix/api/assets/\(stackA)": [.init(json: stackAssetJSON(stackA))],
            "GET /prefix/api/assets/\(stackB)": [.init(json: stackAssetJSON(stackB))],
            "POST /prefix/api/stacks": [.init(status: 201, json: value)],
            "GET /prefix/api/stacks/\(stackID)": [.init(json: value)],
        ])
        StackHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { StackHTTPProtocol.remove(endpoint: endpoint) }
        let repo = stackRepository(fixture)
        await repo.configure(session: stackSession(endpoint), activeEndpoint: endpoint)
        let store = NativeStackManagementStore()
        await store.reload(source: repo)
        await store.perform(.create(assetIDs: [stackB, stackA], addingTo: nil), source: repo)
        #expect(!store.needsReload && store.error == nil && store.stacks.first?.primaryAssetID == stackB)
        let requests = await fixture.requests
        #expect(requests.map(\.method) == ["GET", "GET", "GET", "POST", "GET", "GET"])
        #expect(requests.allSatisfy { $0.authorization == "Bearer synthetic" })
        let write = try #require(requests.first { $0.method == "POST" })
        #expect(try write.jsonBody().isEqual(to: ["assetIds": [stackB, stackA]]))
        await repo.clear()
    }

    /// 追加沿用官方Web的旧主图+新项POST，旧非主成员由服务端带入，之后读取新的stack ID。
    @Test func appendsWithoutMovingOtherStacks() async throws {
        let endpoint = stackEndpoint()
        let fixture = StackHTTPFixture(routes: [
            "GET /prefix/api/stacks/\(stackID)": [.init(json: stackJSON(stackID, assets: [stackA, stackB]))],
            "GET /prefix/api/assets/\(stackC)": [.init(json: stackAssetJSON(stackC))],
            "POST /prefix/api/stacks": [.init(status: 201, json: stackJSON(stackNewID, assets: [stackA, stackB, stackC]))],
            "GET /prefix/api/stacks/\(stackNewID)": [.init(json: stackJSON(stackNewID, assets: [stackA, stackB, stackC]))],
        ])
        StackHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { StackHTTPProtocol.remove(endpoint: endpoint) }
        let repo = stackRepository(fixture)
        await repo.configure(session: stackSession(endpoint), activeEndpoint: endpoint)
        try await repo.changeNativeStack(.create(assetIDs: [stackC], addingTo: stackModel([stackA, stackB])))
        let requests = await fixture.requests
        #expect(requests.map(\.method) == ["GET", "GET", "POST", "GET"])
        let write = try #require(requests.first { $0.method == "POST" })
        #expect(try write.jsonBody().isEqual(to: ["assetIds": [stackA, stackC]]))
        #expect(requests.last?.url.path == "/prefix/api/stacks/\(stackNewID)")
        await repo.clear()
    }

    /// 主图PUT、非主成员DELETE和整组DELETE均准确路由；拆分后查完整列表而非假设未知stack返回404。
    @Test(arguments: ["primary", "remove", "dissolve"])
    func exactActionsAndFreshConfirmation(_ mode: String) async throws {
        let endpoint = stackEndpoint()
        var routes: [String: [StackHTTPReply]] = [
            "GET /prefix/api/stacks/\(stackID)": [.init(json: stackJSON(stackID, assets: [stackA, stackB, stackC]))],
        ]
        let change: NativeStackChange
        switch mode {
        case "primary":
            change = .primary(stackModel([stackA, stackB, stackC]), assetID: stackC)
            let updated = stackJSON(stackID, primary: stackC, assets: [stackC, stackA, stackB])
            routes["PUT /prefix/api/stacks/\(stackID)"] = [.init(json: updated)]
            routes["GET /prefix/api/stacks/\(stackID)"]?.append(.init(json: updated))
        case "remove":
            change = .remove(stackModel([stackA, stackB, stackC]), assetID: stackB)
            routes["DELETE /prefix/api/stacks/\(stackID)/assets/\(stackB)"] = [.init(status: 204, json: "")]
            routes["GET /prefix/api/stacks/\(stackID)"]?.append(.init(json: stackJSON(stackID, assets: [stackA, stackC])))
        default:
            change = .dissolve(stackModel([stackA, stackB, stackC]))
            routes["DELETE /prefix/api/stacks/\(stackID)"] = [.init(status: 204, json: "")]
            routes["GET /prefix/api/stacks"] = [.init(json: "[]")]
        }
        let fixture = StackHTTPFixture(routes: routes)
        StackHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { StackHTTPProtocol.remove(endpoint: endpoint) }
        let repo = stackRepository(fixture)
        await repo.configure(session: stackSession(endpoint), activeEndpoint: endpoint)
        try await repo.changeNativeStack(change)
        let requests = await fixture.requests
        #expect(requests.count == 3)
        #expect(requests.filter { $0.method != "GET" }.count == 1)
        #expect(!requests.contains { $0.method == "DELETE" && $0.url.path == "/prefix/api/assets" })
        let write = try #require(requests.first { $0.method != "GET" })
        if mode == "primary" {
            #expect(try write.jsonBody().isEqual(to: ["primaryAssetId": stackC]))
        }
        if mode == "dissolve" {
            #expect(requests.last?.url.path == "/prefix/api/stacks")
        }
        await repo.clear()
    }

    /// 用户确认后成员/主图已变则只GET，不能把旧快照覆盖到新状态。
    @Test func changedPreflightPreventsAnyWrite() async throws {
        let endpoint = stackEndpoint()
        let fixture = StackHTTPFixture(routes: ["GET /prefix/api/stacks/\(stackID)": [.init(json: stackJSON(stackID, assets: [stackA, stackB, stackC]))]])
        let repo = stackRepository(fixture)
        await repo.configure(session: stackSession(endpoint), activeEndpoint: endpoint)
        await #expect(throws: NativeStackError.changed) { try await repo.changeNativeStack(.dissolve(stackModel([stackA, stackB]))) }
        #expect(await fixture.requests.map(\.method) == ["GET"])
        await repo.clear()
    }

    /// 已属其他stack、他人、已trash、归档或视频候选均阻止创建，不能静默合并/移动未知成员。
    @Test(arguments: ["stacked", "owner", "trashed", "archive", "video"])
    func rejectsChangedCandidate(_ mode: String) async throws {
        let endpoint = stackEndpoint()
        let json = stackAssetJSON(stackA, owner: mode == "owner" ? stackB : stackUser,
                                  trashed: mode == "trashed", visibility: mode == "archive" ? "archive" : "timeline",
                                  type: mode == "video" ? "VIDEO" : "IMAGE", stacked: mode == "stacked")
        let fixture = StackHTTPFixture(routes: ["GET /prefix/api/assets/\(stackA)": [.init(json: json)]])
        StackHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { StackHTTPProtocol.remove(endpoint: endpoint) }
        let client = StackMutationClient(apiURL: endpoint, token: "synthetic", configuration: stackConfiguration())
        defer { client.cancel() }
        await #expect(throws: NativeStackError.invalidSelection) { try await client.requireUnstackedPhoto(stackA, ownerID: stackUser) }
        #expect(await fixture.requests.map(\.method) == ["GET"])
    }

    /// 创建只接受201，权限/限流/服务器失败及意外成功码不重试；正文不能代替准确HTTP状态。
    @Test(arguments: [200, 204, 401, 403, 429, 500])
    func exactStatusWithoutReplay(_ status: Int) async throws {
        let endpoint = stackEndpoint()
        let fixture = StackHTTPFixture(routes: ["POST /prefix/api/stacks": [.init(status: status, json: stackJSON(stackID, assets: [stackA, stackB]))]])
        StackHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { StackHTTPProtocol.remove(endpoint: endpoint) }
        let client = StackMutationClient(apiURL: endpoint, token: "synthetic", configuration: stackConfiguration())
        defer { client.cancel() }
        do {
            _ = try await client.create(assetIDs: [stackA, stackB], expectedMembers: [stackA, stackB])
            Issue.record("Unexpected success status must fail")
        } catch let error as NativeStackError { #expect(error == .unconfirmed && (200 ..< 300).contains(status)) }
        catch let error as LibraryWriteError {
            if case let .http(actual) = error {
                #expect(actual == status && !(200 ..< 300).contains(status))
            } else {
                Issue.record("Unexpected write error")
            }
        }
        #expect(await fixture.requests.count == 1)
    }

    /// 即使200，回执的缺项/重复/错误主图/其他stack ID均失败，不能假定后端回滚。
    @Test(arguments: ["missing", "duplicate", "primary", "id"])
    func rejectsMismatchedReceipt(_ mode: String) async throws {
        let endpoint = stackEndpoint()
        let json = stackJSON(mode == "id" ? stackNewID : stackID,
                             primary: mode == "primary" ? stackA : stackB,
                             assets: mode == "missing" ? [stackB] : mode == "duplicate" ? [stackB, stackB] : [stackB, stackA])
        let fixture = StackHTTPFixture(routes: ["PUT /prefix/api/stacks/\(stackID)": [.init(json: json)]])
        StackHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { StackHTTPProtocol.remove(endpoint: endpoint) }
        let client = StackMutationClient(apiURL: endpoint, token: "synthetic", configuration: stackConfiguration())
        defer { client.cancel() }
        await #expect(throws: NativeStackError.unconfirmed) { try await client.primary(stackModel([stackA, stackB]), assetID: stackB) }
        #expect(await fixture.requests.count == 1)
    }

    /// 新GET必须发生，两个相同列表URL不能复用已完成的索引结果。
    @Test func repeatedListsAreFresh() async throws {
        let fixture = StackHTTPFixture(routes: ["GET /prefix/api/stacks": [
            .init(json: "[\(stackJSON(stackID, assets: [stackA, stackB]))]"),
            .init(json: "[\(stackJSON(stackID, assets: [stackA, stackB, stackC]))]"),
        ]])
        let endpoint = stackEndpoint()
        let repo = stackRepository(fixture)
        await repo.configure(session: stackSession(endpoint), activeEndpoint: endpoint)
        #expect(try await repo.managementStacks().first?.assets.count == 2)
        #expect(try await repo.managementStacks().first?.assets.count == 3)
        #expect(await fixture.requests.count == 2)
        await repo.clear()
    }

    /// 成功HTTP也不能携带他人/已删除/重复成员；缺主图则保留只读而非伪装完整可写。
    @Test(arguments: ["owner", "trashed", "duplicate", "missing-primary"])
    func validatesReadScope(_ mode: String) async throws {
        let endpoint = stackEndpoint()
        let assets: String = switch mode {
        case "owner": stackAssetJSON(stackA, owner: stackB) + "," + stackAssetJSON(stackB)
        case "trashed": stackAssetJSON(stackA, trashed: true) + "," + stackAssetJSON(stackB)
        case "duplicate": stackAssetJSON(stackA) + "," + stackAssetJSON(stackA)
        default: stackAssetJSON(stackB) + "," + stackAssetJSON(stackC)
        }
        let json = #"[{"id":"\#(stackID)","primaryAssetId":"\#(stackA)","assets":[\#(assets)]}]"#
        let fixture = StackHTTPFixture(routes: ["GET /prefix/api/stacks": [.init(json: json)]])
        let repo = stackRepository(fixture)
        await repo.configure(session: stackSession(endpoint), activeEndpoint: endpoint)
        if mode == "missing-primary" {
            let values = try await repo.managementStacks()
            let value = try #require(values.first)
            #expect(!value.canManage && value.assets.count == 2)
        } else {
            await #expect(throws: TimelineReadError.invalidResponse) { _ = try await repo.managementStacks() }
        }
        await repo.clear()
    }

    /// PUT在真实HTTP等待点取消/换号/换端点/清理；实际session或Task撤销后不再fresh读取或重放写入。
    @Test(.timeLimit(.minutes(1)), arguments: ["account", "endpoint", "clear", "task"])
    func cancelsTheRealWriteSessionOnRetirement(_ mode: String) async throws {
        let endpoint = stackEndpoint()
        let fixture = StackHTTPFixture(routes: [
            "GET /prefix/api/stacks/\(stackID)": [.init(json: stackJSON(stackID, assets: [stackA, stackB]))],
            "PUT /prefix/api/stacks/\(stackID)": [.init(json: stackJSON(stackID, primary: stackB, assets: [stackB, stackA]), held: true)],
        ])
        StackHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { StackHTTPProtocol.remove(endpoint: endpoint) }
        let repo = stackRepository(fixture)
        await repo.configure(session: stackSession(endpoint), activeEndpoint: endpoint)
        let pending = Task {
            do { try await repo.changeNativeStack(.primary(stackModel([stackA, stackB]), assetID: stackB)) }
            catch { await fixture.failGate(); throw error }
        }
        guard await fixture.waitForGate() else { try await pending.value; Issue.record("Write must enter gate"); return }
        switch mode {
        case "account": await repo.configure(session: stackSession(endpoint, user: stackC), activeEndpoint: endpoint)
        case "endpoint": await repo.updateRoute(stackEndpoint())
        case "clear": await repo.clear()
        default: pending.cancel()
        }
        await fixture.release()
        if mode == "task" {
            await #expect(throws: CancellationError.self) { try await pending.value }
        } else {
            await #expect(throws: TimelineReadError.staleGeneration) { try await pending.value }
        }
        await fixture.waitForResponderExit()
        #expect(await fixture.requests.map(\.method) == ["GET", "PUT"])
        await repo.clear()
    }

    /// 账号/端点/clear/Task在真实GET预检在途时撤销，旧响应不再产生写请求。
    @Test(.timeLimit(.minutes(1)), arguments: ["account", "endpoint", "clear", "task"])
    func rejectsOldContextBeforeWrite(_ mode: String) async throws {
        let endpoint = stackEndpoint()
        let fixture = StackHTTPFixture(routes: ["GET /prefix/api/stacks/\(stackID)": [.init(json: stackJSON(stackID, assets: [stackA, stackB]), held: true)]])
        let repo = stackRepository(fixture)
        await repo.configure(session: stackSession(endpoint), activeEndpoint: endpoint)
        let pending = Task {
            do { try await repo.changeNativeStack(.dissolve(stackModel([stackA, stackB]))) }
            catch { await fixture.failGate(); throw error }
        }
        guard await fixture.waitForGate() else { try await pending.value; Issue.record("Preflight must enter gate"); return }
        switch mode {
        case "account": await repo.configure(session: stackSession(endpoint, user: stackB), activeEndpoint: endpoint)
        case "endpoint": await repo.updateRoute(stackEndpoint())
        case "clear": await repo.clear()
        default: pending.cancel()
        }
        await fixture.release()
        if mode == "task" {
            await #expect(throws: CancellationError.self) { try await pending.value }
        } else {
            await #expect(throws: TimelineReadError.staleGeneration) { try await pending.value }
        }
        #expect(await fixture.requests.map(\.method) == ["GET"])
        await repo.clear()
    }

    /// 官方列表和写前GET预检的401/403必须保留错误；不能显示假空列表或继续关系写入。
    @Test(arguments: [401, 403], ["list", "preflight"])
    @MainActor func permissionDenialNeverBecomesAnEmptyListOrAWrite(_ status: Int, _ phase: String) async throws {
        let endpoint = stackEndpoint()
        let route = phase == "list" ? "GET /prefix/api/stacks" : "GET /prefix/api/stacks/\(stackID)"
        let fixture = StackHTTPFixture(routes: [route: [.init(status: status, json: #"{"message":"Synthetic permission denial"}"#)]])
        let repo = stackRepository(fixture)
        await repo.configure(session: stackSession(endpoint), activeEndpoint: endpoint)
        if phase == "list" {
            let store = NativeStackManagementStore()
            await store.reload(source: repo)
            #expect(!store.hasLoaded && store.needsReload && store.error != nil && store.stacks.isEmpty)
        } else {
            do {
                try await repo.changeNativeStack(.dissolve(stackModel([stackA, stackB])))
                Issue.record("Denied preflight must not mutate stack relationships")
            } catch { #expect(!(error is CancellationError)) }
        }
        let requests = await fixture.requests
        #expect(requests.count == 1 && requests.first?.method == "GET")
        await repo.clear()
    }

    /// 真实POST权限失败锁定Store；再次点击不能重发，既有照片仅用于GET预检，从未删除或上传。
    @Test(arguments: [401, 403])
    @MainActor func deniedCreateLocksFurtherWritesUntilReload(_ status: Int) async {
        let endpoint = stackEndpoint()
        let fixture = StackHTTPFixture(routes: [
            "GET /prefix/api/stacks": [.init(json: "[]")],
            "GET /prefix/api/assets/\(stackA)": [.init(json: stackAssetJSON(stackA))],
            "GET /prefix/api/assets/\(stackB)": [.init(json: stackAssetJSON(stackB))],
            "POST /prefix/api/stacks": [.init(status: status, json: #"{"message":"Synthetic permission denial"}"#)],
        ])
        StackHTTPProtocol.install(fixture, endpoint: endpoint)
        defer { StackHTTPProtocol.remove(endpoint: endpoint) }
        let repo = stackRepository(fixture)
        await repo.configure(session: stackSession(endpoint), activeEndpoint: endpoint)
        let store = NativeStackManagementStore()
        await store.reload(source: repo)
        let change = NativeStackChange.create(assetIDs: [stackA, stackB], addingTo: nil)
        await store.perform(change, source: repo)
        #expect(store.needsReload && store.error != nil && store.notice == nil)
        await store.perform(change, source: repo)
        let requests = await fixture.requests
        #expect(requests.map(\.method) == ["GET", "GET", "GET", "POST"])
        #expect(requests.filter { $0.method != "GET" }.count == 1)
        await repo.clear()
    }
}

/// 测试专用合成UUID，既非私人资产也非真实账户。
private nonisolated let stackA = "11111111-1111-4111-8111-111111111111"
private nonisolated let stackB = "22222222-2222-4222-8222-222222222222"
private nonisolated let stackC = "33333333-3333-4333-8333-333333333333"
private nonisolated let stackID = "44444444-4444-4444-8444-444444444444"
private nonisolated let stackNewID = "55555555-5555-4555-8555-555555555555"
private nonisolated let stackUser = "66666666-6666-4666-8666-666666666666"

/// 独立host保留API前缀，任何意外请求也会被测试session拦住，不会出网。
private nonisolated func stackEndpoint() -> URL {
    URL(string: "https://\(UUID().uuidString.lowercased()).example.invalid/prefix/api")!
}

/// endpoint/user是明确合成身份；真实仓库配置仍执行，未绕过代际检查。
private nonisolated func stackSession(_ endpoint: URL, user: String = stackUser) -> AccountSession {
    .init(apiURL: endpoint, accessToken: "synthetic", userID: user, userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
          serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// fixture只提供SDK实际HTTP字节和窄writer会话响应；不替换任何业务操作实现。
private nonisolated func stackRepository(_ fixture: StackHTTPFixture) -> ImmichTimelineRepository {
    ImmichTimelineRepository(readLoader: { request, operation in
        #expect(operation == "searchStacks" || operation == "getStack")
        let captured = try StackCapturedRequest(request)
        return try await fixture.response(captured).response(url: captured.url)
    }, stackConfigurationFactory: { stackConfiguration() })
}

/// URLProtocol只属于该会话，取消保留实际URLSession行为，不全局注册。
private nonisolated func stackConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StackHTTPProtocol.self]
    return configuration
}

/// assets顺序为官方响应成员；primary缺省为A，id为实际stack身份。
private nonisolated func stackJSON(_ id: String, primary: String = stackA, assets: [String]) -> String {
    #"{"id":"\#(id)","primaryAssetId":"\#(primary)","assets":[\#(assets.map { stackAssetJSON($0) }.joined(separator: ","))]}"#
}

/// id/owner/状态为合成字段；包含固定SDK AssetResponseDto全部required字段，视频/图片字节不在此伪造。
private nonisolated func stackAssetJSON(_ id: String, owner: String = stackUser, trashed: Bool = false,
                                        visibility: String = "timeline", type: String = "IMAGE", stacked: Bool = false) -> String
{
    let nested = stacked ? #"{"id":"\#(stackID)","assetCount":2,"primaryAssetId":"\#(stackA)"}"# : "null"
    return #"{"id":"\#(id)","ownerId":"\#(owner)","type":"\#(type)","isTrashed":\#(trashed),"visibility":"\#(visibility)","stack":\#(nested),"checksum":"c3ludGhldGlj","createdAt":"2026-11-24T00:00:00.000Z","duration":null,"fileCreatedAt":"2026-11-24T00:00:00.000Z","fileModifiedAt":"2026-11-24T00:00:00.000Z","hasMetadata":true,"height":48,"isArchived":false,"isEdited":false,"isFavorite":false,"isOffline":false,"localDateTime":"2026-11-24T00:00:00.000Z","originalFileName":"synthetic.png","originalPath":"/synthetic.png","thumbhash":null,"updatedAt":"2026-11-24T00:00:00.000Z","width":64}"#
}

/// ids为合成成员，返回与真实DTO映射相同的领域快照，用于确认前状态比较。
private nonisolated func stackModel(_ ids: [String]) -> ManagedNativeStack {
    .init(id: stackID, primaryAssetID: stackA, assets: ids.map { id in
        .init(id: id, ownerID: stackUser, capturedAt: .distantPast, uploadedAt: .distantPast,
              localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
              isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
              projectionType: nil, thumbhash: nil, thumbnailRevision: .distantPast)
    })
}

/// 真实URLSession/SDK请求字节快照，有限收集stream正文以避免写入JSON未被测试实际检查。
private nonisolated struct StackCapturedRequest: Sendable {
    let method: String
    let url: URL
    let authorization: String?
    let body: Data?

    /// request是实际发送内容，保留完整路径/方法/认证，读取POST流体而非重构请求。
    init(_ request: URLRequest) throws {
        method = try #require(request.httpMethod)
        url = try #require(request.url)
        authorization = request.value(forHTTPHeaderField: "Authorization")
        if let bytes = request.httpBody {
            body = bytes
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 {
                    break
                }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 1_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
            }
            body = data
        } else {
            body = nil
        }
    }

    /// 返回已发送JSON完整字典，缺正文立即失败，防止只比对局部字段。
    func jsonBody() throws -> NSDictionary {
        let bytes = try #require(body)
        let object = try JSONSerialization.jsonObject(with: bytes)
        return try #require(object as? NSDictionary)
    }
}

/// 独立原始HTTP状态/正文；held只控制真实响应何时返回，以验证旧代际边界。
private nonisolated struct StackHTTPReply: Sendable {
    var status = 200
    let json: String
    var held = false

    /// url来自真实请求；不改写状态和响应内容，SDK自行解码。
    func response(url: URL) throws -> (Data, HTTPURLResponse) {
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (Data(json.utf8), response)
    }
}

/// 有限HTTP脚本逐条消费，缺路由报错，显式gate避免用sleep猜测在途时序。
private actor StackHTTPFixture {
    private var routes: [String: [StackHTTPReply]]
    private(set) var requests: [StackCapturedRequest] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var failed = false
    private var stopped = false
    private var heldResponderExited = false
    private var exitWaiter: CheckedContinuation<Void, Never>?

    /// routes以方法+完整路径定义响应，重复GET也必须真实消费下一项。
    init(routes: [String: [StackHTTPReply]]) {
        self.routes = routes
    }

    /// request保留实际字节；返回下一响应或挂起，额外写/重试没有脚本可用。
    func response(_ request: StackCapturedRequest) async throws -> StackHTTPReply {
        guard !stopped else { throw CancellationError() }
        requests.append(request)
        let key = request.method + " " + request.url.path
        guard var replies = routes[key], !replies.isEmpty else { failGate(); throw URLError(.badServerResponse) }
        let value = replies.removeFirst(); routes[key] = replies
        if value.held {
            await withCheckedContinuation { pending = $0; waiter?.resume(returning: true); waiter = nil }
        }
        return value
    }

    /// 请求/解码在gate前失败也唤醒测试，不能把编译外的运行故障变成永久等待。
    func failGate() {
        failed = true; waiter?.resume(returning: false); waiter = nil
    }

    /// 返回true表示真实请求已挂起，false表示原操作先失败；测试超时取消会释放全部等待，不留永久continuation。
    func waitForGate() async -> Bool {
        if pending != nil {
            return true
        }
        if failed {
            return false
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: { Task { await self.stop() } }
    }

    /// 撤销仓库上下文后释放旧响应，实际业务守卫决定能否继续写。
    func release() {
        pending?.resume(); pending = nil
    }

    /// URLProtocol实际结束后才唤醒；仅HTTP写gate使用，避免只等业务Task而提早移除host。
    func responderExited() {
        heldResponderExited = true; exitWaiter?.resume(); exitWaiter = nil
    }

    /// 等待实际被hold的HTTP响应任务退出，提前失败/取消清理时不产生不可达等待。
    func waitForResponderExit() async {
        guard !heldResponderExited, !stopped else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { exitWaiter = $0 }
        } onCancel: { Task { await self.stop() } }
    }

    /// 清理或测试超时先阻止未来hold，再恢复当前读/写/退出等待；不产生任何网络业务结果。
    func stop() {
        stopped = true; failGate(); release(); exitWaiter?.resume(); exitWaiter = nil
    }
}

/// 每个测试host隔离的本地HTTP响应器；真实URLSession撤销会终止任务，不发网络请求。
private final nonisolated class StackHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let fixtures = Mutex<[String: StackHTTPFixture]>([:])
    private let loading = Mutex<(stopped: Bool, task: Task<Void, Never>?)>((false, nil))

    /// endpoint是测试独占host，fixture只服务此会话。
    static func install(_ fixture: StackHTTPFixture, endpoint: URL) {
        fixtures.withLock { $0[endpoint.host!] = fixture }
    }

    /// 测试结束移除本host，不影响其他并发测试。
    static func remove(endpoint: URL) {
        if let fixture = fixtures.withLock({ $0.removeValue(forKey: endpoint.host!) }) {
            Task { await fixture.stop() }
        }
    }

    /// 拦截该session所有请求，未注册host也不得出网。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 原样保留请求以测试API前缀/ID路径和方法。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 将原始请求交给脚本，真实错误走URLSession错误回调；停止后的任务不能发布成功。
    override func startLoading() {
        do {
            let captured = try StackCapturedRequest(request)
            let fixture = try #require(Self.fixtures.withLock { $0[captured.url.host ?? ""] })
            let task = Task { @Sendable [weak self, fixture, captured] in
                defer { Task { @Sendable in await fixture.responderExited() } }
                do {
                    let reply = try await fixture.response(captured)
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    let (data, response) = try reply.response(url: captured.url)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
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

    /// 标记停止并取消实际响应任务，迟到gate释放不能产生成功回调。
    override func stopLoading() {
        loading.withLock { $0.stopped = true; $0.task?.cancel() }
    }
}
