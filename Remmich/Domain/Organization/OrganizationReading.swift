import Foundation

/// 浏览组织入口的只读边界；随机返回独立批次，待整理只表示当前本人指定分组中的相簿。
nonisolated protocol OrganizationReading: Sendable {
    /// 返回最多60张由服务端抽样的可见照片；无游标，每次调用重新抽样，错误不得伪装为空批次。
    func randomPhotos() async throws -> [TimelineAssetSummary]
    /// ownerID为当前登录用户，返回本人待整理相簿；nil表示服务器没有目录扩展，不等同空列表。
    func pendingAlbums(ownerID: String) async throws -> [AlbumSummary]?
}

/// 精确复用Fork Web的待整理规则，不把无相簿、无标签或别人共享的相簿混入该入口。
nonisolated enum PendingAlbumSelection {
    static let groupName = "待整理"

    /// albums是当前账户可读列表，directory是已规范化的服务器分组，ownerID必须来自会话身份。
    /// 返回去重、最近更新优先的本人相簿；缺失ownerID的相簿不被猜测为本人所有。
    static func select(_ albums: [AlbumSummary], directory: ForkAlbumDirectory, ownerID: String) -> [AlbumSummary] {
        var seen = Set<String>()
        return albums.filter {
            $0.ownerID == ownerID && directory.includes(albumID: $0.id, category: nil, group: groupName)
                && seen.insert($0.id).inserted
        }.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// album为已通过本人分组筛选的相簿；返回包含归档成员与堆叠成员、排除回收站的原生时间线范围。
    static func timelineQuery(for album: AlbumSummary) -> TimelineQuery {
        var query = TimelineQuery(albumID: album.id)
        query.visibility = nil
        query.includesStacks = true
        query.includesPartners = false
        return query
    }
}
