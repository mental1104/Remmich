import Foundation

/// 默认照片时间线的伙伴查询作用域；仅保存账号namespace、伙伴ID和可空偏好，不含用户姓名/凭据或媒体。
nonisolated struct PartnerTimelinePolicy: Codable, Equatable, Sendable {
    /// 单个incoming方向的服务端偏好；nil代表未知，永远不能拿它作为增量复用凭据。
    struct Member: Codable, Equatable, Sendable { let id: String; let inTimeline: Bool? }
    let namespace: String
    let members: [Member]

    /// scope固定账号，incoming来自fresh本人接收列表；规范化顺序/UUID，拒绝重复或无效身份。
    init(scope: MediaAccountScope, incoming: [ManagedPartner]) throws {
        namespace = scope.cacheNamespace
        guard incoming.allSatisfy({ UUID(uuidString: $0.id) != nil }), Set(incoming.map { $0.id.lowercased() }).count == incoming.count else {
            throw PartnerTimelinePolicyError.invalidPolicy
        }
        members = incoming.map { .init(id: $0.id.lowercased(), inTimeline: $0.inTimeline) }.sorted { $0.id < $1.id }
    }

    var isKnown: Bool {
        members.allSatisfy { $0.inTimeline != nil }
    }

    /// 解码后的证书必须再次核namespace、规范成员顺序及唯一ID，不把损坏文件当作已确认作用域。
    func validate(scope: MediaAccountScope) throws {
        guard namespace == scope.cacheNamespace, members.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.id == $0.id.lowercased() }),
              members == members.sorted(by: { $0.id < $1.id }), Set(members.map(\.id)).count == members.count else { throw PartnerTimelinePolicyError.invalidPolicy }
    }
}

/// 默认timeline的持久作用域证明；完整证书和分批checkpoint都必须绑定实际accepted代际。
nonisolated struct PartnerTimelineCertificate: Codable, Sendable {
    enum Coverage: String, Codable, Sendable { case acceptedMonths }
    let formatVersion: Int
    let generation: Int64
    let policy: PartnerTimelinePolicy
    /// v1缺少此字段，仍只代表旧版完整证书；v2明确只证明已接受月份，不代表整库完成。
    let coverage: Coverage?

    /// generation是原SQLite已暂存、即将accept的正代际；只在完整月份及bookend已核对后构造。
    init(generation: Int64, policy: PartnerTimelinePolicy) {
        formatVersion = 1; self.generation = generation; self.policy = policy; coverage = nil
    }

    /// 只在本批所有新增/替换月份及策略bookend通过后构造，随后仍须原子accept此代际。
    init(partialGeneration: Int64, policy: PartnerTimelinePolicy) {
        formatVersion = 2; generation = partialGeneration; self.policy = policy; coverage = .acceptedMonths
    }

    /// scope为实际目录拥有者；未知版本/非正代际拒绝，nil偏好即使文件有效也不能命中复用。
    func validates(scope: MediaAccountScope) -> Bool {
        let supported = (formatVersion == 1 && coverage == nil)
            || (formatVersion == 2 && coverage == .acceptedMonths && policy.isKnown)
        return supported && generation > 0 && (try? policy.validate(scope: scope)) != nil
    }

    /// 只有完整匹配当前accepted generation和已知fresh策略，旧月计数才具有同一查询作用域。
    func matches(generation: Int64?, policy: PartnerTimelinePolicy, scope: MediaAccountScope) -> Bool {
        formatVersion == 1 && allowsIncrementalReuse(generation: generation, policy: policy, scope: scope)
    }

    /// 分批接续只复用同策略、同accepted代际的已核月份；不对缺失月份或UI发布完整成功。
    func allowsIncrementalReuse(generation: Int64?, policy: PartnerTimelinePolicy, scope: MediaAccountScope) -> Bool {
        validates(scope: scope) && self.generation == generation && self.policy == policy && policy.isKnown
    }
}

/// 真实同步源提供fresh伙伴策略，与原repo账号/路由生命周期绑定；不是Media管理器或持久GET的缓存值。
nonisolated protocol PartnerTimelinePolicyReading: Sendable {
    /// scope是当前待同步账号；返回fresh规范incoming策略，账号/路由退休或HTTP失败抛错，不读媒体。
    func partnerTimelinePolicy(scope: MediaAccountScope) async throws -> PartnerTimelinePolicy
    /// 只退休该账号旧policy的index元数据GET，保留媒体/导出/相簿队列；必须先于新证书写入。
    func retirePartnerTimelineIndexReads(scope: MediaAccountScope) async throws
}

/// 证书随原账号目录的SQLite actor串行访问；写入不accept索引、不创建第二个同步worker。
nonisolated protocol PartnerTimelineCertificateStoring: Sendable {
    /// scope限定账号目录；缺失/损坏/未知格式返回nil表示未确认，I/O失败抛错。
    func loadPartnerTimelineCertificate(scope: MediaAccountScope) async throws -> PartnerTimelineCertificate?
    /// certificate必须对应scope的building代际；原子写失败抛错，不改变accepted指针。
    func stagePartnerTimelineCertificate(_ certificate: PartnerTimelineCertificate, scope: MediaAccountScope) async throws
}

/// 只输出安全ASCII原因；坏作用域/半桶必须保持旧accepted目录，不能降级成普通增量成功。
nonisolated enum PartnerTimelinePolicyError: LocalizedError {
    case invalidPolicy, incompleteMonths, changedPolicy, unavailableStore
    var errorDescription: String? {
        switch self {
        case .invalidPolicy: "Partner timeline policy is invalid. Reload partner sharing."
        case .incompleteMonths: "Partner timeline months could not be verified completely. Retry reading the photo list."
        case .changedPolicy: "Partner timeline policy changed during indexing. Retry reading the photo list."
        case .unavailableStore: "Partner timeline verification storage is unavailable."
        }
    }
}
