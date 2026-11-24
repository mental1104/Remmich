import Foundation

/// 覆盖旧式smart评分叶节点；外层Optional表示省略，本类型的null必须写为JSON null。
enum ImmichNullableRatingValue: Codable, Hashable, Sendable {
    case null, stars(Int)

    /// decoder来自官方整数或null字段；评分范围由请求入口按契约校验。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try container.decodeNil() ? .null : .stars(container.decode(Int.self))
    }

    /// encoder为SDK单值容器；本类型不存在“省略”，只有外层Optional为nil时才省略字段。
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .stars(value): try container.encode(value)
        }
    }
}
