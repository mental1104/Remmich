import CoreLocation
import Foundation
import Photos

/// 设备媒体关联的只读元数据边界；不请求展示图像/视频或原片，不判断备份完成。
@MainActor protocol LocalPhotoMetadataReading: Sendable {
    /// localIdentifiers最多64项且不重复；validateContext由当前账户/页面提供，每次异步边界前后检查发布代际。
    func snapshots(for localIdentifiers: [String], validateContext: @MainActor () throws -> Void) async throws -> [LocalPhotoSnapshot]
}

/// 公开PhotoKit元数据与Cloud ID映射适配；只返回有限当前授权集合，映射期间发生变化则拒绝旧快照。
@MainActor struct PhotoKitLocalPhotoMetadataReader: LocalPhotoMetadataReading {
    typealias AssetLoader = @MainActor ([String]) throws -> [LocalPhotoSnapshot]
    typealias CloudLoader = @Sendable ([String]) async throws -> [String: LocalPhotoCloudIdentity]
    static let batchLimit = 64
    private let assetLoader: AssetLoader
    private let cloudLoader: CloudLoader

    /// assets/cloudIDs仅替换各自系统读取来源，nil使用公开PhotoKit；批量、重复/越界身份、取消和代际校验仍真实执行。
    init(assets: AssetLoader? = nil, cloudIDs: CloudLoader? = nil) {
        assetLoader = assets ?? Self.readAssets
        cloudLoader = cloudIDs ?? LocalPhotoCloudLookup.read
    }

    /// 保留调用方顺序；当前不可见ID不返回。所有返回项都在Cloud映射前后重新读取，并保持完全相同的元数据版本。
    func snapshots(for localIdentifiers: [String], validateContext: @MainActor () throws -> Void) async throws -> [LocalPhotoSnapshot] {
        try checkContext(validateContext)
        guard localIdentifiers.count <= Self.batchLimit, localIdentifiers.allSatisfy({ !$0.isEmpty }),
              Set(localIdentifiers).count == localIdentifiers.count else { throw LocalMediaMetadataError.invalidBatch }
        guard !localIdentifiers.isEmpty else { return [] }
        let requested = Set(localIdentifiers)
        let before = try indexed(assetLoader(localIdentifiers), requested: requested)
        try checkContext(validateContext)
        guard !before.isEmpty else { return [] }
        let identities = try await cloudLoader(localIdentifiers.filter { before[$0] != nil })
        try checkContext(validateContext)
        guard Set(identities.keys).isSubset(of: requested) else { throw LocalMediaMetadataError.invalidBatch }
        let after = try indexed(assetLoader(localIdentifiers), requested: requested)
        try checkContext(validateContext)
        guard before == after else { throw LocalMediaMetadataError.sourceChanged }
        return localIdentifiers.compactMap { id in
            guard let snapshot = after[id] else { return nil }
            let resolution = identities[id] ?? .unavailable
            if case let .resolved(value) = resolution, !LocalMediaMobileMetadata.isUsableCloudID(value) {
                return snapshot.withCloudIdentity(.incomplete)
            }
            return snapshot.withCloudIdentity(resolution)
        }
    }

