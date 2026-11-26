import Foundation
import Photos
import Synchronization

/// 一次完整导出的临时原始资源；调用者负责清理directory，不将临时路径或文件字节写入持久队列。
nonisolated struct PhotoBackupResources: Sendable {
    /// file为私有临时文件，name为服务端保存的原始文件名；二者不能互相替代。
    struct File: Sendable { let file: URL; let name: String }
    let directory: URL
    let primary: File
    let motion: File?
    let created: Date
    let modified: Date
    let favorite: Bool
    let jpeg: File?

    /// rawJPEG时primary明确是RAW、jpeg是第二份原始图；旧媒体缺省nil，不挤占Live Photo motion字段。
    init(directory: URL, primary: File, motion: File?, created: Date, modified: Date, favorite: Bool, jpeg: File? = nil) {
        self.directory = directory; self.primary = primary; self.motion = motion
        self.created = created; self.modified = modified; self.favorite = favorite; self.jpeg = jpeg
    }
}

/// 两份导出前后的公开源观察；只有完整source/日期/收藏一致才发布临时文件，不跨Actor传PHAsset对象。
nonisolated struct PhotoBackupRawJPEGObservation: Equatable, Sendable {
    let source: PhotoBackupSource
    let created: Date
    let modified: Date
    let favorite: Bool
}

/// 双原图的系统读取窄端口；测试仅替换Photos元数据/字节读取，真实导出生命周期仍由Exporter执行。
@MainActor protocol PhotoBackupRawJPEGResourceReading: Sendable {
    /// source必须仍属于当前授权库及完整原始版本，失败抛安全分类；不读取媒体字节。
    func observe(_ source: PhotoBackupSource) throws -> PhotoBackupRawJPEGObservation
    /// role指定已分类原始成员，file是调用方新建私有路径；allowCloud只遵从当前用户确认，可取消实际读取。
    func read(_ role: PhotoBackupImageRole, source: PhotoBackupSource, file: URL, allowCloud: Bool) async throws
}

/// 导出边界只接受当前任务的源快照，不替换上传/判重；测试可用合成磁盘文件替代PhotoKit。
@MainActor protocol PhotoBackupResourceExporting: Sendable {
    /// source为扫描时版本，allowCloud只控制此次PhotoKit原片下载；返回完整资源或明确失败，取消必须结束实际读取。
    func export(_ source: PhotoBackupSource, allowCloud: Bool) async throws -> PhotoBackupResources
}

/// 导出失败以安全原因传递，避免将私人本地标识、路径或系统错误正文保存到队列。
nonisolated struct PhotoBackupExportError: Error, Sendable {
    let reason: PhotoBackupFailure
}

/// 重新从授权照片库读取原始照片/视频、Live Photo动态及明确的RAW+JPEG双图；不改原片，不猜复杂资源完整性。
@MainActor struct PhotoKitBackupResourceExporter: PhotoBackupResourceExporting {
    private let rawJPEGReader: any PhotoBackupRawJPEGResourceReading

    /// 默认真实公开PhotoKit；隔离测试仅注入系统观察/读取端口，不替换资源选择、导出或Worker。
    init(rawJPEGReader: any PhotoBackupRawJPEGResourceReading = PhotoKitBackupRawJPEGResourceReader()) {
        self.rawJPEGReader = rawJPEGReader
    }

