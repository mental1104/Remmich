import Foundation
import Testing
@testable import Remmich

/// 真Store→manager→客户端的公开链接合同；仅私有URLSession响应为合成数据，所有密码/密钥均为测试常量。
@Suite("Album public link contracts")
@MainActor struct AlbumPublicLinkContractTests {
    /// 新query字段默认关闭时，既有GET/POST/PUT客户端请求保留原URL/Bearer/body，不能改变备份等旧夹具边界。
    @Test(arguments: ["read", "create", "role"])
    func existingFixtureRequestsKeepTheirDefaultPath(_ kind: String) async throws {
        let album = publicAlbumJSON()
        let method = kind == "read" ? "GET" : kind == "create" ? "POST" : "PUT"
        let path = kind == "read" ? "albums/\(publicAlbumID)" : kind == "create" ? "albums" : "albums/\(publicAlbumID)/user/\(publicCurrentID)"
        let fixture = ChecksumLookupHTTPFixture(exchanges: [.init(method: method, path: path,
                                                                  status: kind == "role" ? 204 : kind == "create" ? 201 : 200,
                                                                  json: kind == "role" ? "" : album)])
        defer { fixture.close() }
        let client = try #require(fixture.manager.client)
        if kind == "read" {
            _ = try await client.sharingAlbum(publicAlbumID)
        } else if kind == "create" {
            _ = try await client.createAlbum(name: "Synthetic public album")
        } else {
            try await client.changeAlbumSharing(.role(id: publicCurrentID, role: .viewer), albumID: publicAlbumID)
        }
        let requests = await fixture.script.requests(); try #require(requests.count == 1)
        #expect(requests[0].url == fixture.endpoint.appending(path: path) && requests[0].url.query == nil)
        #expect(requests[0].authorization == "Bearer checksum-owner" && requests[0].cookie == nil)
        if kind == "read" {
            #expect(requests[0].body == nil)
        } else {
            #expect(requests[0].body != nil && requests[0].contentType == "application/json")
        }
    }

    /// 创建按真实owner/editor权限；POST回执故意不含album，必须fresh详情和过滤列表均确认才发布成功。
    @Test(arguments: ["owner", "editor"])
    func createsOnlyAfterExplicitConfirmationAndFreshReads(_ role: String) async throws {
        let album = publicAlbumJSON(role: role)
        let receipt = try publicLinkJSON(options: publicNewOptions, album: false)
        let detail = try publicLinkJSON(options: publicNewOptions)
        let fixture = ChecksumLookupHTTPFixture(exchanges: publicReads(album: album, links: "[]") + [
            publicAlbumRead(album), publicList("[]"), .init(method: "POST", path: "shared-links", status: 201, json: receipt),
            publicDetail(detail), publicList("[\(detail)]"),
        ])
        defer { fixture.close() }
        let store = AlbumPublicLinkStore(); await store.reload(manager: fixture.manager)?.value
        try #require(store.hasFreshData && store.links.isEmpty)
        let plan = try store.prepare(.create(newPublicOptions()), manager: fixture.manager)
        #expect(await fixture.script.requests().count == 3)
        let operation = try #require(store.start(plan, manager: fixture.manager)); await operation.value
        #expect(store.hasFreshData && store.links.count == 1 && store.notice != nil && store.error == nil && !store.isWorking)
        #expect(fixture.manager.revision == 1 && !fixture.manager.busy)
        let requests = await fixture.script.requests(); try #require(requests.count == 8)
        try assertPublicBody(requests[5], expected: publicNewOptions, creating: true)
        #expect(requests.filter { $0.method == "POST" }.count == 1 && requests[6].method == "GET")
        #expect(store.start(plan, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == 8)
    }

