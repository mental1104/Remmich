import Foundation

/// 相簿公开链接可写选项；密码只在当前页内存中用于保留/确认，不落盘、打印或展示服务端原值。
nonisolated struct AlbumPublicLinkOptions: Encodable, Equatable, Sendable {
    var description: String?
    var password: String?
    var slug: String?
    var expiresAt: Date?
    var allowUpload: Bool
    var allowDownload: Bool
    var showMetadata: Bool

    /// 规范化空值和毫秒日期；forCreation仅在POST时应用服务端的隐藏元数据/下载联动。
    /// 默认更新保留合法既有权限组合，不因修改描述而隐式关闭下载；返回新副本，不裁剪非空密码或slug。
    func normalized(forCreation: Bool = false) throws -> Self {
        var result = self
        if result.description?.isEmpty == true {
            result.description = nil
        }
        if result.password?.isEmpty == true {
            result.password = nil
        }
        if result.slug?.isEmpty == true {
            result.slug = nil
        }
        if let expiresAt {
            guard expiresAt.timeIntervalSince1970.isFinite else { throw AlbumPublicLinkError.invalidOptions }
            result.expiresAt = try AlbumPublicLink.date(AlbumPublicLink.dateString(expiresAt))
        }
        if forCreation, !showMetadata {
            result.allowDownload = false
        }
        return result
    }

    /// 显式编码全部七项；nil是清除，不能因省略slug而触发服务端意外清除原自定义地址。
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(description, forKey: .description); try values.encode(password, forKey: .password)
        try values.encode(slug, forKey: .slug); try values.encode(expiresAt.map(AlbumPublicLink.dateString), forKey: .expiresAt)
        try values.encode(allowUpload, forKey: .allowUpload); try values.encode(allowDownload, forKey: .allowDownload)
        try values.encode(showMetadata, forKey: .showMetadata)
    }

    /// 当前官方完整编辑字段；不发送客户端状态、密钥、所有者或相簿内容。
    private enum CodingKeys: String, CodingKey { case description, password, slug, expiresAt, allowUpload, allowDownload, showMetadata }
}

/// 官方ALBUM链接的管理快照；列表/详情有album，创建/更新回执可没有，后者必须由fresh详情补证。
nonisolated struct AlbumPublicLink: Decodable, Identifiable, Equatable, Sendable {
    /// 嵌套相簿仅用于身份和名称，不能把其中仅owner的投影当成完整共享权限。
    struct Album: Decodable, Equatable, Sendable { let id: String; let albumName: String }

    let id: String
    let userId: String
    let key: String
    let type: String
    let createdAt: Date
    let album: Album?
    let options: AlbumPublicLinkOptions

    /// decoder为当前HTTP JSON；要求真实nullable字段和合法日期，缺失字段不能默认为清除/永久或未保护。
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); userId = try values.decode(String.self, forKey: .userId)
        key = try values.decode(String.self, forKey: .key); type = try values.decode(String.self, forKey: .type)
        createdAt = try Self.date(values.decode(String.self, forKey: .createdAt))
        album = try values.decodeIfPresent(Album.self, forKey: .album)
        let expiration = try values.decode(String?.self, forKey: .expiresAt)
        options = try .init(description: values.decode(String?.self, forKey: .description),
                            password: values.decode(String?.self, forKey: .password), slug: values.decode(String?.self, forKey: .slug),
                            expiresAt: expiration.map(Self.date), allowUpload: values.decode(Bool.self, forKey: .allowUpload),
                            allowDownload: values.decode(Bool.self, forKey: .allowDownload), showMetadata: values.decode(Bool.self, forKey: .showMetadata))
    }

    /// userID为当前链接创建者，albumID为明确选中相簿；回执可暂缺album，但不能含错误相簿或其他创建者。
    func validate(userID: String, albumID: String, requiresAlbum: Bool = true) throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: userId) != nil, userId.lowercased() == userID.lowercased(), type == "ALBUM",
              !key.isEmpty, key.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }),
              !requiresAlbum || album != nil, album == nil || album?.id.lowercased() == albumID.lowercased() else { throw LibraryWriteError.malformedResponse }
    }

    /// POST/PATCH回执可能缺album；仍须与fresh详情的链接身份、选项和密钥一致，不能靠请求正文伪造结果。
    func confirms(_ receipt: Self) -> Bool {
        id.lowercased() == receipt.id.lowercased() && userId.lowercased() == receipt.userId.lowercased()
            && key == receipt.key && type == receipt.type && createdAt == receipt.createdAt && options == receipt.options
    }

    /// 只在用户主动复制时构造地址；保留反向代理前缀并按component编码slug，不在UI/日志输出密钥。
    func copyURL(apiURL: URL) -> URL? {
        guard apiURL.lastPathComponent == "api", apiURL.user == nil, apiURL.password == nil,
              apiURL.host?.isEmpty == false, apiURL.query == nil, apiURL.fragment == nil,
              ["https", "http"].contains(apiURL.scheme?.lowercased() ?? "") else { return nil }
        let base = apiURL.deletingLastPathComponent()
        if let slug = options.slug, !slug.isEmpty {
            guard slug != ".", slug != ".." else { return nil }
            return base.appending(path: "s").appending(component: slug)
        }
        guard !key.isEmpty, key != ".", key != "..", !key.contains("/") else { return nil }
        return base.appending(path: "share").appending(component: key)
    }

    /// value是官方ISO日期；允许有/无小数秒，其他格式明确失败，不把损坏有效期当永久有效。
    static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) {
            return result
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let result = formatter.date(from: value) else { throw LibraryWriteError.malformedResponse }
        return result
    }

    /// date为有效内存日期；返回官方毫秒ISO格式供显式选项编码及确认，格式器不跨actor共享。
    static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// 仅读取相簿链接的身份与完整访问选项；单资源assets管理不属于此页。
    private enum CodingKeys: String, CodingKey { case id, userId, key, type, createdAt, album, description, password, slug, expiresAt, allowUpload, allowDownload, showMetadata }
}

/// 一次明确的公开链接动作；已有链接依据创建者管理，不额外要求其仍有相簿owner/editor角色。
nonisolated enum AlbumPublicLinkCommand: Sendable {
    case create(AlbumPublicLinkOptions)
    case update(AlbumPublicLink, AlbumPublicLinkOptions)
    case revoke(AlbumPublicLink)
}

/// 确认固定相簿/已有链接基线与页面账号代际；敏感选项仅在此内存计划中保留。
nonisolated struct AlbumPublicLinkPlan: Identifiable, Sendable {
    let id = UUID()
    let album: AlbumSharingSnapshot
    let baseline: [AlbumPublicLink]
    let command: AlbumPublicLinkCommand
    let readGeneration: UUID
    let accountGeneration: UUID
}

/// 仅本地安全原因；不包含服务端原文、链接地址、密钥或密码。
nonisolated enum AlbumPublicLinkError: Error { case reloadRequired, permission, changed, invalidOptions }
