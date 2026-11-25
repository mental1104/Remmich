import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 真实Store→manager→HTTP目录路径测试；只有服务端字节与响应时序是纯合成夹具。
@Suite("Album directory management")
struct AlbumDirectoryManagementTests {
    /// kind覆盖全部可达目录命令；独立声明方法/完整body/写后快照，确认每次写后都真实重读。
    @Test(arguments: ["create", "rename", "delete", "assign", "default", "ungrouped", "move", "clear"])
    @MainActor func writesAndReloadsTheActualDirectory(_ kind: String) async throws {
        let command: AlbumDirectoryCommand
        let write: DirectoryExchange
        let body: String?
        let nextState: String
        let nextAlbums: String
        switch kind {
        case "create":
            command = .createCategory(name: "  New category  ")
            write = .init(method: "POST", path: "fork/album-categories", status: 201,
                          json: #"{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","name":"New category"}"#)
            body = #"{"name":"New category"}"#
            nextState = #"{"categories":[{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","name":"New category"}],"groups":[]}"#
            nextAlbums = directoryAlbums
        case "rename":
            command = .renameCategory(id: directoryCategoryID, name: "  Trips  ")
            write = .init(method: "PATCH", path: "fork/album-categories/\(directoryCategoryID)", status: 200,
                          json: #"{"id":"\#(directoryCategoryID)","name":"Trips"}"#)
            body = #"{"name":"Trips"}"#; nextState = directoryState.replacingOccurrences(of: "Travel", with: "Trips")
            nextAlbums = directoryAlbums
        case "delete":
            command = .deleteCategory(id: directoryCategoryID)
            write = .init(method: "DELETE", path: "fork/album-categories/\(directoryCategoryID)", status: 204, json: "")
            body = nil; nextState = #"{"categories":[],"groups":[]}"#; nextAlbums = directoryAlbums
        case "assign", "default", "ungrouped":
            let group = kind == "ungrouped" ? "" : "North"
            command = .assignGroup(name: group, categoryID: kind == "default" ? nil : directoryCategoryID)
            write = .init(method: "PUT", path: "fork/album-categories/group", status: 204, json: "")
            body = kind == "default" ? #"{"groupName":"North","categoryId":null}"#
                : #"{"groupName":"\#(group)","categoryId":"\#(directoryCategoryID)"}"#
            nextState = kind == "default" ? #"{"categories":[{"id":"\#(directoryCategoryID)","name":"Travel"}],"groups":[]}"#
                : #"{"categories":[{"id":"\#(directoryCategoryID)","name":"Travel"}],"groups":[{"groupName":"\#(group)","categoryId":"\#(directoryCategoryID)"}]}"#
            nextAlbums = directoryAlbums
        default:
            command = .moveAlbum(id: directoryAlbumID, groupName: kind == "clear" ? " \n " : "  South  ")
            let response = kind == "clear" ? "null" : #""South""#
            write = .init(method: "PATCH", path: "albums/\(directoryAlbumID)", status: 200,
                          json: #"{"id":"\#(directoryAlbumID)","albumName":"Owned album","ownerId":"owner","customGroupName":\#(response)}"#)
            body = #"{"customGroupName":\#(response)}"#
            nextState = #"{"categories":[{"id":"\#(directoryCategoryID)","name":"Travel"}],"groups":[]}"#
            nextAlbums = directoryAlbums.replacingOccurrences(of: #""North""#, with: response)
        }
        let preflight = kind == "move" || kind == "clear" ? [directoryAlbumPreflight()] : []
        let fixture = DirectoryFixture(exchanges: directoryReads() + preflight + [write] + directoryReads(state: nextState, albums: nextAlbums))
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        try await loadDirectory(store, fixture: fixture)
        let plan = try store.prepare(command, manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        #expect(store.hasFreshData && !store.isWorking && store.error == nil && store.notice != nil)
        #expect(fixture.manager.revision == 1 && !fixture.manager.busy)
        let requests = await fixture.script.requests()
        try #require(requests.count == 5 + preflight.count)
        try assertDirectoryBody(requests[2 + preflight.count], expected: body)
        #expect(requests.map(\.method) == ["GET", "GET"] + preflight.map(\.method) + [write.method, "GET", "GET"])
        let directory = try #require(store.directory)
        if kind == "delete" || kind == "default" {
            #expect(directory.categoryID(for: "North") == nil)
        }
        if kind == "rename" {
            #expect(directory.categoryName(for: "North") == "Trips")
        }
        if kind == "assign" {
            #expect(directory.categoryID(for: "North") == directoryCategoryID)
        }
        if kind == "ungrouped" {
            #expect(directory.categoryID(for: "") == directoryCategoryID)
        }
        if kind == "move" || kind == "clear" {
            #expect(directory.albums.first?.groupName == (kind == "clear" ? "" : "South"))
            #expect(directory.categoryID(for: kind == "clear" ? "" : "South") == nil)
        }
        #expect(directory.albums.count == 2)
        #expect(store.start(plan, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == 5 + preflight.count)
    }

    /// status含错成功码与权限/冲突/限流/服务异常；失败后不自动重放或伪装成功，明确重载才恢复。
    @Test(arguments: [201, 401, 403, 404, 409, 429, 503])
    @MainActor func rejectedOrUnconfirmedWritesRequireReload(_ status: Int) async throws {
        let write = DirectoryExchange(method: "PATCH", path: "fork/album-categories/\(directoryCategoryID)", status: status,
                                      json: #"{"id":"\#(directoryCategoryID)","name":"Trips"}"#)
        let fixture = DirectoryFixture(exchanges: directoryReads() + [write] + directoryReads())
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        try await loadDirectory(store, fixture: fixture)
        let plan = try store.prepare(.renameCategory(id: directoryCategoryID, name: "Trips"), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        #expect(!store.hasFreshData && !store.isWorking && store.error != nil && store.notice == nil && !store.isUnsupported)
        #expect(fixture.manager.revision == (status == 201 || status == 503 ? 1 : 0))
        #expect(store.start(plan, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == 3)
        try await loadDirectory(store, fixture: fixture)
        _ = try store.prepare(.renameCategory(id: directoryCategoryID, name: "Another name"), manager: fixture.manager)
        #expect(await fixture.script.requests().count == 5)
    }

    /// kind/status覆盖其余写方法的权限拒绝和错误成功码，不能因2xx或空body就误认完成。
    @Test(arguments: ["create", "delete", "assign", "move"], ["wrong-success", "forbidden"])
    @MainActor func everyDirectoryWriteEnforcesItsStatusAndPermissions(_ kind: String, _ status: String) async throws {
        let command: AlbumDirectoryCommand
        let method: String
        let path: String
        let json: String
        switch kind {
        case "create":
            command = .createCategory(name: "New category"); method = "POST"; path = "fork/album-categories"
            json = #"{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","name":"New category"}"#
        case "delete":
            command = .deleteCategory(id: directoryCategoryID); method = "DELETE"; path = "fork/album-categories/\(directoryCategoryID)"; json = "{}"
        case "assign":
            command = .assignGroup(name: "North", categoryID: nil); method = "PUT"; path = "fork/album-categories/group"; json = "{}"
        default:
            command = .moveAlbum(id: directoryAlbumID, groupName: "South"); method = "PATCH"; path = "albums/\(directoryAlbumID)"
            json = #"{"id":"\#(directoryAlbumID)","albumName":"Owned album","ownerId":"owner","customGroupName":"South"}"#
        }
        let preflight = kind == "move" ? [directoryAlbumPreflight()] : []
        let fixture = DirectoryFixture(exchanges: directoryReads() + preflight + [
            .init(method: method, path: path, status: status == "forbidden" ? 403 : kind == "move" ? 201 : 200, json: json),
        ])
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        try await loadDirectory(store, fixture: fixture)
        let operation = try #require(try store.start(store.prepare(command, manager: fixture.manager), manager: fixture.manager))
        await operation.value
        #expect(!store.hasFreshData && !store.isUnsupported && store.notice == nil && store.error != nil)
        #expect(fixture.manager.revision == (status == "forbidden" ? 0 : 1))
        #expect(await fixture.script.requests().count == 3 + preflight.count)
    }

    /// 用户取消已经发送的写入时，未知结果必须显式核对；取消不生成新的自动GET或重发命令。
    @Test @MainActor func cancellationOfAnInflightWriteRequiresExplicitReload() async throws {
        let fixture = DirectoryFixture(exchanges: directoryReads() + [
            .init(method: "PUT", path: "fork/album-categories/group", status: 204, json: "", held: true),
        ])
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        try await loadDirectory(store, fixture: fixture)
        let plan = try store.prepare(.assignGroup(name: "North", categoryID: nil), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        let completion = Task { await operation.value; await fixture.script.operationFinished() }
        #expect(await fixture.script.waitForHeldRequest())
        store.cancel()
        await fixture.script.release()
        await completion.value
        #expect(!store.hasFreshData && !store.isWorking && store.notice == nil && store.error != nil)
        #expect(!fixture.manager.busy && fixture.manager.revision == 1)
        #expect(store.start(plan, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == 3)
    }

    /// 缺扩展只识别可选GET的404/405/501；401/403不展示成“正常空目录”，也不再读取相簿。
    @Test(arguments: [401, 403, 404, 405, 501])
    @MainActor func missingExtensionAndAuthenticationRemainDifferent(_ status: Int) async throws {
        let fixture = DirectoryFixture(exchanges: [.init(method: "GET", path: "fork/album-categories", status: status, json: "{}")])
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        let read = try #require(store.reload(manager: fixture.manager))
        await read.value
        let unsupported = [404, 405, 501].contains(status)
        #expect(store.isUnsupported == unsupported && (store.error == nil) == unsupported)
        #expect(!store.hasFreshData && store.directory == nil && !store.isLoading)
        #expect(throws: AlbumDirectoryManagementError.self) {
            try store.prepare(.createCategory(name: "Trip"), manager: fixture.manager)
        }
        #expect(await fixture.script.requests().count == 1)
    }

    /// 默认大组/非法输入/不可见分组/别人相簿不能形成可执行计划；Unicode长度按服务端UTF16衡量。
    @Test @MainActor func validatesVisibleSelectionsBeforeAnyWrite() async throws {
        let fixture = DirectoryFixture(exchanges: directoryReads())
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        try await loadDirectory(store, fixture: fixture)
        for name in [" \n ", "默认", String(repeating: "a", count: 101), String(repeating: "😀", count: 51)] {
            #expect(throws: AlbumDirectoryManagementError.self) { try store.prepare(.createCategory(name: name), manager: fixture.manager) }
        }
        _ = try store.prepare(.createCategory(name: String(repeating: "😀", count: 50)), manager: fixture.manager)
        #expect(throws: AlbumDirectoryManagementError.self) { try store.prepare(.deleteCategory(id: ForkAlbumDirectory.defaultCategory), manager: fixture.manager) }
        #expect(throws: AlbumDirectoryManagementError.self) { try store.prepare(.assignGroup(name: "Missing", categoryID: nil), manager: fixture.manager) }
        #expect(throws: AlbumDirectoryManagementError.self) { try store.prepare(.assignGroup(name: "North", categoryID: directoryAlbumID), manager: fixture.manager) }
        #expect(throws: AlbumDirectoryManagementError.self) { try store.prepare(.moveAlbum(id: directorySharedID, groupName: "South"), manager: fixture.manager) }
        #expect(await fixture.script.requests().count == 2)
    }

    /// 写已确认但后续读取失败时保留成功回执，禁止再写；显式重载读取真实状态后才恢复。
    @Test @MainActor func savedChangeWithFailedRefreshIsNotReportedAsFullyFresh() async throws {
        let fixture = DirectoryFixture(exchanges: directoryReads() + [
            .init(method: "DELETE", path: "fork/album-categories/\(directoryCategoryID)", status: 204, json: ""),
            .init(method: "GET", path: "fork/album-categories", status: 503, json: "{}"),
        ] + directoryReads(state: #"{"categories":[],"groups":[]}"#))
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        try await loadDirectory(store, fixture: fixture)
        let plan = try store.prepare(.deleteCategory(id: directoryCategoryID), manager: fixture.manager)
        let operation = try #require(store.start(plan, manager: fixture.manager))
        await operation.value
        #expect(store.notice != nil && store.error != nil && !store.hasFreshData && fixture.manager.revision == 1)
        #expect(store.start(plan, manager: fixture.manager) == nil)
        try await loadDirectory(store, fixture: fixture)
        #expect(store.directory?.categoryID(for: "North") == nil)
        #expect(store.directory?.albums.count == 2 && fixture.manager.revision == 1)
    }

    /// variant是错误回执类型；HTTP200仍须身份/真实group字段一致，不能拿静默忽略或错误对象确认写成。
    @Test(arguments: ["wrong-id", "wrong-name", "missing-group", "wrong-group"])
    @MainActor func validatesReturnedIdentityAndGroupField(_ variant: String) async throws {
        let isGroup = variant.contains("group")
        let command: AlbumDirectoryCommand = isGroup ? .moveAlbum(id: directoryAlbumID, groupName: nil)
            : .renameCategory(id: directoryCategoryID, name: "Trips")
        let json = switch variant {
        case "wrong-id": #"{"id":"\#(directorySharedID)","name":"Trips"}"#
        case "wrong-name": #"{"id":"\#(directoryCategoryID)","name":"Travel"}"#
        case "missing-group": #"{"id":"\#(directoryAlbumID)","albumName":"Owned album","ownerId":"owner"}"#
        default: #"{"id":"\#(directoryAlbumID)","albumName":"Owned album","ownerId":"owner","customGroupName":"North"}"#
        }
        let preflight = isGroup ? [directoryAlbumPreflight()] : []
        let fixture = DirectoryFixture(exchanges: directoryReads() + preflight + [
            .init(method: "PATCH", path: isGroup ? "albums/\(directoryAlbumID)" : "fork/album-categories/\(directoryCategoryID)", status: 200, json: json),
        ])
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        try await loadDirectory(store, fixture: fixture)
        let operation = try #require(try store.start(store.prepare(command, manager: fixture.manager), manager: fixture.manager))
        await operation.value
        #expect(!store.hasFreshData && store.notice == nil && store.error != nil)
        #expect(fixture.manager.revision == 1)
        #expect(await fixture.script.requests().count == 3 + preflight.count)
    }

    /// scenario以真实在途GET/PATCH触发账号或端点变更；旧任务不能覆盖新快照或增加新上下文revision。
    @Test(arguments: ["read-account", "read-endpoint", "write-account", "write-endpoint"])
    @MainActor func lateResponsesCannotEnterTheNextContext(_ scenario: String) async throws {
        let reading = scenario.hasPrefix("read")
        let changingAccount = scenario.hasSuffix("account")
        let prefix = changingAccount ? "" : "fallback/"
        let nextAuthorization = changingAccount ? "Bearer synthetic-next-owner" : "Bearer synthetic-owner"
        let held: [DirectoryExchange] = reading ? [.init(method: "GET", path: "fork/album-categories", status: 200, json: directoryState, held: true)]
            : directoryReads() + [.init(method: "PATCH", path: "fork/album-categories/\(directoryCategoryID)", status: 200,
                                        json: #"{"id":"\#(directoryCategoryID)","name":"Trips"}"#, held: true)]
        let fresh = directoryReads(state: #"{"categories":[{"id":"\#(directoryCategoryID)","name":"Travel"}],"groups":[]}"#,
                                   albums: directoryAlbums.replacingOccurrences(of: "North", with: "South"))
            .map { DirectoryExchange(method: $0.method, path: prefix + $0.path, status: $0.status, json: $0.json, authorization: nextAuthorization) }
        let fixture = DirectoryFixture(exchanges: held + fresh)
        defer { fixture.close() }
        let store = AlbumDirectoryManagementStore()
        let operation: Task<Void, Never>
        if reading {
            operation = try #require(store.reload(manager: fixture.manager))
        } else {
            try await loadDirectory(store, fixture: fixture)
            operation = try #require(try store.start(store.prepare(.renameCategory(id: directoryCategoryID, name: "Trips"), manager: fixture.manager), manager: fixture.manager))
        }
        let completion = Task { await operation.value; await fixture.script.operationFinished() }
        #expect(await fixture.script.waitForHeldRequest())
        let endpoint = changingAccount ? fixture.endpoint : fixture.endpoint.appending(path: "fallback")
        fixture.manager.configure(session: directorySession(endpoint: endpoint, user: changingAccount ? "next-owner" : "owner"), endpoint: endpoint)
        #expect(throws: AlbumDirectoryManagementError.self) { try store.prepare(.createCategory(name: "New account category"), manager: fixture.manager) }
        store.invalidate()
        try await loadDirectory(store, fixture: fixture)
        await fixture.script.release()
        await completion.value
        #expect(store.directory?.albums.first?.groupName == "South" && store.hasFreshData && store.error == nil)
        #expect(!store.isWorking && !store.isLoading && fixture.manager.revision == 0 && !fixture.manager.busy)
        #expect(await fixture.script.requests().count == (reading ? 3 : 5))
    }
}

/// 合成UUID仅用于本地响应，不读取真实账号/相簿/媒体。
private nonisolated let directoryCategoryID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
private nonisolated let directoryAlbumID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private nonisolated let directorySharedID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private nonisolated let directoryState = #"{"categories":[{"id":"\#(directoryCategoryID)","name":"Travel"}],"groups":[{"groupName":"North","categoryId":"\#(directoryCategoryID)"}]}"#
private nonisolated let directoryAlbums = #"[{"id":"\#(directoryAlbumID)","albumName":"Owned album","ownerId":"owner","customGroupName":"North"},{"id":"\#(directorySharedID)","albumName":"Shared album","ownerId":"someone-else","customGroupName":null}]"#

/// 仅相簿属性写新增fresh角色预检；明确旧owner响应保留旧夹具，其余个人目录动作不新增权限GET。
private nonisolated func directoryAlbumPreflight() -> DirectoryExchange {
    .init(method: "GET", path: "albums/\(directoryAlbumID)", status: 200,
          json: #"{"id":"\#(directoryAlbumID)","albumName":"Owned album","ownerId":"owner","customGroupName":"North"}"#)
}

/// state/albums是独立声明的固定JSON；返回真实顺序的两个GET交换，写后调用也必须消耗新响应。
private nonisolated func directoryReads(state: String = directoryState, albums: String = directoryAlbums) -> [DirectoryExchange] {
    [.init(method: "GET", path: "fork/album-categories", status: 200, json: state), .init(method: "GET", path: "albums", status: 200, json: albums)]
}

/// endpoint/user创建隔离合成登录上下文，不访问Keychain、磁盘或外部服务。
private nonisolated func directorySession(endpoint: URL, user: String = "owner") -> AccountSession {
    .init(apiURL: endpoint, accessToken: "synthetic-\(user)", userID: user, userEmail: "\(user)@example.invalid", name: user,
          isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
}

/// store/fixture使用真实重载入口；等待两次GET均完成后断言写入前置条件。
@MainActor private func loadDirectory(_ store: AlbumDirectoryManagementStore, fixture: DirectoryFixture) async throws {
    let read = try #require(store.reload(manager: fixture.manager))
    await read.value
    #expect(store.hasFreshData && !store.isLoading && !store.isUnsupported && store.error == nil)
}

/// 一次固定服务器响应；held暂停真实在途请求，authorization支持测试账号切换。
private nonisolated struct DirectoryExchange: Sendable {
    let method: String
    let path: String
    let status: Int
    let json: String
    var held = false
    var authorization = "Bearer synthetic-owner"
}

/// URLSession真实请求的不可变快照；有限JSON流在回调线程完整读取，避免跨actor传递Foundation流。
private nonisolated struct DirectoryRequest: Sendable {
    let method: String
    let url: URL
    let authorization: String?
    let contentType: String?
    let cookie: String?
    let body: Data?

    /// request是本测试会话发送值；body最多100KB，未设置JSON体的GET/DELETE保持nil。
    init(_ request: URLRequest) throws {
        guard let method = request.httpMethod, let url = request.url else { throw URLError(.badURL) }
        self.method = method; self.url = url
        authorization = request.value(forHTTPHeaderField: "Authorization")
        contentType = request.value(forHTTPHeaderField: "Content-Type"); cookie = request.value(forHTTPHeaderField: "Cookie")
        if let data = request.httpBody {
            body = data
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 2048)
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

/// 隔离响应脚本只掌管字节/时序，不修改业务状态；所有意外请求失败，不进入真实网络。
private actor DirectoryScript {
    private let exchanges: [DirectoryExchange]
    private var captured: [DirectoryRequest] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Bool, Never>?
    private var observed = false
    private var finished = false

    /// exchanges独立定义预期路径和响应，不根据生产命令推导应答。
    init(_ exchanges: [DirectoryExchange]) {
        self.exchanges = exchanges
    }

    /// request保存真实方法/身份/头/体；endpoint为本测试根地址，held只暂停预先指定的一次响应。
    func response(_ request: DirectoryRequest, endpoint: URL) async throws -> DirectoryExchange {
        let index = captured.count; captured.append(request)
        guard exchanges.indices.contains(index) else { throw URLError(.badServerResponse) }
        let exchange = exchanges[index]
        guard request.method == exchange.method, request.url == endpoint.appending(path: exchange.path),
              request.authorization == exchange.authorization, request.cookie == nil,
              request.contentType == (request.body == nil ? nil : "application/json") else { throw URLError(.badServerResponse) }
        if exchange.held {
            await withCheckedContinuation { continuation in
                pending = continuation; observed = true; observer?.resume(returning: true); observer = nil
            }
        }
        return exchange
    }

    /// 返回不可变捕获值供测试断言，不在URLSession回调里隐藏失败。
    func requests() -> [DirectoryRequest] {
        captured
    }

    /// 已捕获在途请求返回true；业务任务若提前失败返回false，避免回归导致测试无限等待。
    func waitForHeldRequest() async -> Bool {
        if observed {
            return true
        }
        if finished {
            return false
        }
        return await withCheckedContinuation { observer = $0 }
    }

    /// 操作结束时唤醒尚未到达gate的观察者；不生成服务端成功回执。
    func operationFinished() {
        finished = true
        if !observed {
            observer?.resume(returning: false); observer = nil
        }
    }

    /// 测试显式释放旧响应；真实取消仍由URLProtocol遵守，不向新上下文强塞成功。
    func release() {
        pending?.resume(); pending = nil
    }
}

/// 每个测试独占随机.invalid host、真实manager及私有URLSession配置。
@MainActor private struct DirectoryFixture {
    let endpoint: URL
    let manager: LibraryManagementController
    let script: DirectoryScript

    /// exchanges指定独立HTTP序列；配置工厂仅影响本manager，不修改正常构造或全局URLProtocol注册。
    init(exchanges: [DirectoryExchange]) {
        endpoint = URL(string: "https://directory-\(UUID().uuidString.lowercased()).invalid/api")!
        script = DirectoryScript(exchanges)
        DirectoryProtocol.install(script, endpoint: endpoint)
        manager = LibraryManagementController(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DirectoryProtocol.self]
            return configuration
        })
        manager.configure(session: directorySession(endpoint: endpoint), endpoint: endpoint)
    }

    /// 取消本manager真实会话并移除本测试host，不碰其他测试/正常连接。
    func close() {
        manager.configure(session: nil, endpoint: nil)
        DirectoryProtocol.remove(endpoint: endpoint)
    }
}

/// request是实际写请求，expected是独立完整JSON或nil无body；逐字值比较避免把null误省略。
private nonisolated func assertDirectoryBody(_ request: DirectoryRequest, expected: String?) throws {
    if let expected {
        let actual = try JSONSerialization.jsonObject(with: #require(request.body))
        let expected = try JSONSerialization.jsonObject(with: Data(expected.utf8))
        #expect(try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
    } else {
        #expect(request.body == nil)
    }
}

/// 私有HTTP响应器拦截本测试会话全部请求；取消状态与任务指针在回调线程间由Mutex保护。
private final nonisolated class DirectoryProtocol: URLProtocol, @unchecked Sendable {
    /// 一个随机host的响应器与API根，不共享业务状态。
    private struct Entry: Sendable { let script: DirectoryScript; let endpoint: URL }
    /// URLSession取消与异步响应任务的同步状态。
    private struct Loading: Sendable { var stopped = false; var task: Task<Void, Never>? }
    private static let scripts = Mutex<[String: Entry]>([:])
    private let loading = Mutex(Loading())

    /// script/endpoint只注册到本类私有表；不会调用URLProtocol.registerClass。
    static func install(_ script: DirectoryScript, endpoint: URL) {
        scripts.withLock { $0[endpoint.host!] = .init(script: script, endpoint: endpoint) }
    }

    /// 移除本测试endpoint，不影响其他并行测试。
    static func remove(endpoint: URL) {
        _ = scripts.withLock { $0.removeValue(forKey: endpoint.host!) }
    }

    /// 拦截包括错误host在内的所有会话请求，禁止回落到真实网络。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// request原样进入验证，不修正生产客户端发出的路由或body。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 捕获真实请求并通过固定脚本回传HTTP响应；任何捕获/协议异常使真正URLSession失败。
    override func startLoading() {
        do {
            let capturedRequest = try DirectoryRequest(request)
            guard let entry = Self.scripts.withLock({ $0[capturedRequest.url.host ?? ""] }) else { throw URLError(.badURL) }
            // 显式发送不可变请求和Sendable脚本条目，避免继承URLProtocol回调的隔离推断。
            let task = Task { @Sendable [weak self, capturedRequest, entry] in
                do {
                    let exchange = try await entry.script.response(capturedRequest, endpoint: entry.endpoint)
                    guard let self, !Task.isCancelled, !self.loading.withLock({ $0.stopped }) else { return }
                    guard let response = HTTPURLResponse(url: capturedRequest.url, statusCode: exchange.status, httpVersion: nil,
                                                         headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(exchange.json.utf8))
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

    /// 遵守真实URLSession取消，旧脚本即使以后释放也不得再次交付字节。
    override func stopLoading() {
        let task = loading.withLock { $0.stopped = true; return $0.task }
        task?.cancel()
    }
}