    /// 已有链接只认创建者；viewer/未知相簿角色仍可管理自己的链接，密码/slug保留、替换、清除均显式编码。
    @Test(arguments: ["keep", "replace", "clear"], ["viewer", "future-role"])
    func updatesCreatorOptionsWithoutRequiringAlbumShare(_ mode: String, _ role: String) async throws {
        let baseline = try publicLinkJSON(); let nextOptions = publicUpdatedOptions(mode)
        let after = try publicLinkJSON(options: nextOptions)
        let fixture = try ChecksumLookupHTTPFixture(exchanges: publicReads(album: publicAlbumJSON(role: role), links: "[\(baseline)]") + [
            publicDetail(baseline), .init(method: "PATCH", path: "shared-links/\(publicLinkID)", status: 200,
                                          json: publicLinkJSON(options: nextOptions, album: false)), publicDetail(after), publicList("[\(after)]"),
        ])
        defer { fixture.close() }
        let store = AlbumPublicLinkStore(); await store.reload(manager: fixture.manager)?.value
        let link = try #require(store.links.first); var options = link.options
        switch mode {
        case "keep": options.description = "Updated description"
        case "replace":
            options.description = "Updated description"; options.password = "synthetic replacement"; options.slug = "new-slug"
            options.expiresAt = try AlbumPublicLink.date("2027-01-01T00:00:00.000Z"); options.allowUpload = false
        default:
            options.description = nil; options.password = nil; options.slug = nil; options.expiresAt = nil
            options.showMetadata = false; options.allowDownload = false; options.allowUpload = false
        }
        let plan = try store.prepare(.update(link, options), manager: fixture.manager)
        await store.start(plan, manager: fixture.manager)?.value
        #expect(store.hasFreshData && store.links.count == 1 && store.notice != nil && fixture.manager.revision == 1)
        let requests = await fixture.script.requests(); try #require(requests.count == 7)
        try assertPublicBody(requests[4], expected: nextOptions, creating: false)
        #expect(requests.map(\.method) == ["GET", "GET", "GET", "GET", "PATCH", "GET", "GET"])
    }

    /// 撤销204后要求成功的fresh列表确实不含链接；列表仍含/失败不会当已撤销，照片与相簿无DELETE。
    @Test(arguments: ["absent", "present", "unavailable"])
    func revokesOnlyWithFreshAbsence(_ result: String) async throws {
        let baseline = try publicLinkJSON()
        var list = publicList(result == "present" ? "[\(baseline)]" : "[]")
        if result == "unavailable" {
            list = publicList("{}", status: 403)
        }
        let fixture = ChecksumLookupHTTPFixture(exchanges: publicReads(links: "[\(baseline)]") + [publicDetail(baseline),
                                                                                                  .init(method: "DELETE", path: "shared-links/\(publicLinkID)", status: 204, json: ""), list])
        defer { fixture.close() }
        let store = AlbumPublicLinkStore(); await store.reload(manager: fixture.manager)?.value
        let link = try #require(store.links.first); let plan = try store.prepare(.revoke(link), manager: fixture.manager)
        await store.start(plan, manager: fixture.manager)?.value
        #expect(fixture.manager.revision == 1 && !store.isWorking)
        #expect(store.hasFreshData == (result == "absent") && (store.notice != nil) == (result == "absent"))
        if result == "absent" {
            #expect(store.links.isEmpty && store.error == nil)
        } else {
            #expect(store.error != nil)
        }
        let requests = await fixture.script.requests()
        #expect(requests.count == 6 && requests.filter { $0.method == "DELETE" }.map(\.url.path) == ["/api/shared-links/\(publicLinkID)"])
    }

    /// viewer和未来未知角色不能创建；读取页面不自动写入，不能用可见相簿或旧owner标量替代真实权限。
    @Test(arguments: ["viewer", "future-role"])
    func neverCreatesFromReadOnlyAlbumRoles(_ role: String) async throws {
        let fixture = ChecksumLookupHTTPFixture(exchanges: publicReads(album: publicAlbumJSON(role: role)))
        defer { fixture.close() }
        let store = AlbumPublicLinkStore(); await store.reload(manager: fixture.manager)?.value
        #expect(store.hasFreshData)
        #expect(throws: AlbumPublicLinkError.self) { try store.prepare(.create(newPublicOptions()), manager: fixture.manager) }
        #expect(await fixture.script.requests().count == 3 && fixture.manager.revision == 0)
    }

