import CryptoKit
import Foundation

/// 显式管理通道的安全错误；目录名称校验和HTTP/账号状态保留独立语义，不自动重试写请求。
nonisolated enum LibraryWriteError: LocalizedError {
    case invalidID, unavailable, changedAccount, busy, malformedResponse, trashedDuplicate, invalidPresetName, invalidDirectoryName
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidID: "无效的资源标识。"
        case .unavailable: "请先连接服务器。"
        case .changedAccount: "账户或连接已变更，请重新操作。"
        case .busy: "请等待当前操作完成。"
        case .malformedResponse: "服务器返回的数据不符合约定，未确认操作成功。"
        case .trashedDuplicate: "服务器回收站中已有此文件，请先决定是否恢复；未标记为备份成功。"
        case .invalidPresetName: "Enter a saved search name of 1 to 100 characters."
        case .invalidDirectoryName: "Enter a category name of 1 to 100 characters. The default category is reserved."
        case let .http(code): "服务器返回 HTTP \(code)。请检查权限、版本和连接；不自动重试写操作。"
        }
    }
}

/// 显式管理通道读取的资源快照；可选版本/方向信息供编辑页核对，不从预览像素猜测原图状态。
nonisolated struct ManagedAsset: Decodable, Sendable {
    let id: String
    let ownerId: String
    let isFavorite: Bool
    let visibility: String
    let isTrashed: Bool
    let type: String
    let originalFileName: String
    let livePhotoVideoId: String?
    let exifInfo: Exif?
    let projectionType: String?
    let updatedAt: String?
    let checksum: String?

    /// 原始EXIF尺寸和方向，缺字段保持nil；旋转后的编辑坐标由领域层按服务端规则计算。
    struct Exif: Decodable, Sendable {
        let description: String?
        let exifImageWidth: Int?
        let exifImageHeight: Int?
        let orientation: String?

        /// description为文字描述，宽高单位为像素；orientation为服务端原始方向字符串，缺省不猜测。
        init(description: String?, exifImageWidth: Int?, exifImageHeight: Int?, orientation: String? = nil) {
            self.description = description
            self.exifImageWidth = exifImageWidth
            self.exifImageHeight = exifImageHeight
            self.orientation = orientation
        }
    }

    /// id/ownerId为资源与拥有者身份，收藏/可见性/回收站值来自服务器；type/filename/livePhoto关联保持原值。
    /// exifInfo为可选原始信息；projectionType/updatedAt/checksum缺省nil以兼容旧构造，存在时仍由Decodable真实解码。
    init(id: String, ownerId: String, isFavorite: Bool, visibility: String, isTrashed: Bool, type: String,
         originalFileName: String, livePhotoVideoId: String?, exifInfo: Exif?,
         projectionType: String? = nil, updatedAt: String? = nil, checksum: String? = nil)
    {
        self.id = id
        self.ownerId = ownerId
        self.isFavorite = isFavorite
        self.visibility = visibility
        self.isTrashed = isTrashed
        self.type = type
        self.originalFileName = originalFileName
        self.livePhotoVideoId = livePhotoVideoId
        self.exifInfo = exifInfo
        self.projectionType = projectionType
        self.updatedAt = updatedAt
        self.checksum = checksum
    }
}

nonisolated struct ManagedAlbum: Decodable, Identifiable, Sendable {
    let id: String
    let albumName: String
    let ownerId: String
}

nonisolated struct AssetEditList: Codable, Sendable {
    var edits: [Edit]

    struct Edit: Codable, Sendable, Equatable {
        let action: String
        let parameters: Parameters
    }

    struct Parameters: Codable, Sendable, Equatable {
        var x: Int? = nil
        var y: Int? = nil
        var width: Int? = nil
        var height: Int? = nil
        var angle: Int? = nil
        var axis: String? = nil
    }
}

