import CryptoKit
import Foundation

/// 热循环只读一项/写一项；扫描及界面冷快照不进入这个接口，避免每个检查点遍历完整历史。
nonisolated protocol PhotoBackupWorkStoring: Sendable {
    /// scope为已认证账号；返回按扫描顺序排列的下一项，不隐式claim或恢复暂停项。
    func nextQueuedPhotoBackup(scope: MediaAccountScope) async throws -> PhotoBackupJob?
    /// job必须已经由显式扫描创建，成功落盘后才能进行下一外部副作用。
    func savePhotoBackupJob(_ job: PhotoBackupJob, scope: MediaAccountScope) async throws
    /// 停止当前账号的排队及执行中项目，保留回执，不自动回滚远端上传。
    func pausePhotoBackupWork(scope: MediaAccountScope) async throws
}

extension SQLiteLibraryIndexStore: PhotoBackupWorkStoring {}

/// 官方上传/回读的窄边界；真实实现继续使用LibraryMutationClient判重、磁盘multipart和鉴权规则。
nonisolated protocol PhotoBackupUploading: Sendable {
    /// 参数沿用官方上传语义，hidden仅用于Live Photo动态资源，livePhotoVideoID只引用已确认的动态资源。
    func upload(file: URL, filename: String, created: Date, modified: Date, favorite: Bool,
                hidden: Bool, livePhotoVideoID: String?) async throws -> LibraryMutationClient.UploadResult
    /// id为已确认主体；回读必须核对身份、拥有者、回收站及必要Live Photo配对。
    func asset(_ id: String) async throws -> ManagedAsset
}

extension LibraryMutationClient: PhotoBackupUploading {}

/// 单次前台执行结果只含计数；未知结果和已发送但未确认的资源不会算作成功。
nonisolated struct PhotoBackupRunResult: Sendable {
    var completed = 0
    var duplicates = 0
    var failed = 0
    var skipped = 0
    var review = 0
    var stopped = false
}

/// 串行执行持久队列的一个前台周期；不持有全量历史、不做定时重试，账号发布权由调用者的validateContext决定。
@MainActor final class PhotoBackupWorker {
    private let store: any PhotoBackupWorkStoring
    private let exporter: any PhotoBackupResourceExporting

    /// store只提供持久检查点，exporter负责重新读取当前源；二者均可由测试提供独立的合成实现。
    init(store: any PhotoBackupWorkStoring, exporter: any PhotoBackupResourceExporting) {
        self.store = store
        self.exporter = exporter
    }