    /// 确认后权限/链接改变就停止；创建还重读自己的已有列表以阻止另一窗口已经创建后的旧确认重放。
    @Test(arguments: ["album-role", "create-list", "update-options", "revoke-owner"])
    func changedPreflightCannotSendAWrite(_ scenario: String) async throws {
        let baseline = try publicLinkJSON(); let creating = ["album-role", "create-list"].contains(scenario)
        var reads = publicReads(links: creating ? "[]" : "[\(baseline)]")
        switch scenario {
        case "album-role": reads += [publicAlbumRead(publicAlbumJSON(role: "viewer"))]
        case "create-list": reads += [publicAlbumRead(publicAlbumJSON()), publicList("[\(baseline)]")]
        case "update-options": try reads += [publicDetail(publicLinkJSON(options: publicUpdatedOptions("clear")))]
        default: try reads += [publicDetail(publicLinkJSON(creator: publicOtherID))]
        }
        let fixture = ChecksumLookupHTTPFixture(exchanges: reads); defer { fixture.close() }
        let store = AlbumPublicLinkStore(); await store.reload(manager: fixture.manager)?.value
        let command: AlbumPublicLinkCommand
        if creating {
            command = .create(newPublicOptions())
        } else {
            let link = try #require(store.links.first)
            command = scenario == "revoke-owner" ? .revoke(link) : .update(link, link.options)
        }
        let plan = try store.prepare(command, manager: fixture.manager); await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.error != nil && store.notice == nil && fixture.manager.revision == 0)
        #expect(await fixture.script.requests().allSatisfy { $0.method == "GET" })
    }

    /// 错误成功码/服务错误/密码回执不符均锁定为未知，下一步只能显式重读，不能重发相同确认。
    @Test(arguments: ["create-200", "update-201", "revoke-200", "update-500", "update-mismatch"])
    func enforcesPreciseStatusAndReceiptWithoutRetry(_ scenario: String) async throws {
        let baseline = try publicLinkJSON(); let creating = scenario.hasPrefix("create"); let revoke = scenario.hasPrefix("revoke")
        var sequence = publicReads(links: creating ? "[]" : "[\(baseline)]")
        sequence += creating ? [publicAlbumRead(publicAlbumJSON()), publicList("[]")] : [publicDetail(baseline)]
        let status = try scenario == "update-mismatch" ? 200 : Int(#require(scenario.split(separator: "-").last))!
        try sequence += [.init(method: creating ? "POST" : revoke ? "DELETE" : "PATCH", path: creating ? "shared-links" : "shared-links/\(publicLinkID)",
                               status: status, json: revoke ? "" : publicLinkJSON(options: publicNewOptions, album: false))]
        let fixture = ChecksumLookupHTTPFixture(exchanges: sequence); defer { fixture.close() }
        let store = AlbumPublicLinkStore(); await store.reload(manager: fixture.manager)?.value
        let command: AlbumPublicLinkCommand
        if creating {
            command = .create(newPublicOptions())
        } else {
            let link = try #require(store.links.first); command = revoke ? .revoke(link) : .update(link, link.options)
        }
        let plan = try store.prepare(command, manager: fixture.manager); await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.notice == nil && store.error != nil && fixture.manager.revision == 1)
        #expect(store.start(plan, manager: fixture.manager) == nil)
        let requests = await fixture.script.requests(); #expect(requests.count == sequence.count && requests.filter { $0.method != "GET" }.count == 1)
    }

    /// POST/PATCH即使状态/选项正确，错误所属相簿/创建者/类型、缺详情或列表未收录都不能确认公开链接。
    @Test(arguments: ["wrong-album", "wrong-creator", "wrong-type", "missing-album", "changed-options", "list-missing"])
    func requiresFreshDetailAndListInsteadOfInferringAlbum(_ variant: String) async throws {
        let baseline = try publicLinkJSON(); let receipt = try publicLinkJSON(album: false)
        var detail = try publicLinkJSON()
        switch variant {
        case "wrong-album": detail = try publicLinkJSON(albumID: publicOtherID)
        case "wrong-creator": detail = try publicLinkJSON(creator: publicOtherID)
        case "wrong-type": detail = try publicLinkJSON(type: "INDIVIDUAL")
        case "missing-album": detail = receipt
        case "changed-options": detail = try publicLinkJSON(options: publicUpdatedOptions("clear"))
        default: break
        }
        let fixture = ChecksumLookupHTTPFixture(exchanges: publicReads(links: "[\(baseline)]") + [publicDetail(baseline),
                                                                                                  .init(method: "PATCH", path: "shared-links/\(publicLinkID)", status: 200, json: receipt), publicDetail(detail)]
                + (variant == "list-missing" ? [publicList("[]")] : []))
        defer { fixture.close() }
        let store = AlbumPublicLinkStore(); await store.reload(manager: fixture.manager)?.value
        let link = try #require(store.links.first); let plan = try store.prepare(.update(link, link.options), manager: fixture.manager)
        await store.start(plan, manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.notice == nil && store.error != nil && fixture.manager.revision == 1)
        #expect(store.copyURL(for: link, manager: fixture.manager) == nil)
    }

    /// nullable与日期/布尔字段必须真实存在；缺少不能默认为永久、无密码或允许下载，重复ID也拒绝整列表。
    @Test(arguments: ["missing-expiry", "invalid-expiry", "missing-password", "invalid-download", "duplicate"])
    func malformedListNeverEnablesWriting(_ variant: String) async throws {
        let bytes = try Data(publicLinkJSON().utf8)
        let decoded = try JSONSerialization.jsonObject(with: bytes)
        var object = try #require(decoded as? [String: Any])
        switch variant {
        case "missing-expiry": object.removeValue(forKey: "expiresAt")
        case "invalid-expiry": object["expiresAt"] = "not-a-date"
        case "missing-password": object.removeValue(forKey: "password")
        case "invalid-download": object["allowDownload"] = "true"
        default: break
        }
        let list = try String(decoding: JSONSerialization.data(withJSONObject: variant == "duplicate" ? [object, object] : [object]), as: UTF8.self)
        let fixture = ChecksumLookupHTTPFixture(exchanges: publicReads(links: list)); defer { fixture.close() }
        let store = AlbumPublicLinkStore(); await store.reload(manager: fixture.manager)?.value
        #expect(!store.hasFreshData && store.links.isEmpty && store.error != nil && fixture.manager.revision == 0)
    }

    /// 预检、写、详情、最终列表四个真实请求门分别取消/退页/换号/换端点，旧响应不可再写或发布成功。
    @Test(.timeLimit(.minutes(1)), arguments: [3, 4, 5, 6], ["cancel", "page", "account", "endpoint"])
    func retiresInflightRequestsWithoutReplaying(_ heldIndex: Int, _ retirement: String) async throws {
        let baseline = try publicLinkJSON()
        var sequence = try publicReads(links: "[\(baseline)]") + [publicDetail(baseline),
                                                                  .init(method: "PATCH", path: "shared-links/\(publicLinkID)", status: 200, json: publicLinkJSON(album: false)), publicDetail(baseline), publicList("[\(baseline)]")]
        sequence[heldIndex].held = true
        let fixture = ChecksumLookupHTTPFixture(exchanges: sequence)
        defer { fixture.close() }
        let store = AlbumPublicLinkStore(); await store.reload(manager: fixture.manager)?.value
        let link = try #require(store.links.first); let plan = try store.prepare(.update(link, link.options), manager: fixture.manager)
        let task = try #require(store.start(plan, manager: fixture.manager))
        let observer = Task { await task.value; await fixture.script.operationFinished() }
        do {
            try await withTaskCancellationHandler {
                try #require(await fixture.script.waitForHeld(), "Actual public-link request must enter its gate")
                switch retirement {
                case "cancel": task.cancel()
                case "page": store.invalidate(manager: fixture.manager)
                case "account":
                    fixture.manager.configure(session: checksumLookupSession(endpoint: fixture.endpoint, user: publicOtherID, token: "other"), endpoint: fixture.endpoint)
                    store.invalidate(manager: fixture.manager)
                default:
                    fixture.manager.configure(session: checksumLookupSession(endpoint: fixture.endpoint), endpoint: fixture.endpoint.appending(path: "new-route"))
                    store.invalidate(manager: fixture.manager)
                }
                await fixture.script.release(); await task.value; await fixture.script.waitForHeldResponderExit()
                #expect(!store.hasFreshData && store.notice == nil && !store.isWorking && store.copyURL(for: link, manager: fixture.manager) == nil)
                #expect(fixture.manager.revision == (["cancel", "page"].contains(retirement) && heldIndex >= 4 ? 1 : 0))
                #expect(await fixture.script.requests().count == heldIndex + 1)
            } onCancel: { Task { @MainActor in store.invalidate(manager: fixture.manager); await fixture.script.stop() } }
        } catch {
            store.invalidate(manager: fixture.manager); await fixture.script.stop(); await task.value; await observer.value; throw error
        }
        await observer.value; await fixture.script.stop()
    }

    /// 地址仅由主动复制入口获得且保留代理前缀/安全组件编码；换账号即使旧View尚存在也不能复制旧密钥。
    @Test(arguments: ["none", "simple", "encoded", "dot"])
    func copyingUsesOnlyCurrentFreshAssociation(_ mode: String) async throws {
        let options = switch mode {
        case "none": publicUpdatedOptions("clear")
        case "encoded": publicOldOptions.replacingOccurrences(of: "old-slug", with: "encoded/name?#space x")
        case "dot": publicOldOptions.replacingOccurrences(of: "old-slug", with: "..")
        default: publicOldOptions
        }
        let baseline = try publicLinkJSON(options: options)
        let fixture = ChecksumLookupHTTPFixture(exchanges: publicReads(links: "[\(baseline)]")); defer { fixture.close() }
        let store = AlbumPublicLinkStore(); await store.reload(manager: fixture.manager)?.value
        let link = try #require(store.links.first)
        if mode == "dot" {
            #expect(store.copyURL(for: link, manager: fixture.manager) == nil)
            return
        }
        let url = try #require(store.copyURL(for: link, manager: fixture.manager))
        if mode == "encoded" {
            #expect(url.absoluteString.hasSuffix("/s/encoded%2Fname%3F%23space%20x"))
            #expect(url.query == nil && url.fragment == nil)
        } else {
            #expect(url == fixture.endpoint.deletingLastPathComponent().appending(path: mode == "none" ? "share" : "s")
                .appending(component: mode == "none" ? "synthetic_key" : "old-slug"))
        }
        let prefixed = try #require(URL(string: "https://public.example.invalid/prefix/api"))
        #expect(link.copyURL(apiURL: prefixed)?.path.hasPrefix("/prefix/") == true)
        fixture.manager.configure(session: checksumLookupSession(endpoint: fixture.endpoint, user: publicOtherID), endpoint: fixture.endpoint)
        #expect(store.copyURL(for: link, manager: fixture.manager) == nil)
        #expect(await fixture.script.requests().count == 3)
    }
}

