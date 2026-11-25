import Foundation

/// 场景外层展示组，仅引用当前完整照片快照；不是官方stack资源，也没有客户端写入能力。
nonisolated struct SceneStackGroup: Identifiable, Hashable, Sendable {
    let id: String
    let coverID: String
    let memberIDs: [String]
}

/// 未查询空月、不支持、证据不可用与成功组明确分开；HTTP/JSON失败通过throws保留。
nonisolated enum SceneStackAvailability: Sendable {
    case notRequested, unsupported, unavailable, available([SceneStackGroup])

    /// 仅完整成功的分组参与投影；其余状态都保留完整原生照片。
    var groups: [SceneStackGroup] {
        if case let .available(groups) = self {
            return groups
        }; return []
    }
}

/// 只读组证据或快照形状不可信时禁止隐藏任何照片，不把损坏响应转成空成功。
nonisolated enum SceneStackError: Error, Equatable, Sendable { case invalidGroups }

/// 保留原始摘要的独立页面投影；group仅标记封面，展开子项仍是同一原片/原日期/官方stack字段。
nonisolated struct SceneStackTile: Identifiable, Sendable {
    let asset: TimelineAssetSummary
    let group: SceneStackGroup?
    var id: String {
        asset.id
    }
}

/// 仅接受完整当前请求内、互不重叠且包含封面的有效组；绝不根据相似度自行创造分组。
nonisolated enum SceneStackValidator {
    /// groups来自一次真实chunk响应，assetIDs为该请求完整ID；返回规范化组，任何坏项使整个响应失败。
    static func validate(_ groups: [SceneStackGroup], assetIDs: [String]) throws -> [SceneStackGroup] {
        let requested = try Set(assetIDs.map(canonicalID))
        guard requested.count == assetIDs.count else { throw SceneStackError.invalidGroups }
        var used = Set<String>(); var groupIDs = Set<String>()
        return try groups.map { group in
            // group ID是区分大小写的不透明展示键，不当作asset UUID、路径或服务端可写资源。
            let id = group.id
            let cover = try canonicalID(group.coverID)
            let members = try group.memberIDs.map(canonicalID)
            let unique = Set(members)
            guard !id.isEmpty, members.count >= 2, unique.count == members.count, unique.contains(cover),
                  unique.isSubset(of: requested), used.isDisjoint(with: unique), groupIDs.insert(id).inserted else { throw SceneStackError.invalidGroups }
            used.formUnion(unique)
            return .init(id: id, coverID: cover, memberIDs: members)
        }
    }

    /// assets为完整月快照；groups已严格验证，expanded仅是本页状态，关闭分组时调用方传空groups恢复原顺序。
    /// 返回只影响此页面的单元，不修改摘要、canonical Index、拍摄日期或原生stack。
    static func project(assets: [TimelineAssetSummary], groups: [SceneStackGroup], expanded: Set<String>) -> [SceneStackTile] {
        let membership = Dictionary(groups.flatMap { group in group.memberIDs.map { ($0, group) } }, uniquingKeysWith: { first, _ in first })
        var children: [String: [TimelineAssetSummary]] = [:]
        for asset in assets {
            if let group = membership[asset.id.lowercased()], asset.id.lowercased() != group.coverID {
                children[group.id, default: []].append(asset)
            }
        }
        var result: [SceneStackTile] = []
        for asset in assets {
            guard let group = membership[asset.id.lowercased()] else { result.append(.init(asset: asset, group: nil)); continue }
            guard group.coverID == asset.id.lowercased() else { continue }
            result.append(.init(asset: asset, group: group))
            if expanded.contains(group.id) {
                // 展开成员相邻展示，但仍保留原摘要日期；成员顺序以原桶为准，不信任manifest顺序。
                result += (children[group.id] ?? []).map { .init(asset: $0, group: nil) }
            }
        }
        return result
    }

    /// value必须为UUID；统一大小写仅用于组身份比较，不重写原始照片摘要。
    private static func canonicalID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value) else { throw SceneStackError.invalidGroups }
        return uuid.uuidString.lowercased()
    }
}

/// 原仓库创建的代际绑定前台读取器；完整月份/照片与可选分组分别读取，失败保留原片快照。
nonisolated protocol SceneStackReading: Sendable {
    /// 返回真实标准月份；count包含标准桶媒体，不能未经IMAGE过滤就称照片总数。
    func months() async throws -> [TimelineBucketSummary]
    /// bucketID为真实月份；返回完整本人可见照片，错误抛出而非假空月。
    func assets(in bucketID: TimelineBucketID) async throws -> [TimelineAssetSummary]
    /// assets为完整本月照片，分组只在这些ID内生效；不支持与证据不可用明确返回，HTTP失败抛出。
    func groups(for assets: [TimelineAssetSummary]) async throws -> SceneStackAvailability
    /// 主Photos可能含伙伴/视频；仅本人IMAGE参加查询，其余原行由调用方保持，不改变单张/选择语义。
    func groupsForTimeline(_ assets: [TimelineAssetSummary]) async throws -> SceneStackAvailability
}

extension SceneStackReading {
    /// 简单测试/只含本人照片的来源沿用既有方法；真实repo覆盖此方法，使用已验证身份筛选混合主时间线。
    nonisolated func groupsForTimeline(_ assets: [TimelineAssetSummary]) async throws -> SceneStackAvailability {
        try await groups(for: assets)
    }
}

/// Feature只取得原仓库生命周期内的窄facade，不能复制旧token创建脱离换号生命周期的读取器。
nonisolated protocol SceneStackProviding: Sendable {
    /// 返回绑定原仓库当前代际的读取器；旧facade在换号/换端点后所有方法均失败。
    func sceneStackReader() async throws -> any SceneStackReading
}
