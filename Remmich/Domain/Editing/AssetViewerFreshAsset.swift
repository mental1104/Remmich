import Foundation

/// 查看器单张直读快照，只理解服务端实际版本/显示字段；不把尺寸、isEdited或HTTP成功当成派生完成证据。
nonisolated struct AssetViewerFreshAsset: Decodable, Sendable {
    let id: String
    let ownerId: String
    let type: String
    let livePhotoVideoId: String?
    let updatedAt: String
    let width: Int?
    let height: Int?
    let thumbhash: String?
    let isFavorite: Bool
    let visibility: String
    let isTrashed: Bool

    /// 返回真实updatedAt含小数的时间；无效时间不能转换为当前时间或伪造新版本。
    func revision() throws -> Date {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = parser.date(from: updatedAt) {
            return value
        }
        parser.formatOptions = [.withInternetDateTime]
        guard let value = parser.date(from: updatedAt) else { throw AssetViewerFreshReadError.invalid }
        return value
    }
}

/// 无效或不匹配的刷新响应；错误不包含私人响应内容，不会伪造新版本。
nonisolated enum AssetViewerFreshReadError: Error, LocalizedError {
    case invalid
    var errorDescription: String? {
        "The current photo state could not be verified."
    }
}
