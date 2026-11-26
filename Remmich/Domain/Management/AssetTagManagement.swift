import Foundation

/// 当前账号的官方标签；name是叶名、value是完整层级路径，缺省颜色/父ID保持nil。
nonisolated struct ManagedTag: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let parentId: String?
    let name: String
    let value: String
    let createdAt: String
    let updatedAt: String
    let color: String?
    /// 保留wire缺键与显式null的区别；官方mapTag在无颜色时省略，不据此补发clear命令。
    let hasColorField: Bool

    private enum CodingKeys: String, CodingKey { case id, parentId, name, value, createdAt, updatedAt, color }

    /// decoder来自完整标签对象；缺省颜色可正常读取，但错误类型不能降级成无颜色。
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); parentId = try values.decodeIfPresent(String.self, forKey: .parentId)
        name = try values.decode(String.self, forKey: .name); value = try values.decode(String.self, forKey: .value)
        createdAt = try values.decode(String.self, forKey: .createdAt); updatedAt = try values.decode(String.self, forKey: .updatedAt)
        color = try values.decodeIfPresent(String.self, forKey: .color); hasColorField = values.contains(.color)
    }

    /// other是同一标签旧定义；只允许颜色及更新时间变化，保留身份、名称、路径、父级和创建时间。
    func preservesDefinition(of other: ManagedTag) -> Bool {
        id == other.id && parentId == other.parentId && name == other.name && value == other.value && createdAt == other.createdAt
    }

    /// value为真实UUID；官方标签接口要求v4/RFC变体，非法值不得进入路径或请求体。
    static func requireID(_ value: String) throws {
        guard let uuid = UUID(uuidString: value), uuid.uuid.6 >> 4 == 4, uuid.uuid.8 & 0xC0 == 0x80 else { throw LibraryWriteError.invalidID }
    }

    /// name为单个用户输入叶名；返回trim值，不把斜线解释为创建多级标签，不隐式修改已有层级。
    static func leafName(_ name: String) throws -> String {
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, !result.contains("/") else { throw AssetTagError.invalidName }
        return result
    }

    /// tags来自一次完整GET；返回规范顺序列表，拒绝身份重复、错UUID和重复全路径，不把畸形树当空列表。
    static func catalog(_ tags: [ManagedTag]) throws -> [ManagedTag] {
        var ids = Set<String>(); var paths = Set<String>()
        for tag in tags {
            try requireID(tag.id)
            if let parent = tag.parentId {
                try requireID(parent)
            }
            guard ids.insert(tag.id.lowercased()).inserted, paths.insert(tag.value).inserted,
                  tag.value.components(separatedBy: "/").last == tag.name else { throw LibraryWriteError.malformedResponse }
        }
        return tags.sorted { $0.id < $1.id }
    }
}

/// GET资源标签的独立快照；tags必须实际出现，缺字段/null不能冒充“无标签”。
nonisolated struct TaggedAssetSnapshot: Decodable, Equatable, Sendable {
    let id: String
    let ownerId: String
    let type: String
    let isTrashed: Bool
    let livePhotoVideoId: String?
    let tags: [ManagedTag]

    /// 官方资源响应中本页所需的字段，不写入媒体、EXIF或配对信息。
    private enum CodingKeys: String, CodingKey { case id, ownerId, type, isTrashed, livePhotoVideoId, tags }

    /// decoder来自真实GET200；标签按ID规范化，仅为比较消除数据库返回顺序差异。
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        ownerId = try values.decode(String.self, forKey: .ownerId)
        type = try values.decode(String.self, forKey: .type)
        isTrashed = try values.decode(Bool.self, forKey: .isTrashed)
        livePhotoVideoId = try values.decodeIfPresent(String.self, forKey: .livePhotoVideoId)
        tags = try ManagedTag.catalog(values.decode([ManagedTag].self, forKey: .tags))
    }
}

/// 一次fresh个人树与单资源关系；不包含缓存或跨账号标签候选。
nonisolated struct AssetTagState: Equatable, Sendable {
    let asset: TaggedAssetSnapshot
    let tags: [ManagedTag]

    /// id为真实标签；返回其本身与所有后代ID，按parentId闭包而非显示前缀判断删除影响。
    func subtree(_ id: String) -> Set<String> {
        var result: Set<String> = [id]
        var changed = true
        while changed {
            changed = false
            for tag in tags where tag.parentId.map(result.contains) == true {
                if result.insert(tag.id).inserted {
                    changed = true
                }
            }
        }
        return result
    }
}

