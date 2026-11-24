import Foundation

/// 编辑列表是可重新提交的完整文档；未知字段必须阻止编辑，不能解码后静默丢弃再覆盖服务器。
nonisolated extension AssetEditList {
    /// decoder可来自本地请求文档或官方GET回执；assetId仅为回执元数据，由读取通道另行核对。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: EditDocumentKey.self)
        try container.requireKnownKeys(["assetId", "edits"])
        edits = try container.decode([Edit].self, forKey: .init("edits"))
    }
}

/// 官方编辑行的id仅标识服务器记录；重提时沿用现有action/parameters请求形状，保持数组顺序。
nonisolated extension AssetEditList.Edit {
    /// decoder必须包含当前理解的完整操作；未来操作或附加行为字段显式失败，交由界面提示升级。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: EditDocumentKey.self)
        try container.requireKnownKeys(["id", "action", "parameters"])
        if container.contains(.init("id")) {
            _ = try container.decode(UUID.self, forKey: .init("id"))
        }
        action = try container.decode(String.self, forKey: .init("action"))
        guard ["crop", "rotate", "mirror"].contains(action) else {
            throw DecodingError.dataCorruptedError(forKey: .init("action"), in: container,
                                                   debugDescription: "Unsupported asset edit action")
        }
        parameters = try container.decode(AssetEditList.Parameters.self, forKey: .init("parameters"))
    }
}

/// 参数对象只接受本版本可以完整保留的字段；值与操作组合的合法性继续由编辑领域模型验证。
nonisolated extension AssetEditList.Parameters {
    /// decoder中的未知参数意味着当前版本无法无损重提，必须抛错而非删除该参数。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: EditDocumentKey.self)
        try container.requireKnownKeys(["x", "y", "width", "height", "angle", "axis"])
        x = try container.decodeIfPresent(Int.self, forKey: .init("x"))
        y = try container.decodeIfPresent(Int.self, forKey: .init("y"))
        width = try container.decodeIfPresent(Int.self, forKey: .init("width"))
        height = try container.decodeIfPresent(Int.self, forKey: .init("height"))
        angle = try container.decodeIfPresent(Int.self, forKey: .init("angle"))
        axis = try container.decodeIfPresent(String.self, forKey: .init("axis"))
    }
}

/// GET回执身份与编辑文档一起解码；请求编码仍只包含edits，不向PUT添加assetId或行id。
nonisolated struct AssetEditReceipt: Decodable, Sendable {
    let assetID: UUID
    let document: AssetEditList

    /// decoder必须来自官方GET /assets/:id/edits；缺少或无效assetId不是可覆盖的空编辑列表。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: EditDocumentKey.self)
        assetID = try container.decode(UUID.self, forKey: .init("assetId"))
        document = try AssetEditList(from: decoder)
    }
}

/// 动态键保留JSON中所有实际字段，避免合成CodingKeys在检查前已忽略未来字段。
private nonisolated struct EditDocumentKey: CodingKey {
    let stringValue: String
    var intValue: Int? {
        nil
    }

    /// value为JSON字段原文；此键只用于读取和完整性检查，不做大小写转换。
    init(_ value: String) {
        stringValue = value
    }

    /// stringValue为解码器提供的字段名；任意字段均保留，之后再检查白名单。
    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    /// intValue不用于对象字段；拒绝整数字段键。
    init?(intValue _: Int) {
        nil
    }
}

private nonisolated extension KeyedDecodingContainer where Key == EditDocumentKey {
    /// allowed为当前协议可完整保留的字段集合；未知字段阻止可写文档的解码。
    func requireKnownKeys(_ allowed: Set<String>) throws {
        guard allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Unsupported asset edit fields"))
        }
    }
}