    /// scope/userID固定为本轮认证身份，allowCloud固定为用户此次确认的选择；validateContext在每次await前后检查代际。
    /// preflight为Controller整批核查的完整许可；nil仅保留低层独立Worker测试入口，产品Controller始终提供计划。
    /// progress只发布当前任务及安全计数；调用者仍须检查代际。取消、存储错误或未知上传结果停止后续自动上传。
    func run(scope: MediaAccountScope, userID: String, allowCloud: Bool, client: any PhotoBackupUploading,
             preflight: PhotoBackupPreflightPlan? = nil,
             validateContext: @MainActor () throws -> Void,
             progress: @MainActor (PhotoBackupJob, PhotoBackupRunResult) -> Void) async throws -> PhotoBackupRunResult
    {
        var result = PhotoBackupRunResult()
        do {
            while true {
                try checkContext(validateContext)
                guard var job = try await store.nextQueuedPhotoBackup(scope: scope) else { break }
                try checkContext(validateContext)
                if let preflight, !preflight.allowed.contains(job.source) {
                    // 服务器已有项持久保存为已匹配；不伪造上传回执，未知历史仍待核查，均不进入Exporter。
                    if preflight.existing.contains(job.source) {
                        try job.confirmExistingMatch()
                    } else {
                        job.fail(.historyNeedsReview)
                    }
                    try await checkpoint(job, scope: scope, validateContext: validateContext)
                    if preflight.existing.contains(job.source) {
                        result.skipped += 1
                    } else {
                        result.review += 1
                    }
                    progress(job, result)
                    continue
                }
                try job.begin()
                try await checkpoint(job, scope: scope, validateContext: validateContext)
                progress(job, result)
                do {
                    let resources = try await exporter.export(job.source, allowCloud: allowCloud)
                    defer { try? FileManager.default.removeItem(at: resources.directory) }
                    try checkContext(validateContext)
                    guard (job.source.kind == .livePhoto) == (resources.motion != nil), (job.source.kind == .rawJPEG) == (resources.jpeg != nil) else {
                        throw PhotoBackupExportError(reason: .unsupportedResources)
                    }
                    try job.exported()
                    try await checkpoint(job, scope: scope, validateContext: validateContext)
                    if job.source.kind == .rawJPEG {
                        try await uploadImages(&job, resources: resources, scope: scope, userID: userID, client: client, validateContext: validateContext)
                    } else {
                        if let motion = resources.motion {
                            let receipt = try await client.upload(file: motion.file, filename: motion.name, created: resources.created,
                                                                  modified: resources.modified, favorite: false, hidden: true, livePhotoVideoID: nil)
                            try checkContext(validateContext)
                            guard let id = UUID(uuidString: receipt.id), ["created", "duplicate"].contains(receipt.status) else {
                                throw LibraryWriteError.malformedResponse
                            }
                            try job.recordMotion(id)
                            try await checkpoint(job, scope: scope, validateContext: validateContext)
                        }
                        let primary = try await client.upload(file: resources.primary.file, filename: resources.primary.name,
                                                              created: resources.created, modified: resources.modified, favorite: resources.favorite,
                                                              hidden: false, livePhotoVideoID: job.motionAssetID?.uuidString)
                        try checkContext(validateContext)
                        guard let primaryID = UUID(uuidString: primary.id), ["created", "duplicate"].contains(primary.status) else {
                            throw LibraryWriteError.malformedResponse
                        }
                        try job.recordPrimary(primaryID, duplicate: primary.status == "duplicate", checksum: primary.checksum)
                        try await checkpoint(job, scope: scope, validateContext: validateContext)
                        // created与duplicate都回读真实主体；部分Live Photo回执永远不能替代最终配对核对。
                        let confirmed = try await client.asset(primaryID.uuidString)
                        try checkContext(validateContext)
                        guard UUID(uuidString: confirmed.id) == primaryID, confirmed.ownerId == userID, !confirmed.isTrashed,
                              confirmed.type == (job.source.kind == .video ? "VIDEO" : "IMAGE")
                        else {
                            throw LibraryWriteError.malformedResponse
                        }
                        if job.source.kind == .livePhoto {
                            guard let motionID = job.motionAssetID,
                                  confirmed.livePhotoVideoId.flatMap(UUID.init(uuidString:)) == motionID
                            else {
                                throw PhotoBackupExportError(reason: .livePhotoMismatch)
                            }
                            // 主体关联不代表动态资源当前仍可用；完成前独立fresh回读，保留verifying检查点。
                            let motion = try await client.asset(motionID.uuidString)
                            try checkContext(validateContext)
                            guard UUID(uuidString: motion.id) == motionID, motion.ownerId == userID,
                                  motion.type == "VIDEO", !motion.isTrashed
                            else {
                                throw LibraryWriteError.malformedResponse
                            }
                            // 既有动态视频可能归档，不强制hidden；两次读取之间仍没有服务端CAS/原子快照。
                        }
                        try job.confirmVerifiedReceipt()
                    }
                    try await checkpoint(job, scope: scope, validateContext: validateContext)
                    result.completed += 1
                    let duplicate = job.source.kind == .rawJPEG ? job.rawReceipt?.duplicate == true && job.jpegReceipt?.duplicate == true : job.primaryWasDuplicate
                    if duplicate {
                        result.duplicates += 1
                    }
                    progress(job, result)
                } catch {
                    if error is PhotoBackupPersistenceError {
                        throw error
                    }
                    // 旧代际即使收到真实成功也不得落盘或发布；新一轮会把中断中的状态恢复为暂停。
                    try checkContext(validateContext)
                    let failure = Self.failure(for: error)
                    job.fail(failure)
                    try await checkpoint(job, scope: scope, validateContext: validateContext)
                    result.failed += 1
                    progress(job, result)
                    if Self.requiresStop(failure) {
                        result.stopped = true
                        try await store.pausePhotoBackupWork(scope: scope)
                        try checkContext(validateContext)
                        break
                    }
                }
            }
            return result
        } catch {
            // 用户停止时Task已取消，但仍须保存暂停；代际已变则不能用旧任务暂停新账号/新会话工作。
            if (try? validateContext()) != nil {
                try await store.pausePhotoBackupWork(scope: scope)
            }
            throw error
        }
    }