/// 独立写入通道只暴露明确的官方操作；浏览 SDK 的只读保护继续保留。
final nonisolated class LibraryMutationClient: Sendable {
    let apiURL: URL
    let userID: String
    private let token: String
    private let session: URLSession

    final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }

    init(apiURL: URL, token: String, userID: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.apiURL = apiURL
        self.token = token
        self.userID = userID
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    func cancel() {
        session.invalidateAndCancel()
    }

    /// id为元数据或本机checksum找到的候选；真实GET200状态用于校验账号、版本、offline/trash和服务端编辑。
    /// 只读取资产信息，不下载照片/视频，不将候选直接视为已匹配或已备份。
    func localMediaAsset(_ id: String) async throws -> LocalMediaRemoteAsset {
        let expected = try validID(id)
        let data = try await send("GET", ["assets", expected], expectedStatus: 200)
        let asset = try JSONDecoder().decode(LocalMediaRemoteAsset.self, from: data)
        guard asset.id == UUID(uuidString: expected) else { throw LibraryWriteError.malformedResponse }
        return asset
    }

    /// queries为最多64个不重复nonce的本机完整字节摘要；官方precheck只查现有资源，accept仅返回未命中，绝不上传。
    /// 精确200、逐ID唯一回执及duplicate/isTrashed必须完整；结果仍须调用方fresh owner/版本/编辑状态验证。
    @concurrent func lookupLocalMediaChecksums(_ queries: [LocalMediaChecksumQuery]) async throws -> [LocalMediaChecksumLookup] {
        guard queries.count <= LocalMediaChecksumQuery.batchLimit,
              Set(queries.map(\.id)).count == queries.count else { throw LocalPhotoChecksumError.invalidInput }
        guard !queries.isEmpty else { return [] }
        // id仅本次nonce，checksum固定十六进制SHA1；不附带文件、Photos标识、metadata或上传参数。
        struct Body: Encodable { let assets: [Item]; struct Item: Encodable { let id: String; let checksum: String } }
        // presence区分省略与null，accept不能带冲突duplicate字段，reject不能缺失isTrashed。
        struct Item: Decodable {
            let id: String
            let action: String
            let reason: String?
            let assetId: String?
            let isTrashed: Bool?
            let hasReason: Bool
            let hasAssetID: Bool
            let hasTrash: Bool
            private enum CodingKeys: String, CodingKey { case id, action, reason, assetId, isTrashed }

            /// decoder是实际单条回执；错误类型拒绝，不把null/缺失默认为false或未命中。
            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id); action = try values.decode(String.self, forKey: .action)
                reason = try values.decodeIfPresent(String.self, forKey: .reason); assetId = try values.decodeIfPresent(String.self, forKey: .assetId)
                isTrashed = try values.decodeIfPresent(Bool.self, forKey: .isTrashed)
                hasReason = values.contains(.reason); hasAssetID = values.contains(.assetId); hasTrash = values.contains(.isTrashed)
            }
        }
        // 官方根对象；不能用其他数组或空响应冒充所有资源未命中。
        struct Response: Decodable { let results: [Item] }
        let body = Body(assets: queries.map { .init(id: $0.id.uuidString.lowercased(), checksum: $0.digest.sha1Hex) })
        let data = try await send("POST", ["assets", "bulk-upload-check"], body: JSONEncoder().encode(body), expectedStatus: 200)
        guard data.count <= 262_144 else { throw LibraryWriteError.malformedResponse }
        let results = try JSONDecoder().decode(Response.self, from: data).results
        let expected = Set(queries.map { $0.id.uuidString.lowercased() })
        guard results.count == queries.count, Set(results.map(\.id)) == expected else { throw LibraryWriteError.malformedResponse }
        var mapped: [String: LocalMediaChecksumLookup.Outcome] = [:]
        for result in results {
            guard mapped[result.id] == nil else { throw LibraryWriteError.malformedResponse }
            switch result.action {
            case "accept":
                guard !result.hasReason, !result.hasAssetID, !result.hasTrash else { throw LibraryWriteError.malformedResponse }
                mapped[result.id] = .noMatch
            case "reject":
                guard result.reason == "duplicate", let id = result.assetId, let assetID = UUID(uuidString: id),
                      assetID.uuid.6 >> 4 == 4, assetID.uuid.8 & 0xC0 == 0x80,
                      let trashed = result.isTrashed else { throw LibraryWriteError.malformedResponse }
                mapped[result.id] = trashed ? .trashed(assetID) : .existing(assetID)
            default: throw LibraryWriteError.malformedResponse
            }
        }
        try Task.checkCancellation()
        return try queries.map { query in
            guard let outcome = mapped[query.id.uuidString.lowercased()] else { throw LibraryWriteError.malformedResponse }
            return .init(id: query.id, outcome: outcome)
        }
    }

    /// cloudIDs为本机已读到的完整Photos标识；只读取官方同步元数据，不请求任何媒体、不reset也不提交ack。
    /// 返回完整流中的未验证候选；现有metadata检查点、SyncReset、HTTP/协议失败均抛错，不返回部分结果。
    @concurrent func localMediaMetadata(cloudIDs: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord] {
        guard !cloudIDs.isEmpty else { return [] }
        var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: cloudIDs)
        let acknowledgements = try await send("GET", ["sync", "ack"], expectedStatus: 200)
        try LocalMediaMetadataStreamDecoder.requireFullMetadataSnapshot(acknowledgements)
        struct Body: Encodable { let types: [String] }
        var streamRequest = try request("POST", ["sync", "stream"])
        streamRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        streamRequest.setValue("application/jsonlines+json", forHTTPHeaderField: "Accept")
        streamRequest.httpBody = try JSONEncoder().encode(Body(types: ["AssetMetadataV1"]))
        let (bytes, response) = try await session.bytes(for: streamRequest)
        guard let response = response as? HTTPURLResponse else { throw LocalMediaMetadataStreamError.invalidResponse }
        guard response.statusCode == 200 else { throw LibraryWriteError.http(response.statusCode) }
        guard response.mimeType?.lowercased() == "application/jsonlines+json" else { throw LocalMediaMetadataStreamError.invalidResponse }
        var untilCancellationCheck = 65536
        for try await byte in bytes {
            try decoder.append(byte)
            untilCancellationCheck -= 1
            if untilCancellationCheck == 0 {
                try Task.checkCancellation()
                untilCancellationCheck = 65536
            }
        }
        try Task.checkCancellation()
        return try decoder.finish()
    }

    private func validID(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw LibraryWriteError.invalidID }
        return value
    }

    private func request(_ method: String, _ components: [String]) throws -> URLRequest {
        try Task.checkCancellation()
        guard ["https", "http"].contains(apiURL.scheme), apiURL.host != nil,
              apiURL.user == nil, apiURL.password == nil, apiURL.query == nil, apiURL.fragment == nil,
              !token.contains("\r"), !token.contains("\n") else { throw LibraryWriteError.unavailable }
        var request = URLRequest(url: components.reduce(apiURL) { $0.appendingPathComponent($1) })
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func checked(_ data: Data, _ response: URLResponse) throws -> Data {
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw LibraryWriteError.malformedResponse }
        guard (200 ..< 300).contains(response.statusCode) else { throw LibraryWriteError.http(response.statusCode) }
        return data
    }

    /// method/path为固定操作，body为可选JSON，query为查询参数；expectedStatus可要求契约的精确状态码。
    /// 返回响应字节；HTTP失败、取消或状态不匹配均拒绝，旧操作未指定状态时保持原行为。
    private func send(_ method: String, _ path: [String], body: Data? = nil, query: [URLQueryItem] = [], expectedStatus: Int? = nil) async throws -> Data {
        var request = try request(method, path)
        if !query.isEmpty {
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = query
            request.url = components.url
        }
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let result = try checked(data, response)
        if let expectedStatus, (response as? HTTPURLResponse)?.statusCode != expectedStatus {
            throw LibraryWriteError.malformedResponse
        }
        return result
    }

    /// 读取当前账号登记；只有明确缺少扩展的404/405/501返回nil，鉴权和网络错误继续抛出。
    func searchPresets() async throws -> [NativeSearchPreset]? {
        do {
            let data = try await send("GET", ["fork", "search-presets"], expectedStatus: 200)
            return try JSONDecoder().decode([NativeSearchPreset].self, from: data)
        } catch let LibraryWriteError.http(status) where [404, 405, 501].contains(status) {
            return nil
        }
    }

    /// name/conditions为新登记的完整内容；仅201与有效对象确认成功，不自动重放POST。
    func createSearchPreset(name: String, conditions: NativeSearchPresetConditions) async throws -> NativeSearchPreset {
        let body = try presetBody(name: name, conditions: conditions)
        let data = try await send("POST", ["fork", "search-presets"], body: body, expectedStatus: 201)
        return try JSONDecoder().decode(NativeSearchPreset.self, from: data)
    }

    /// id为当前账号的登记UUID；发送完整name/conditions，重名409与跨账号404由服务端裁决。
    func updateSearchPreset(_ id: String, name: String, conditions: NativeSearchPresetConditions) async throws -> NativeSearchPreset {
        let body = try presetBody(name: name, conditions: conditions)
        let data = try await send("PATCH", ["fork", "search-presets", validID(id)], body: body, expectedStatus: 200)
        return try JSONDecoder().decode(NativeSearchPreset.self, from: data)
    }

    /// id为待删除登记UUID；只接受204，不删除任何照片或相簿。
    func deleteSearchPreset(_ id: String) async throws {
        _ = try await send("DELETE", ["fork", "search-presets", validID(id)], expectedStatus: 204)
    }

    /// name去除首尾空白后按服务器UTF16长度校验；conditions原样编码，不能丢弃null/已知字段。
    private func presetBody(name: String, conditions: NativeSearchPresetConditions) throws -> Data {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 100).contains(name.utf16.count) else { throw LibraryWriteError.invalidPresetName }
        struct Body: Encodable { let name: String; let conditions: NativeSearchPresetConditions }
        return try JSONEncoder().encode(Body(name: name, conditions: conditions))
    }

    /// 每次真实读取当前账号目录；仅该可选GET的404/405/501表示扩展未安装，鉴权失败继续抛出。
    func albumDirectoryState() async throws -> ForkAlbumDirectory.State? {
        do {
            let data = try await send("GET", ["fork", "album-categories"], expectedStatus: 200)
            let result = try JSONDecoder().decode(ForkAlbumDirectory.State.self, from: data)
            let ids = result.categories.map(\.id)
            guard Set(ids).count == ids.count, ids.allSatisfy({ UUID(uuidString: $0) != nil }),
                  Set(result.groups.map(\.groupName)).count == result.groups.count,
                  result.groups.allSatisfy({ ids.contains($0.categoryId) }) else { throw LibraryWriteError.malformedResponse }
            return result
        } catch let LibraryWriteError.http(status) where [404, 405, 501].contains(status) {
            return nil
        }
    }

    /// 真实读取所有可见相簿的目录字段；不复用持久索引GET缓存，缺少分组字段仍可兼容解码。
    func directoryAlbums() async throws -> [ManagedDirectoryAlbum] {
        let data = try await send("GET", ["albums"], expectedStatus: 200)
        let result = try JSONDecoder().decode([ManagedDirectoryAlbum].self, from: data)
        guard Set(result.map(\.id)).count == result.count,
              result.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw LibraryWriteError.malformedResponse }
        return result
    }

    /// name按Fork规则trim/校验；只有201和匹配名称、有效UUID的大组确认创建，不自动重放POST。
    func createAlbumCategory(name: String) async throws -> ForkAlbumDirectory.Category {
        let (title, body) = try albumCategoryBody(name)
        let data = try await send("POST", ["fork", "album-categories"], body: body, expectedStatus: 201)
        let result = try JSONDecoder().decode(ForkAlbumDirectory.Category.self, from: data)
        guard UUID(uuidString: result.id) != nil, result.name == title else { throw LibraryWriteError.malformedResponse }
        return result
    }

    /// id为自有真实大组UUID，name为新名；200、相同ID及匹配名称共同确认，重名409由服务端裁决。
    func renameAlbumCategory(_ id: String, name: String) async throws -> ForkAlbumDirectory.Category {
        let id = try validID(id)
        let (title, body) = try albumCategoryBody(name)
        let data = try await send("PATCH", ["fork", "album-categories", id], body: body, expectedStatus: 200)
        let result = try JSONDecoder().decode(ForkAlbumDirectory.Category.self, from: data)
        guard result.id.lowercased() == id.lowercased(), result.name == title else { throw LibraryWriteError.malformedResponse }
        return result
    }

    /// id为自有大组UUID；仅204确认，服务端级联移除个人映射，分组回默认且不删除相簿/照片。
    func deleteAlbumCategory(_ id: String) async throws {
        _ = try await send("DELETE", ["fork", "album-categories", validID(id)], expectedStatus: 204)
    }

    /// groupName为当前账号可见分组，空串代表未分组；categoryID为自有大组或nil回默认，必须显式编码null。
    func assignAlbumGroup(_ groupName: String, categoryID: String?) async throws {
        let category = try categoryID.map(validID)
        var body: [String: Any] = ["groupName": groupName.trimmingCharacters(in: .whitespacesAndNewlines)]
        body["categoryId"] = category.map { $0 as Any } ?? NSNull()
        _ = try await send("PUT", ["fork", "album-categories", "group"],
                           body: JSONSerialization.data(withJSONObject: body), expectedStatus: 204)
    }

    /// id为相簿UUID，groupName为目标分组；nil/空白显式写null，只有200和ID/字段回执一致才确认。
    /// 此字段属于相簿本身，其他有权限客户端可见；权限检查保留服务端album.update语义。
    func setAlbumGroup(_ id: String, groupName: String?) async throws -> ManagedDirectoryAlbum {
        let id = try validID(id)
        let name = groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: [String: Any] = ["customGroupName": name.isEmpty ? NSNull() : name as Any]
        let data = try await send("PATCH", ["albums", id], body: JSONSerialization.data(withJSONObject: body), expectedStatus: 200)
        let result = try JSONDecoder().decode(ManagedDirectoryAlbum.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard result.id.lowercased() == id.lowercased(), result.groupName == name,
              object?.keys.contains("customGroupName") == true else { throw LibraryWriteError.malformedResponse }
        return result
    }

    /// name为用户输入；返回trim名称及唯一name字段的JSON，禁止把虚拟默认名称持久化为实体。
    private func albumCategoryBody(_ name: String) throws -> (String, Data) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 100).contains(title.utf16.count), title != "默认" else { throw LibraryWriteError.invalidDirectoryName }
        // 大组命令只允许发送名称字段，不混入客户端状态或其他相簿属性。
        struct Body: Encodable { let name: String }
        return try (title, JSONEncoder().encode(Body(name: title)))
    }

    /// id为当前管理资源；每次真实GET200并核对响应身份，元数据DTO不复用编辑/备份解码字段。
    func assetMetadata(_ id: String) async throws -> AssetMetadataSnapshot {
        let id = try validID(id)
        let data = try await send("GET", ["assets", id], expectedStatus: 200)
        let result = try JSONDecoder().decode(AssetMetadataSnapshot.self, from: data)
        guard result.id.lowercased() == id.lowercased() else { throw LibraryWriteError.malformedResponse }
        return result
    }

    /// id为已预检资源，patch只编码明确set/clear字段；精确200、同ID/owner和实际字段回执共同确认。
    /// 不发送Live Photo关联/描述/可见性等其他属性，不重试；服务端继续执行权限与EXIF锁定/sidecar规则。
    func updateAssetMetadata(_ id: String, patch: AssetMetadataPatch) async throws -> AssetMetadataSnapshot {
        let id = try validID(id)
        let body = try JSONEncoder().encode(patch)
        let data = try await send("PUT", ["assets", id], body: body, expectedStatus: 200)
        let result = try JSONDecoder().decode(AssetMetadataSnapshot.self, from: data)
        guard result.id.lowercased() == id.lowercased(), result.ownerId.lowercased() == userID.lowercased(),
              !result.isTrashed, patch.isConfirmed(by: result) else { throw LibraryWriteError.malformedResponse }
        return result
    }

    func asset(_ id: String) async throws -> ManagedAsset {
        try await JSONDecoder().decode(ManagedAsset.self, from: send("GET", ["assets", validID(id)]))
    }

    /// id/ownerID固定查看器已选静态照片；用既有无重定向鉴权会话直读，4秒超时且只接受匹配身份的200。
    /// 返回真实显示字段，不走索引缓存/后台GET队列，也不把响应当作编辑派生完成通知。
    func freshViewerAsset(_ id: String, ownerID: String) async throws -> AssetViewerFreshAsset {
        var request = try request("GET", ["assets", validID(id)])
        request.timeoutInterval = 4
        let (data, response) = try await session.data(for: request)
        let bytes = try checked(data, response)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LibraryWriteError.malformedResponse }
        let value = try JSONDecoder().decode(AssetViewerFreshAsset.self, from: bytes)
        guard UUID(uuidString: value.id) == UUID(uuidString: id), value.ownerId == ownerID,
              value.type == "IMAGE", value.livePhotoVideoId == nil else { throw LibraryWriteError.malformedResponse }
        _ = try value.revision()
        return value
    }

    func albums(containing assetID: String? = nil) async throws -> [ManagedAlbum] {
        let query = try assetID.map { try [URLQueryItem(name: "assetId", value: validID($0))] } ?? []
        return try await JSONDecoder().decode([ManagedAlbum].self, from: send("GET", ["albums"], query: query))
    }

    /// 真实读取所有可见相簿及完整有序成员；不要求不存在的ownerId，也不将缺成员降成空列表。
    func sharingAlbums() async throws -> [AlbumSharingSnapshot] {
        let values = try await JSONDecoder().decode([AlbumSharingSnapshot].self, from: send("GET", ["albums"], expectedStatus: 200))
        for value in values {
            try value.validate()
        }
        guard Set(values.map { $0.id.lowercased() }).count == values.count else { throw LibraryWriteError.malformedResponse }
        return values
    }

    /// id为当前明确选择的相簿；强制fresh200与匹配UUID，不复用列表或索引缓存做写前预检。
    func sharingAlbum(_ id: String) async throws -> AlbumSharingSnapshot {
        let id = try validID(id)
        let value = try await JSONDecoder().decode(AlbumSharingSnapshot.self, from: send("GET", ["albums", id], expectedStatus: 200))
        try value.validate()
        guard value.id.lowercased() == id.lowercased() else { throw LibraryWriteError.malformedResponse }
        return value
    }

    /// 只读取现有服务器账户供选择；不按email发邀请，不猜不可见账户，也不暴露管理用户API。
    func sharingUsers() async throws -> [AlbumSharingUser] {
        let values = try await JSONDecoder().decode([AlbumSharingUser].self, from: send("GET", ["users"], expectedStatus: 200))
        guard values.allSatisfy({ UUID(uuidString: $0.id) != nil }), Set(values.map { $0.id.lowercased() }).count == values.count else {
            throw LibraryWriteError.malformedResponse
        }
        return values
    }

    /// 仅提交一个明确成员，沿官方PUT200/角色PUT204/DELETE204；无重试、无owner提升或批量部分写推断。
    func changeAlbumSharing(_ command: AlbumSharingCommand, albumID: String) async throws {
        let albumID = try validID(albumID); let userID = try validID(command.userID)
        switch command {
        case let .add(_, role):
            struct Body: Encodable { struct Member: Encodable { let userId: String; let role: String }; let albumUsers: [Member] }
            let data = try await send("PUT", ["albums", albumID, "users"], body: JSONEncoder().encode(Body(albumUsers: [.init(userId: userID, role: role.rawValue)])), expectedStatus: 200)
            let value = try JSONDecoder().decode(AlbumSharingSnapshot.self, from: data)
            try value.validate()
            guard value.id.lowercased() == albumID.lowercased() else { throw LibraryWriteError.malformedResponse }
        case let .role(_, role):
            struct Body: Encodable { let role: String }
            _ = try await send("PUT", ["albums", albumID, "user", userID], body: JSONEncoder().encode(Body(role: role.rawValue)), expectedStatus: 204)
        case .remove:
            _ = try await send("DELETE", ["albums", albumID, "user", userID], expectedStatus: 204)
        }
    }

    /// id为当前查看照片；精确200、匹配的assetId及可完整保留的编辑文档才允许进入编辑器。
    func edits(_ id: String) async throws -> AssetEditList {
        let id = try validID(id)
        let data = try await send("GET", ["assets", id, "edits"], expectedStatus: 200)
        let receipt = try JSONDecoder().decode(AssetEditReceipt.self, from: data)
        guard receipt.assetID == UUID(uuidString: id) else { throw LibraryWriteError.malformedResponse }
        return receipt.document
    }

    /// id为目标资源，三个可选字段只发送指定项；仅精确200确认完成，不自动重试不确定写入。
    func update(_ id: String, favorite: Bool? = nil, visibility: String? = nil, description: String? = nil) async throws {
        struct Update: Encodable { let isFavorite: Bool?; let visibility: String?; let description: String? }
        let body = try JSONEncoder().encode(Update(isFavorite: favorite, visibility: visibility, description: description))
        _ = try await send("PUT", ["assets", validID(id)], body: body, expectedStatus: 200)
    }

    /// id为单个资源；force固定false，只移入回收站，精确204才确认。
    func trash(_ id: String) async throws {
        struct Body: Encodable { let ids: [String]; let force = false }
        _ = try await send("DELETE", ["assets"], body: JSONEncoder().encode(Body(ids: [validID(id)])), expectedStatus: 204)
    }

    /// id为单个回收站资源；精确200且实际恢复计数为1才确认，零计数需重读状态而非盲目重发。
    func restore(_ id: String) async throws {
        struct Body: Encodable { let ids: [String] }
        struct Result: Decodable { let count: Int }
        let data = try await send("POST", ["trash", "restore", "assets"], body: JSONEncoder().encode(Body(ids: [validID(id)])), expectedStatus: 200)
        guard let result = try? JSONDecoder().decode(Result.self, from: data), result.count == 1 else {
            throw LibraryWriteError.malformedResponse
        }
    }

    /// id为原资源、edits为完整官方编辑列表；200确认参数保存，不覆盖原始文件。
    func saveEdits(_ id: String, _ edits: AssetEditList) async throws {
        _ = try await send("PUT", ["assets", validID(id), "edits"], body: JSONEncoder().encode(edits), expectedStatus: 200)
    }

    /// id为需恢复原始显示的资源；只删除编辑参数，精确204才确认。
    func resetEdits(_ id: String) async throws {
        _ = try await send("DELETE", ["assets", validID(id), "edits"], expectedStatus: 204)
    }

    func createAlbum(name: String, assetID: String? = nil) async throws -> ManagedAlbum {
        struct Body: Encodable { let albumName: String; let assetIds: [String] }
        let body = try JSONEncoder().encode(Body(albumName: name, assetIds: assetID.map { try [validID($0)] } ?? []))
        return try await JSONDecoder().decode(ManagedAlbum.self, from: send("POST", ["albums"], body: body))
    }

    /// id/name为目标相簿与新名；使用官方PATCH及精确200，不以不存在的PUT路由写入。
    func renameAlbum(_ id: String, name: String) async throws {
        struct Body: Encodable { let albumName: String }
        _ = try await send("PATCH", ["albums", validID(id)], body: JSONEncoder().encode(Body(albumName: name)), expectedStatus: 200)
    }

    /// albumID为目标相簿，assetID为候选成员；服务端最终检查写权限与成员资格，只发送封面字段。
    /// 返回服务端确认相簿；身份或状态码不符一律失败，不自动重发。
    func setAlbumCover(_ albumID: String, assetID: String) async throws -> ManagedAlbum {
        struct Body: Encodable { let albumThumbnailAssetId: String }
        let id = try validID(albumID)
        let body = try JSONEncoder().encode(Body(albumThumbnailAssetId: validID(assetID)))
        let data = try await send("PATCH", ["albums", id], body: body, expectedStatus: 200)
        let result = try JSONDecoder().decode(ManagedAlbum.self, from: data)
        guard result.id.lowercased() == id.lowercased() else { throw LibraryWriteError.malformedResponse }
        return result
    }

    /// id为相簿身份；只删除相簿保留照片，精确204才确认。
    func deleteAlbum(_ id: String) async throws {
        _ = try await send("DELETE", ["albums", validID(id)], expectedStatus: 204)
    }

    /// assetID为需移出成员、albumID为相簿；200和唯一匹配ID的success=true共同确认，不删除照片。
    func remove(_ assetID: String, from albumID: String) async throws {
        struct Body: Encodable { let ids: [String] }
        let id = try validID(assetID)
        let data = try await send("DELETE", ["albums", validID(albumID), "assets"], body: JSONEncoder().encode(Body(ids: [id])), expectedStatus: 200)
        try confirmMembership(data, assetID: id)
    }

    /// assetID为需加入成员、albumID为相簿；响应必须唯一对应请求ID并确认成功。
    func add(_ assetID: String, to albumID: String) async throws {
        struct Body: Encodable { let ids: [String] }
        let id = try validID(assetID)
        let data = try await send("PUT", ["albums", validID(albumID), "assets"], body: JSONEncoder().encode(Body(ids: [id])), expectedStatus: 200)
        try confirmMembership(data, assetID: id)
    }

    /// data为官方BulkIdResponseDto数组，assetID为唯一请求身份；缺ID、错误ID、失败或额外行均不确认为成功。
    private func confirmMembership(_ data: Data, assetID: String) throws {
        struct Result: Decodable { let id: String; let success: Bool }
        guard let results = try? JSONDecoder().decode([Result].self, from: data), results.count == 1,
              let result = results.first, result.id.lowercased() == assetID.lowercased(), result.success
        else { throw LibraryWriteError.malformedResponse }
    }

    struct UploadResult: Decodable, Sendable { let id: String; let status: String }

    /// 流式计算校验和、先查重、再从磁盘上传；绝不把大视频整体读入内存。
    @concurrent func upload(file: URL, filename: String, created: Date, modified: Date,
                            favorite: Bool, hidden: Bool = false, livePhotoVideoID: String? = nil) async throws -> UploadResult
    {
        let checksum = try Self.checksum(file)
        struct Check: Encodable { let assets: [Item]; struct Item: Encodable { let id: String; let checksum: String } }
        struct Checks: Decodable {
            let results: [Item]
            struct Item: Decodable { let id: String; let action: String; let assetId: String?; let isTrashed: Bool? }
        }
        let key = UUID().uuidString
        let checkBody = try JSONEncoder().encode(Check(assets: [.init(id: key, checksum: checksum)]))
        let check = try await JSONDecoder().decode(Checks.self, from: send("POST", ["assets", "bulk-upload-check"], body: checkBody))
        guard check.results.count == 1, let result = check.results.first, result.id == key else { throw LibraryWriteError.malformedResponse }
        if result.action == "reject" {
            guard result.isTrashed != true else { throw LibraryWriteError.trashedDuplicate }
            guard let id = result.assetId else { throw LibraryWriteError.malformedResponse }
            return try UploadResult(id: validID(id), status: "duplicate")
        }
        guard result.action == "accept" else { throw LibraryWriteError.malformedResponse }
        let boundary = "Remmich-\(UUID().uuidString)"
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        FileManager.default.createFile(atPath: bodyFile.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyFile)
        defer { try? output.close() }
        func write(_ value: String) throws {
            try output.write(contentsOf: Data(value.utf8))
        }
        var fields = ["fileCreatedAt": created.ISO8601Format(), "fileModifiedAt": modified.ISO8601Format(), "isFavorite": String(favorite)]
        if hidden {
            fields["visibility"] = "hidden"
        }
        if let livePhotoVideoID {
            fields["livePhotoVideoId"] = try validID(livePhotoVideoID)
        }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        // 原始名称可能带引号或换行，必须清理以避免 multipart 头注入。
        let safeName = filename.replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\\", with: "_")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        try output.synchronize()
        var request = try request("POST", ["assets"])
        request.timeoutInterval = 3600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        let (data, response) = try await session.upload(for: request, fromFile: bodyFile)
        let uploaded = try JSONDecoder().decode(UploadResult.self, from: checked(data, response))
        _ = try validID(uploaded.id)
        guard ["created", "duplicate"].contains(uploaded.status) else { throw LibraryWriteError.malformedResponse }
        return uploaded
    }

    static func checksum(_ file: URL) throws -> String {
        var hash = Insecure.SHA1()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