/// 每次只执行一个明确命令；单照片关系接口可给精确ID结果，不用bulk计数冒充完整成功。
nonisolated enum AssetTagCommand: Sendable {
    case create(name: String, parentID: String?)
    case rename(tagID: String, name: String)
    case color(tagID: String, change: AssetTagColorChange)
    case delete(tagID: String)
    case attach(tagID: String)
    case detach(tagID: String)

    /// state为真实读取状态；验证名称/层级存在及明确关系，返回无，不自动建父节点或重发重复关系。
    func validate(in state: AssetTagState) throws {
        switch self {
        case let .create(name, parentID):
            let leaf = try ManagedTag.leafName(name)
            let parent = state.tags.first { $0.id == parentID }
            guard parentID == nil || parent != nil else { throw AssetTagError.reloadRequired }
            let value = parent.map { $0.value + "/" + leaf } ?? leaf
            guard !state.tags.contains(where: { $0.value == value }) else { throw AssetTagError.alreadyExists }
        case let .rename(id, name):
            guard let tag = state.tags.first(where: { $0.id == id }) else { throw AssetTagError.reloadRequired }
            let leaf = try ManagedTag.leafName(name)
            guard leaf != tag.name else { throw AssetTagError.noChanges }
            let value = String(tag.value.dropLast(tag.name.count)) + leaf
            guard !state.tags.contains(where: { $0.id != id && $0.value == value }) else { throw AssetTagError.alreadyExists }
        case let .color(id, change):
            guard let tag = state.tags.first(where: { $0.id == id }) else { throw AssetTagError.reloadRequired }
            guard change != .keep, !change.matches(tag) else { throw AssetTagError.noChanges }
        case let .delete(id), let .attach(id), let .detach(id):
            guard state.tags.contains(where: { $0.id == id }) else { throw AssetTagError.reloadRequired }
            let attached = state.asset.tags.contains { $0.id == id }
            if case .attach = self, attached {
                throw AssetTagError.noChanges
            }
            if case .detach = self, !attached {
                throw AssetTagError.noChanges
            }
        }
    }
}

/// 确认绑定完整树、当前照片关系和双代际；旧确认不能用于新的标签树/账号/页面。
nonisolated struct AssetTagPlan: Identifiable, Sendable {
    let id = UUID()
    let baseline: AssetTagState
    let command: AssetTagCommand
    let readGeneration: UUID
    let accountGeneration: UUID
}

/// 官方单ID成员错误保持类型；不显示服务器errorMessage或将duplicate当作新增成功。
nonisolated enum AssetTagMembershipFailure: String, Decodable, Equatable, Sendable {
    case duplicate, noPermission = "no_permission", notFound = "not_found", unknown, validation
}

/// 标签页只显示稳定本地错误，不输出完整服务端正文/私人标签到日志。
nonisolated enum AssetTagError: LocalizedError {
    case invalidName, invalidColor, alreadyExists, noChanges, reloadRequired, changedRemotely, notOwned, trashed
    case membership(AssetTagMembershipFailure)

    var errorDescription: String? {
        switch self {
        case .invalidName: "Enter one nonempty tag name without a slash."
        case .invalidColor: "Choose a valid RGB or RGBA tag color."
        case .alreadyExists: "A tag with this complete path already exists."
        case .noChanges: "The selected tag or relationship has no change."
        case .reloadRequired: "Reload tags before reviewing another change."
        case .changedRemotely: "Tags changed since they were loaded. Reload and review again."
        case .notOwned: "Only the asset owner can manage tags here."
        case .trashed: "Restore this asset before changing its tags."
        case .membership(.duplicate): "The server reports this tag is already attached. Reload to check the current state."
        case .membership(.noPermission): "The server denied permission to change this tag relationship."
        case .membership(.notFound): "The server reports this relationship does not exist. Reload to check."
        case .membership(.validation): "The server rejected the tag relationship. Reload before another change."
        case .membership(.unknown): "The server could not confirm this relationship. Reload before another change."
        }
    }
}
