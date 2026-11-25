/// 相簿写后读取的显式能力；普通albums可能来自索引队列，不能被当作已完成写入后的新鲜状态。
nonisolated protocol ManagementAlbumReading: AlbumReading {
    /// 每次使用当前凭据发起独立前台GET；返回此刻真实相簿列表，错误不得降级为旧已完成响应。
    func foregroundAlbums() async throws -> [AlbumSummary]
}