    /// RAW/JPEG每份都经完整字节摘要、现有upload内查重及独立fresh确认后落盘；旧UUID绝不跳过当前尝试。
    /// resources来自完整导出，scope/userID/context固定；第二份失败保留第一份回执，不删除远端或自动重发。
    private func uploadImages(_ job: inout PhotoBackupJob, resources: PhotoBackupResources, scope: MediaAccountScope,
                              userID: String, client: any PhotoBackupUploading, validateContext: @MainActor () throws -> Void) async throws
    {
        guard let pair = job.source.rawJPEG, let jpeg = resources.jpeg, resources.motion == nil,
              resources.primary.name == pair.raw.originalFilename, jpeg.name == pair.jpeg.originalFilename
        else {
            throw PhotoBackupExportError(reason: .unsupportedResources)
        }
        for (role, file) in [(PhotoBackupImageRole.raw, resources.primary), (.jpeg, jpeg)] {
            try checkContext(validateContext)
            let checksum = try await Self.originalChecksum(file.file)
            try checkContext(validateContext)
            let uploaded = try await client.upload(file: file.file, filename: file.name, created: resources.created,
                                                   modified: resources.modified, favorite: resources.favorite, hidden: false, livePhotoVideoID: nil)
            try checkContext(validateContext)
            guard let id = UUID(uuidString: uploaded.id), ["created", "duplicate"].contains(uploaded.status) else {
                throw LibraryWriteError.malformedResponse
            }
            let receipt = PhotoBackupImageReceipt(assetID: id, checksum: checksum, duplicate: uploaded.status == "duplicate")
            let asset = try await client.asset(id.uuidString)
            try checkContext(validateContext)
            try Self.verifyImage(asset, receipt: receipt, userID: userID)
            try job.recordImage(receipt, role: role)
            try await checkpoint(job, scope: scope, validateContext: validateContext)
        }
        try job.imagesUploaded()
        try await checkpoint(job, scope: scope, validateContext: validateContext)
        // 第一份确认后仍可能被回收/删除；整组完成前再分别fresh读取，不能把先前部分确认当成最终快照。
        guard let raw = job.rawReceipt, let jpeg = job.jpegReceipt else { throw LibraryWriteError.malformedResponse }
        for receipt in [raw, jpeg] {
            let asset = try await client.asset(receipt.assetID.uuidString)
            try checkContext(validateContext)
            try Self.verifyImage(asset, receipt: receipt, userID: userID)
        }
        try job.confirmVerifiedImages()
    }

    /// 独立fresh资产必须精确对应实际文件SHA1、账号及IMAGE身份且明确在线；缺checksum/isOffline也不能确认。
    private static func verifyImage(_ asset: ManagedAsset, receipt: PhotoBackupImageReceipt, userID: String) throws {
        guard UUID(uuidString: asset.id) == receipt.assetID, asset.ownerId == userID, asset.type == "IMAGE", !asset.isTrashed,
              asset.checksum == receipt.checksum, asset.isOffline == false else { throw LibraryWriteError.malformedResponse }
    }