    /// source必须仍可读且修改日期/媒体类型一致；下载选项每次从当前队列配置读取，不隐式允许iCloud。
    func export(_ source: PhotoBackupSource, allowCloud: Bool) async throws -> PhotoBackupResources {
        try Task.checkCancellation()
        if source.kind == .rawJPEG {
            return try await exportRawJPEG(source, allowCloud: allowCloud)
        }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { throw PhotoBackupExportError(reason: .permission) }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [source.localID], options: nil).firstObject else {
            throw PhotoBackupExportError(reason: .sourceMissing)
        }
        try validate(asset, against: source)
        let resources = PHAssetResource.assetResources(for: asset)
        let primaryType: PHAssetResourceType = source.kind == .video ? .video : .photo
        let primaries = resources.filter { $0.type == primaryType }
        let motions = resources.filter { $0.type == .pairedVideo }
        guard !resources.contains(where: { $0.type == .alternatePhoto }), primaries.count == 1,
              source.kind == .livePhoto ? motions.count == 1 : motions.isEmpty,
              let primary = primaries.first else { throw PhotoBackupExportError(reason: .unsupportedResources) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "RemmichBackup-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let file = try await exportResource(primary, directory: directory, allowCloud: allowCloud)
            let motion: PhotoBackupResources.File? = if let paired = motions.first {
                try await exportResource(paired, directory: directory, allowCloud: allowCloud)
            } else {
                nil
            }
            try Task.checkCancellation()
            // iCloud读取期间可能在其他应用编辑/删除资源；不能将两个不同版本拼成一个备份。
            guard let current = PHAsset.fetchAssets(withLocalIdentifiers: [source.localID], options: nil).firstObject else {
                throw PhotoBackupExportError(reason: .sourceMissing)
            }
            try validate(current, against: source)
            let created = asset.creationDate ?? asset.modificationDate ?? Date()
            return .init(directory: directory, primary: file, motion: motion, created: created,
                         modified: asset.modificationDate ?? created, favorite: asset.isFavorite)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 扫描只读取公开资源描述；仅明确无调整双原图升级source类型，其他复杂形状仍走原有明确拒绝路径。
    nonisolated static func source(for asset: PHAsset) -> PhotoBackupSource {
        let pair: PhotoBackupRawJPEGSource? = if asset.mediaType == .image, !asset.mediaSubtypes.contains(.photoLive),
                                                 let modified = asset.modificationDate, modified.timeIntervalSince1970.isFinite
        {
            try? rawJPEGSource(for: asset)
        } else {
            nil
        }
        return .init(localID: asset.localIdentifier, modifiedAt: asset.modificationDate,
                     kind: pair != nil ? .rawJPEG : asset.mediaType == .video ? .video : asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo,
                     rawJPEG: pair)
    }

    /// asset资源必须完整恰两份；公开type/UTI各自确认，不使用私有isCurrent或资源数组位置。
    fileprivate nonisolated static func rawJPEGSource(for asset: PHAsset) throws -> PhotoBackupRawJPEGSource {
        let values = PHAssetResource.assetResources(for: asset).map { resource in
            PhotoBackupOriginalImage(kind: resource.type == .photo ? .photo : resource.type == .alternatePhoto ? .alternatePhoto : .unsupported,
                                     uniformTypeIdentifier: resource.uniformTypeIdentifier, originalFilename: resource.originalFilename,
                                     pixelWidth: resource.pixelWidth, pixelHeight: resource.pixelHeight)
        }
        do { return try .init(originals: values, hasAdjustments: asset.hasAdjustments, adjustmentTime: asset.adjustmentTimestamp) }
        catch { throw PhotoBackupExportError(reason: .unsupportedResources) }
    }

    /// 两份必须完整导出且前后观察一致；任一失败回收整个临时目录，旧部分回执由持久队列保留。
    private func exportRawJPEG(_ source: PhotoBackupSource, allowCloud: Bool) async throws -> PhotoBackupResources {
        let before = try rawJPEGReader.observe(source)
        guard before.source == source, source.rawJPEG != nil else { throw PhotoBackupExportError(reason: .sourceChanged) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "RemmichBackup-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            guard let pair = source.rawJPEG else { throw PhotoBackupExportError(reason: .unsupportedResources) }
            let raw = directory.appending(path: "original-raw"); let jpeg = directory.appending(path: "original-jpeg")
            try await rawJPEGReader.read(.raw, source: source, file: raw, allowCloud: allowCloud)
            try Task.checkCancellation()
            try await rawJPEGReader.read(.jpeg, source: source, file: jpeg, allowCloud: allowCloud)
            try Task.checkCancellation()
            guard try rawJPEGReader.observe(source) == before else { throw PhotoBackupExportError(reason: .sourceChanged) }
            return .init(directory: directory, primary: .init(file: raw, name: pair.raw.originalFilename), motion: nil,
                         created: before.created, modified: before.modified, favorite: before.favorite,
                         jpeg: .init(file: jpeg, name: pair.jpeg.originalFilename))
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    /// asset为当前PhotoKit对象，source为扫描快照；仅同版本、同资源组合可继续本次任务。
    private func validate(_ asset: PHAsset, against source: PhotoBackupSource) throws {
        let kind: PhotoBackupSource.Kind = asset.mediaType == .video ? .video : asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo
        guard asset.mediaType == .image || asset.mediaType == .video, kind == source.kind,
              asset.modificationDate == source.modifiedAt else { throw PhotoBackupExportError(reason: .sourceChanged) }
    }

    /// resource为已检查的原始资源；目录为本任务私有目录。分块写盘并保留可取消的PhotoKit请求ID。
    private func exportResource(_ resource: PHAssetResource, directory: URL, allowCloud: Bool) async throws -> PhotoBackupResources.File {
        try Task.checkCancellation()
        let file = directory.appending(path: UUID().uuidString).appendingPathExtension((resource.originalFilename as NSString).pathExtension)
        let writer = try PhotoBackupResourceFileWriter(file: file)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowCloud
        try await writer.read(resource, options: options)
        try Task.checkCancellation()
        return .init(file: file, name: resource.originalFilename)
    }
}

/// 默认双原图系统适配；每次请求重新取授权PHAsset并对完整描述，沿用真正可取消的流式原始资源writer。
@MainActor struct PhotoKitBackupRawJPEGResourceReader: PhotoBackupRawJPEGResourceReading {
    /// 只接受有限且已冻结的修改版本；缺失版本/Photos调整/成员变化不能被当成完整原始组合。
    func observe(_ source: PhotoBackupSource) throws -> PhotoBackupRawJPEGObservation {
        let asset = try asset(for: source)
        guard let modified = asset.modificationDate else { throw PhotoBackupExportError(reason: .sourceChanged) }
        return .init(source: source, created: asset.creationDate ?? modified, modified: modified, favorite: asset.isFavorite)
    }

    /// 每份读取前复核相同原始资源，读取后由Exporter独立observe再次复核；不请求缩略图/渲染图或覆盖原片。
    func read(_ role: PhotoBackupImageRole, source: PhotoBackupSource, file: URL, allowCloud: Bool) async throws {
        let asset = try asset(for: source)
        guard let pair = source.rawJPEG else { throw PhotoBackupExportError(reason: .unsupportedResources) }
        let expected = role == .raw ? pair.raw : pair.jpeg
        let candidates = PHAssetResource.assetResources(for: asset).filter {
            $0.uniformTypeIdentifier == expected.uniformTypeIdentifier && $0.originalFilename == expected.originalFilename
                && $0.pixelWidth == expected.pixelWidth && $0.pixelHeight == expected.pixelHeight
                && $0.type == (expected.kind == .photo ? .photo : .alternatePhoto)
        }
        guard candidates.count == 1, let resource = candidates.first else { throw PhotoBackupExportError(reason: .sourceChanged) }
        let writer = try PhotoBackupResourceFileWriter(file: file)
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowCloud
        try await writer.read(resource, options: options)
    }

    /// Task与权限均即时检查；相同localID必须仍是相同的非Live、无调整双图完整快照。
    private func asset(for source: PhotoBackupSource) throws -> PHAsset {
        try Task.checkCancellation()
        let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard permission == .authorized || permission == .limited else { throw PhotoBackupExportError(reason: .permission) }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [source.localID], options: nil).firstObject else {
            throw PhotoBackupExportError(reason: .sourceMissing)
        }
        guard let modified = source.modifiedAt, modified.timeIntervalSince1970.isFinite,
              source.kind == .rawJPEG, asset.mediaType == .image, !asset.mediaSubtypes.contains(.photoLive),
              PhotoKitBackupResourceExporter.source(for: asset) == source else { throw PhotoBackupExportError(reason: .sourceChanged) }
        return asset
    }
}

/// PhotoKit回调可能跨线程；Mutex保护文件、continuation及请求ID安装，确保取消/完成只释放一次。
/// requestData提供cancelDataRequest所需ID；writeData没有可用ID，无法满足中途停止iCloud读取的要求。
private final nonisolated class PhotoBackupResourceFileWriter: @unchecked Sendable {
    /// 文件句柄与完成权只在锁内变更；cancel可早于continuation或PhotoKit请求ID的安装。
    private struct State {
        var handle: FileHandle?
        var continuation: CheckedContinuation<Void, any Error>?
        var requestID: PHAssetResourceDataRequestID?
        var finished = false
        var cancelled = false
        var writeFailure: (any Error)?
    }

    private let state: Mutex<State>
    private let manager = PHAssetResourceManager.default()

    /// file必须是新的私有临时路径；无法创建/打开时失败，不覆盖已有文件。
    init(file: URL) throws {
        guard !FileManager.default.fileExists(atPath: file.path),
              FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteFileExists) }
        state = try Mutex(State(handle: FileHandle(forWritingTo: file)))
    }

