import Foundation

/// SDK日期过滤的替换类型，保留缺省/null/日期，防止默认排除回收站的eq:null被省略。
struct ImmichNullableDateFilter: Codable, Hashable, Sendable {
    /// missing省略键，null匹配未回收日期，date通过SDK日期编码策略序列化。
    enum Value: Hashable, Sendable { case missing, null, date(Date) }
    var eq: Value = .missing
    var gt: Date?
    var gte: Date?
    var lt: Date?
    var lte: Date?
    var ne: Value = .missing
    private enum CodingKeys: String, CodingKey { case eq, gt, gte, lt, lte, ne }

    /// eq/ne为三态，gt/gte/lt/lte为边界日期；nil只省略对应边界，保留官方全部日期运算符。
    init(eq: Value = .missing, gt: Date? = nil, gte: Date? = nil, lt: Date? = nil, lte: Date? = nil, ne: Value = .missing) {
        self.eq = eq
        self.gt = gt
        self.gte = gte
        self.lt = lt
        self.lte = lte
        self.ne = ne
    }

    /// decoder按SDK的日期策略读取值，缺省与显式null独立保留。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eq = try Self.value(container, key: .eq)
        ne = try Self.value(container, key: .ne)
        gt = try container.decodeIfPresent(Date.self, forKey: .gt)
        gte = try container.decodeIfPresent(Date.self, forKey: .gte)
        lt = try container.decodeIfPresent(Date.self, forKey: .lt)
        lte = try container.decodeIfPresent(Date.self, forKey: .lte)
    }

    /// encoder由SDK提供；显式null必须写出，真实日期沿用其现有ISO8601策略。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try Self.encode(eq, key: .eq, container: &container)
        try Self.encode(ne, key: .ne, container: &container)
        try container.encodeIfPresent(gt, forKey: .gt)
        try container.encodeIfPresent(gte, forKey: .gte)
        try container.encodeIfPresent(lt, forKey: .lt)
        try container.encodeIfPresent(lte, forKey: .lte)
    }

    /// container/key指定eq或ne；不存在与null均不尝试日期解析。
    private static func value(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Value {
        guard container.contains(key) else { return .missing }
        return try container.decodeNil(forKey: key) ? .null : .date(container.decode(Date.self, forKey: key))
    }

    /// value为当前比较值，key为运算符；修改container的该键，不影响其他日期边界。
    private static func encode(_ value: Value, key: CodingKeys, container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch value {
        case .missing: break
        case .null: try container.encodeNil(forKey: key)
        case let .date(date): try container.encode(date, forKey: key)
        }
    }
}