    /// 从完整私有临时文件流式SHA1，不占主Actor、不接受空文件；当前Task取消在每块读取前传播。
    @concurrent private static func originalChecksum(_ file: URL) async throws -> String {
        var hash = Insecure.SHA1(); var count: Int64 = 0
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            hash.update(data: data); count += Int64(data.count)
        }
        guard count > 0 else { throw PhotoBackupExportError(reason: .unsupportedResources) }
        return Data(hash.finalize()).base64EncodedString()
    }

    /// job为当前唯一执行项；存储失败必须逃出循环，不能继续上传或用失败状态覆盖未知持久结果。
    private func checkpoint(_ job: PhotoBackupJob, scope: MediaAccountScope, validateContext: @MainActor () throws -> Void) async throws {
        try checkContext(validateContext)
        do { try await store.savePhotoBackupJob(job, scope: scope) }
        catch { throw PhotoBackupPersistenceError(underlying: error) }
        try checkContext(validateContext)
    }

    /// validate只验证账号/端点发布权；Task取消另行检查，以便取消清理仍可保存当前账号的暂停状态。
    private func checkContext(_ validate: @MainActor () throws -> Void) throws {
        try Task.checkCancellation()
        try validate()
    }

    /// error仅转为安全分类；不持久化HTTP正文、设备标识或路径。
    private static func failure(for error: any Error) -> PhotoBackupFailure {
        if let error = error as? PhotoBackupExportError {
            return error.reason
        }
        if let error = error as? URLError {
            // 只有短暂连接失败可进入独立同意的网络重核；超时也可能已提交，仍须完整查重，绝不直接重POST。
            switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
                return .network
            case .userAuthenticationRequired, .userCancelledAuthentication, .clientCertificateRejected, .clientCertificateRequired:
                return .permission
            default:
                return .unconfirmedResponse
            }
        }
        if let error = error as? LibraryWriteError {
            switch error {
            case .http(401), .http(403): return .permission
            case .unavailable, .changedAccount: return .unavailable
            default: return .unconfirmedResponse
            }
        }
        return .unconfirmedResponse
    }

    /// 本地单项缺失/版本变更/不支持可以继续下一项；网络、权限及未知回执需用户处理后明确恢复。
    private static func requiresStop(_ failure: PhotoBackupFailure) -> Bool {
        switch failure {
        case .sourceMissing, .sourceChanged, .unsupportedResources: false
        default: true
        }
    }
}

/// 持久检查点失败与网络/资源失败分开传播；不能再尝试覆盖该任务状态或继续上传下一项。
private nonisolated struct PhotoBackupPersistenceError: Error {
    let underlying: any Error
}

/// 同账号所有前台备份入口共用退役屏障；新窗口/快速切回同账号必须等待旧任务完成取消和暂停落盘。
@MainActor enum PhotoBackupRunCoordinator {
    /// 取消操作与完整退役屏障分开保留；泛型返回值不进入全局字典，完成后及时释放任务捕获。
    private struct Active {
        let id: UUID
        let cancel: @MainActor () -> Void
        let retired: Task<Void, Never>
    }

    private static var active: [String: Active] = [:]

    /// scope绑定持久namespace；operation在前一操作完全退役后执行。调用Task取消必须传递给真实执行Task。
    /// 该屏障也用于恢复/扫描/单项重试，防止它们与正在落盘的上传检查点互相覆盖。
    static func perform<Value: Sendable>(scope: MediaAccountScope, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let namespace = scope.cacheNamespace
        let previous = active[namespace]
        previous?.cancel()
        let id = UUID()
        let task = Task {
            await previous?.retired.value
            try Task.checkCancellation()
            return try await operation()
        }
        let retired = Task { _ = await task.result }
        active[namespace] = .init(id: id, cancel: { task.cancel() }, retired: retired)
        defer {
            if active[namespace]?.id == id {
                active.removeValue(forKey: namespace)
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
