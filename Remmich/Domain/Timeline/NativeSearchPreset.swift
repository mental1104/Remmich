import Foundation

/// 保存条件中的三种状态；missing不写字段，null明确表示无评分/无标签。
nonisolated enum NativePresetNullable<Value: Codable & Sendable>: Codable, Sendable {
    case missing, null, value(Value)

    /// 从单值解码显式null或有效值；missing只能由键容器确认字段缺省。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try container.decodeNil() ? .null : .value(container.decode(Value.self))
    }

    /// 向单值容器编码null/值；missing必须交由键容器省略，禁止伪装成null。
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .missing:
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Missing preset values require a keyed container."))
        case .null: try container.encodeNil()
        case let .value(value): try container.encode(value)
        }
    }
}

extension NativePresetNullable: Equatable where Value: Equatable {}

extension KeyedDecodingContainer {
    /// type为可缺省条件，key是JSON字段；明确保留不存在与null的差异。
    nonisolated func decode<Value: Codable & Sendable>(_: NativePresetNullable<Value>.Type, forKey key: Key) throws -> NativePresetNullable<Value> {
        guard contains(key) else { return .missing }
        return try decodeNil(forKey: key) ? .null : .value(decode(Value.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    /// value为可缺省条件，key为JSON字段；只有missing省略，null必须保留。
    nonisolated mutating func encode(_ value: NativePresetNullable<some Codable & Sendable>, forKey key: Key) throws {
        switch value {
        case .missing: break
        case .null: try encodeNil(forKey: key)
        case let .value(value): try encode(value, forKey: key)
        }
    }
}

/// 完整建模现有服务端登记结构，暂未提供控件的字段也不能在改名时丢失。
nonisolated struct NativeSearchPresetConditions: Codable, Sendable {
    struct TextQuery: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case smart, metadata, description, fullPath, ocr }
        let value: String
        let type: Kind
    }

    enum AlbumStatus: String, Codable, Sendable { case inAlbum = "in", notInAlbum = "notIn" }
    enum MediaType: String, Codable, Sendable { case image, video }
    typealias MediaCategory = NativeSearchMediaCategory
    typealias Resolution = NativeSearchResolution

    var query: TextQuery?
    var queryAssetId: String?
    var personIds: [String]?
    var tagIds: NativePresetNullable<[String]> = .missing
    var country: String?
    var state: String?
    var city: String?
    var make: String?
    var model: String?
    var lensModel: String?
    var deviceModels: [String]?
    var takenAfter: String?
    var takenBefore: String?
    var isArchive: Bool?
    var isFavorite: Bool?
    var albumStatus: AlbumStatus?
    var mediaType: MediaType?
    var isPanorama: Bool?
    var mediaCategory: MediaCategory?
    var resolution: Resolution?
    var orientation: NativeSearchQuery.Orientation?
    var rating: NativePresetNullable<Int> = .missing
    var exifConditions: [NativeSearchNumericCondition]?

    /// 编译器校验的字段全集，同时用于阻止新版未知条件被静默忽略。
    enum CodingKeys: String, CodingKey, CaseIterable {
        case query, queryAssetId, personIds, tagIds, country, state, city, make, model, lensModel, deviceModels
        case takenAfter, takenBefore, isArchive, isFavorite, albumStatus, mediaType, isPanorama, mediaCategory
        case resolution, orientation, rating, exifConditions
    }
}

/// 当前用户的具名条件；解析未知条件时拒绝，避免修改后破坏服务器保存内容。
nonisolated struct NativeSearchPreset: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let conditions: NativeSearchPresetConditions

    private enum CodingKeys: String, CodingKey { case id, name, conditions }

    /// decoder为服务端JSON；先检查字段全集，再解码完整条件结构。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.superDecoder(forKey: .conditions)
        let keys = try nested.container(keyedBy: PresetConditionKey.self).allKeys.map(\.stringValue)
        let allowed = Set(NativeSearchPresetConditions.CodingKeys.allCases.map(\.rawValue))
        guard Set(keys).isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(.init(codingPath: nested.codingPath, debugDescription: "Unsupported saved search fields."))
        }
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        conditions = try NativeSearchPresetConditions(from: nested)
    }
}

/// 仅用于枚举JSON条件键，不把任意字典引入领域查询接口。
private nonisolated struct PresetConditionKey: CodingKey {
    let stringValue: String
    var intValue: Int? {
        nil
    }

    /// stringValue为JSON对象的原始键名，不改变内容。
    init(stringValue: String) {
        self.stringValue = stringValue
    }

    /// 条件字段不使用数组数字键。
    init?(intValue _: Int) {
        nil
    }
}
