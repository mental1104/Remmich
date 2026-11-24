import Foundation

/// SDK的NumberFilterNullable替换类型，保留缺省/null/数值，其他官方比较操作原样编解码。
struct ImmichNullableNumberFilter: Codable, Hashable, Sendable {
    /// missing省略键，null明确匹配空值，number保留0和其他具体数值。
    enum Value: Hashable, Sendable { case missing, null, number(Double) }
    var eq: Value = .missing
    var gt: Double?
    var gte: Double?
    var inValues: [Double]?
    var lt: Double?
    var lte: Double?
    var ne: Value = .missing
    var notIn: [Double]?
    private enum CodingKeys: String, CodingKey { case eq, gt, gte, inValues = "in", lt, lte, ne, notIn }

    /// eq/ne支持三态，其他参数为官方数值运算符；nil省略该运算符，不向服务器增加默认限制。
    init(eq: Value = .missing, gt: Double? = nil, gte: Double? = nil, inValues: [Double]? = nil,
         lt: Double? = nil, lte: Double? = nil, ne: Value = .missing, notIn: [Double]? = nil)
    {
        self.eq = eq
        self.gt = gt
        self.gte = gte
        self.inValues = inValues
        self.lt = lt
        self.lte = lte
        self.ne = ne
        self.notIn = notIn
    }

    /// decoder为符合官方NumberFilterNullable的JSON；不存在与显式null必须独立保留。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eq = try Self.value(container, key: .eq)
        ne = try Self.value(container, key: .ne)
        gt = try container.decodeIfPresent(Double.self, forKey: .gt)
        gte = try container.decodeIfPresent(Double.self, forKey: .gte)
        inValues = try container.decodeIfPresent([Double].self, forKey: .inValues)
        lt = try container.decodeIfPresent(Double.self, forKey: .lt)
        lte = try container.decodeIfPresent(Double.self, forKey: .lte)
        notIn = try container.decodeIfPresent([Double].self, forKey: .notIn)
    }

    /// encoder为SDK请求编码器；null写出JSON null，missing才省略。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try Self.encode(eq, key: .eq, container: &container)
        try Self.encode(ne, key: .ne, container: &container)
        try container.encodeIfPresent(gt, forKey: .gt)
        try container.encodeIfPresent(gte, forKey: .gte)
        try container.encodeIfPresent(inValues, forKey: .inValues)
        try container.encodeIfPresent(lt, forKey: .lt)
        try container.encodeIfPresent(lte, forKey: .lte)
        try container.encodeIfPresent(notIn, forKey: .notIn)
    }

    /// container/key定位eq或ne；返回缺省、null或实际数值，类型错误交给解码器抛出。
    private static func value(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Value {
        guard container.contains(key) else { return .missing }
        return try container.decodeNil(forKey: key) ? .null : .number(container.decode(Double.self, forKey: key))
    }

    /// value/key指定比较项，container为当前编码容器；只修改对应键，不改变其他运算符。
    private static func encode(_ value: Value, key: CodingKeys, container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch value {
        case .missing: break
        case .null: try container.encodeNil(forKey: key)
        case let .number(number): try container.encode(number, forKey: key)
        }
    }
}