    /// resource/options只在主Actor内交给PhotoKit；后台回调仅持有本线程安全writer，不传递PHAsset对象。
    @MainActor func read(_ resource: PHAssetResource, options: PHAssetResourceRequestOptions) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let mayStart = state.withLock { value in
                    guard !value.cancelled else { return false }
                    value.continuation = continuation
                    return true
                }
                guard mayStart else { continuation.resume(throwing: CancellationError()); return }
                let requestID = manager.requestData(for: resource, options: options, dataReceivedHandler: { [self] data in
                    write(data)
                }, completionHandler: { [self] error in
                    finish(error)
                })
                let mustCancel = state.withLock { value in
                    value.requestID = requestID
                    return value.cancelled || value.finished
                }
                // cancel可能发生在requestData已启动、返回ID尚未安装的窗口，安装后仍必须取消实际请求。
                if mustCancel {
                    manager.cancelDataRequest(requestID)
                }
            }
        } onCancel: { [self] in cancel() }
    }

    /// data为PhotoKit当前分块；写失败立即终结并取消余下资源读取，绝不累积整个视频到内存。
    private func write(_ data: Data) {
        let failure: (any Error)? = state.withLock { value in
            guard !value.finished, let handle = value.handle else { return nil }
            do { try handle.write(contentsOf: data); return nil } catch { value.writeFailure = error; return error }
        }
        if let failure {
            finish(failure)
            if let id = state.withLock({ $0.requestID }) {
                manager.cancelDataRequest(id)
            }
        }
    }

    /// error为PhotoKit/写盘结果；仅首个完成事件关闭句柄和恢复continuation，晚回调不再访问文件。
    private func finish(_ error: (any Error)?) {
        let result: (CheckedContinuation<Void, any Error>?, (any Error)?) = state.withLock { value in
            guard !value.finished else { return (nil, nil) }
            value.finished = true
            var failure = value.writeFailure ?? error
            do { try value.handle?.close() } catch {
                if failure == nil {
                    failure = error
                }
            }
            value.handle = nil
            let continuation = value.continuation
            value.continuation = nil
            return (continuation, failure)
        }
        if let error = result.1 {
            result.0?.resume(throwing: error)
        } else {
            result.0?.resume()
        }
    }

    /// Task取消既恢复等待者也终止PhotoKit请求；若ID尚未返回，read安装ID时补做真实取消。
    private func cancel() {
        let id = state.withLock { value in value.cancelled = true; return value.requestID }
        finish(CancellationError())
        if let id {
            manager.cancelDataRequest(id)
        }
    }
}