private nonisolated let publicAlbumID = "44444444-4444-4444-8444-444444444444"
private nonisolated let publicLinkID = "22222222-2222-4222-8222-222222222222"
private nonisolated let publicCurrentID = "99999999-9999-4999-8999-999999999999"
private nonisolated let publicOtherID = "33333333-3333-4333-8333-333333333333"
/// 所有响应中的密码/slug/密钥仅为固定合成值，不来自用户或实际服务。
private nonisolated let publicOldOptions = #"{"description":"Baseline","password":"synthetic original","slug":"old-slug","expiresAt":null,"allowUpload":true,"allowDownload":true,"showMetadata":true}"#
private nonisolated let publicNewOptions = #"{"description":"New link","password":null,"slug":null,"expiresAt":null,"allowUpload":false,"allowDownload":false,"showMetadata":false}"#

/// 创建输入故意含allowDownload=true/showMetadata=false，服务规范化后预期明确为false，与官方Web一致。
private nonisolated func newPublicOptions() -> AlbumPublicLinkOptions {
    .init(description: "New link", password: nil, slug: nil, expiresAt: nil, allowUpload: false, allowDownload: true, showMetadata: false)
}

/// mode是独立声明的保留/替换/清除回执选项，不调用生产编码器生成预期body。
private nonisolated func publicUpdatedOptions(_ mode: String) -> String {
    switch mode {
    case "keep": #"{"description":"Updated description","password":"synthetic original","slug":"old-slug","expiresAt":null,"allowUpload":true,"allowDownload":true,"showMetadata":true}"#
    case "replace": #"{"description":"Updated description","password":"synthetic replacement","slug":"new-slug","expiresAt":"2027-01-01T00:00:00.000Z","allowUpload":false,"allowDownload":true,"showMetadata":true}"#
    default: #"{"description":null,"password":null,"slug":null,"expiresAt":null,"allowUpload":false,"allowDownload":false,"showMetadata":false}"#
    }
}