    /// values是实际元数据结果，requested为当前有限请求；重复/额外ID拒绝，不靠字典覆盖隐藏响应问题。
    private func indexed(_ values: [LocalPhotoSnapshot], requested: Set<String>) throws -> [String: LocalPhotoSnapshot] {
        let ids = values.map(\.identity.localIdentifier)
        guard ids.count == Set(ids).count, Set(ids).isSubset(of: requested) else { throw LocalMediaMetadataError.invalidBatch }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.identity.localIdentifier, $0) })
    }

    /// validate检查调用方代际；Task取消独立检查，任何失败都不返回旧账户/旧页面的关联结果。
    private func checkContext(_ validate: @MainActor () throws -> Void) throws {
        try Task.checkCancellation()
        try validate()
    }

    /// ids来自验证后的本地身份，返回公开元数据快照；不弹权限、不使用KVC/isCurrent/locallyAvailable或任何媒体数据请求。
    private static func readAssets(_ ids: [String]) throws -> [LocalPhotoSnapshot] {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { throw LocalMediaMetadataError.permission }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var snapshots: [LocalPhotoSnapshot] = []
        for index in 0 ..< assets.count {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            guard asset.mediaType == .image || asset.mediaType == .video else { continue }
            let kind: LocalPhotoIdentity.MediaKind = asset.mediaType == .video ? .video : asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .image
            let descriptors = PHAssetResource.assetResources(for: asset).map(resourceDescriptor).sorted(by: resourcePrecedes)
            snapshots.append(.init(identity: .init(localIdentifier: asset.localIdentifier, modificationDate: asset.modificationDate, mediaKind: kind),
                                   creationDate: asset.creationDate, adjustmentTime: asset.adjustmentTimestamp,
                                   hasAdjustments: asset.hasAdjustments, latitude: asset.location?.coordinate.latitude,
                                   longitude: asset.location?.coordinate.longitude, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                   duration: asset.duration, mediaSubtypes: asset.mediaSubtypes.rawValue,
                                   resources: descriptors, cloudIdentity: .unavailable))
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == authorization else { throw LocalMediaMetadataError.permission }
        return snapshots
    }

    /// resource为公开资源描述对象；保留类型/文件名/UTI/尺寸，不读取任何文件内容，也不选择某个资源作为current原片。
    private static func resourceDescriptor(_ resource: PHAssetResource) -> LocalPhotoResourceDescriptor {
        let role: LocalPhotoResourceDescriptor.Role = switch resource.type {
        case .photo: .originalPhoto
        case .video: .originalVideo
        case .pairedVideo: .pairedVideo
        case .alternatePhoto: .alternatePhoto
        case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo: .adjusted
        case .adjustmentData: .adjustmentData
        default: .other
        }
        return .init(type: resource.type.rawValue, role: role, originalFilename: resource.originalFilename,
                     uniformTypeIdentifier: resource.uniformTypeIdentifier, pixelWidth: resource.pixelWidth, pixelHeight: resource.pixelHeight)
    }

    /// lhs/rhs均来自同一公开资源列表；稳定排序仅避免PhotoKit枚举顺序差异，完全重复资源仍保留以观察形态。
    private static func resourcePrecedes(_ lhs: LocalPhotoResourceDescriptor, _ rhs: LocalPhotoResourceDescriptor) -> Bool {
        if lhs.type != rhs.type {
            return lhs.type < rhs.type
        }
        if lhs.originalFilename != rhs.originalFilename {
            return lhs.originalFilename < rhs.originalFilename
        }
        if lhs.uniformTypeIdentifier != rhs.uniformTypeIdentifier {
            return lhs.uniformTypeIdentifier < rhs.uniformTypeIdentifier
        }
        if lhs.pixelWidth != rhs.pixelWidth {
            return lhs.pixelWidth < rhs.pixelWidth
        }
        return lhs.pixelHeight < rhs.pixelHeight
    }
}

/// 同步映射可能昂贵，在并发执行器上只处理有限ID并返回Sendable值；不让PHAsset/PHCloudIdentifier跨Actor传递。
private nonisolated enum LocalPhotoCloudLookup {
    /// ids由上层限制为最多64项；公开API没有取消句柄，取消发生后只丢弃结果，不能宣称已中止系统元数据网络。
    @concurrent static func read(_ ids: [String]) async throws -> [String: LocalPhotoCloudIdentity] {
        try Task.checkCancellation()
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: ids)
        try Task.checkCancellation()
        var values: [String: LocalPhotoCloudIdentity] = [:]
        for id in ids {
            switch mappings[id] {
            case let .success(identifier)?:
                let value = identifier.stringValue
                values[id] = LocalMediaMobileMetadata.isUsableCloudID(value) ? .resolved(value) : .incomplete
            case .failure?: values[id] = .failed
            case nil: values[id] = .unavailable
            }
        }
        return values
    }
}
