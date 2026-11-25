import Foundation

/// Remmich自有相簿读取投影；保留首位owner展示字段，并完整携带官方成员中的所有owner身份供本人筛选。
public struct ImmichAlbum: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let thumbnailAssetID: String?
    public let assetCount: Int
    public let updatedAt: Date
    public let createdAt: Date
    public let startDate: Date?
    public let endDate: Date?
    public let lastModifiedAssetTimestamp: Date?
    public let isShared: Bool
    public let ownerName: String?
    public let ownerID: String?
    public let ownerIDs: [String]
}