/// role为当前用户真实相簿角色；首owner是其他用户，避免错误只按原始owner标量开放创建。
private nonisolated func publicAlbumJSON(role: String = "editor") -> String {
    #"{"id":"\#(publicAlbumID)","albumName":"Synthetic public album","albumUsers":[{"user":{"id":"\#(publicOtherID)","name":"First owner"},"role":"owner"},{"user":{"id":"\#(publicCurrentID)","name":"Current"},"role":"\#(role)"}]}"#
}

/// options是独立JSON字段；album=false模拟真实POST/PATCH未join相簿的回执，不让请求值补造身份。
private nonisolated func publicLinkJSON(options: String = publicOldOptions, album: Bool = true,
                                        albumID: String = publicAlbumID, creator: String = publicCurrentID, type: String = "ALBUM") throws -> String
{
    let decoded = try JSONSerialization.jsonObject(with: Data(options.utf8))
    var object = try #require(decoded as? [String: Any])
    object["id"] = publicLinkID; object["userId"] = creator; object["key"] = "synthetic_key"; object["type"] = type
    object["createdAt"] = "2026-11-25T00:00:00.000Z"; object["assets"] = []
    if album {
        object["album"] = ["id": albumID, "albumName": "Synthetic public album"]
    }
    return try String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

/// album/links为完整固定响应，返回列表→相簿详情→本人链接三次真实HTTP读取。
private nonisolated func publicReads(album: String = publicAlbumJSON(), links: String = "[]") -> [ChecksumLookupExchange] {
    [.init(method: "GET", path: "albums", status: 200, json: "[\(album)]"), publicAlbumRead(album), publicList(links)]
}

/// json是当前相簿详情；只模拟公开GET200，权限仍由真实共享模型判断。
private nonisolated func publicAlbumRead(_ json: String) -> ChecksumLookupExchange {
    .init(method: "GET", path: "albums/\(publicAlbumID)", status: 200, json: json)
}

/// json/status为本人链接列表响应；精确断言官方albumId query，而不是把过滤条件编码成路径。
private nonisolated func publicList(_ json: String, status: Int = 200) -> ChecksumLookupExchange {
    .init(method: "GET", path: "shared-links", status: status, json: json, query: [.init(name: "albumId", value: publicAlbumID)])
}

/// json为单链接详情，固定真实UUID路径；不使用公开key认证或密码登录API。
private nonisolated func publicDetail(_ json: String) -> ChecksumLookupExchange {
    .init(method: "GET", path: "shared-links/\(publicLinkID)", status: 200, json: json)
}

/// request为客户端实际序列化正文；expected独立JSON须逐字段相等且无隐含省略，creating只允许额外type/albumId。
private nonisolated func assertPublicBody(_ request: ChecksumLookupRequest, expected: String, creating: Bool) throws {
    let bytes = try #require(request.body)
    let actualValue = try JSONSerialization.jsonObject(with: bytes)
    let expectedValue = try JSONSerialization.jsonObject(with: Data(expected.utf8))
    let actual = try #require(actualValue as? [String: Any]); var planned = try #require(expectedValue as? [String: Any])
    if creating {
        planned["type"] = "ALBUM"; planned["albumId"] = publicAlbumID
    }
    #expect(NSDictionary(dictionary: actual).isEqual(to: planned))
    #expect(actual.count == (creating ? 9 : 7) && request.authorization == "Bearer checksum-owner")
}
