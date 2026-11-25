import Foundation
import Photos

/// 当前系统照片库访问范围；limited只代表已授权子集，不声称扫描了设备全库。
nonisolated enum LocalPhotoLibraryAccess: String, Codable, Equatable, Sendable { case unknown, full, limited, denied }

/// Controller只依赖身份清单和显式授权；测试可替换系统边界，不能借此绕过真实扫描状态机。
@MainActor protocol LocalPhotoInventoryReading: Sendable {
    var authorization: LocalPhotoLibraryAccess { get }
    /// 只允许用户明确扫描按钮调用，返回系统当前范围，不扩展limited访问。
    func requestAuthorization() async -> LocalPhotoLibraryAccess
    /// validateContext逐批检查账户/取消；返回当前授权图片和视频ID，绝不读取媒体内容。
    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String]
}

/// 默认公开PhotoKit清单；只在前台枚举当前访问对象，每256项让出UI执行器并重新验证权限。
@MainActor struct PhotoKitLocalPhotoInventory: LocalPhotoInventoryReading {
    var authorization: LocalPhotoLibraryAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .full
        case .limited: .limited
        case .notDetermined: .unknown
        default: .denied
        }
    }

    /// 已决定的权限不再次弹框；只有显式扫描遇到notDetermined才请求系统照片授权。
    func requestAuthorization() async -> LocalPhotoLibraryAccess {
        if authorization == .unknown {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return authorization
    }

    /// 不排序文件名/日期或推测云端字节；options仅筛选图片与视频，有限循环定期让出以支持取消。
    func localIdentifiers(validateContext: @MainActor () throws -> Void) async throws -> [String] {
        try Task.checkCancellation(); try validateContext()
        let access = authorization
        guard access == .full || access == .limited else { throw LocalMediaMetadataError.permission }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let assets = PHAsset.fetchAssets(with: options)
        var result: [String] = []
        result.reserveCapacity(assets.count)
        for index in 0 ..< assets.count {
            if index.isMultiple(of: 256) {
                await Task.yield()
                try Task.checkCancellation(); try validateContext()
                guard authorization == access else { throw LocalMediaMetadataError.permission }
            }
            result.append(assets.object(at: index).localIdentifier)
        }
        try Task.checkCancellation(); try validateContext()
        guard authorization == access else { throw LocalMediaMetadataError.permission }
        return result
    }
}
