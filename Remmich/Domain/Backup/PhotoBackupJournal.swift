import Foundation

/// 备份源的稳定快照；localID只在当前手机照片库内有效，修改版本变化后必须成为新的任务。
nonisolated struct PhotoBackupSource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case photo, video, livePhoto }
    let localID: String
    let modifiedAt: Date?
    let kind: Kind
}

/// 备份失败的可持久化原因，不保存token、原始HTTP响应或私人文件路径。
nonisolated enum PhotoBackupFailure: String, Codable, Sendable {
    case interrupted, sourceMissing, sourceChanged, unsupportedResources, permission, network
    case livePhotoMismatch, unconfirmedResponse, unavailable, storage

    /// 返回安全可展示的原因；中断/网络错误也必须经用户明确恢复后再查重。
    var message: String {
        switch self {
        case .interrupted: "The previous operation was interrupted. Resume will check server duplicates before retrying."
        case .sourceMissing: "The source is no longer available in the authorized photo library."
        case .sourceChanged: "The source changed. Scan the selected albums again before uploading this version."
        case .unsupportedResources: "This resource combination cannot be confirmed as a complete backup."
        case .permission: "Photo or server permission is required."
        case .network: "The connection failed. Resume to check duplicates and retry."
        case .livePhotoMismatch: "The existing still image does not have the expected Live Photo pairing."
        case .unconfirmedResponse: "The server did not confirm the complete backup. Reload before retrying."
        case .unavailable: "The account or endpoint is unavailable."
        case .storage: "The backup state could not be saved. No new upload will start."
        }
    }
}

/// 非法转换或损坏日志必须显式失败，不能以空队列覆盖已有恢复资料。
nonisolated enum PhotoBackupStateError: Error, Equatable, Sendable {
    case invalidTransition, invalidJournal
}

/// 单个原片/视频/Live Photo逻辑任务；只有全部资源和配对已确认才可完成。
nonisolated struct PhotoBackupJob: Codable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable {
        case queued, exporting, uploadingMotion, uploadingPrimary, verifying, paused, failed, cancelled, completed

        /// 进程退出后这些状态都不是成功；冷恢复必须暂停，等待重新验证。
        var isInFlight: Bool {
            switch self {
            case .exporting, .uploadingMotion, .uploadingPrimary, .verifying: true
            default: false
            }
        }
    }

    let id: UUID
    let source: PhotoBackupSource
    private(set) var stage: Stage
    private(set) var attempts: Int
    private(set) var motionAssetID: UUID?
    private(set) var primaryAssetID: UUID?
    private(set) var primaryWasDuplicate: Bool
    private(set) var failure: PhotoBackupFailure?

    /// source为用户明确选中的当前版本；id为本地任务身份，不作为服务端资产ID使用。
    init(source: PhotoBackupSource, id: UUID = UUID()) {
        self.id = id
        self.source = source
        stage = .queued
        attempts = 0
        primaryWasDuplicate = false
    }

    /// 只验证当前任务的持久化不变量，供单项检查点使用；不把回执存在等同于已完成服务器验证。
    func validate() throws {
        guard !source.localID.isEmpty, attempts >= 0,
              motionAssetID == nil || source.kind == .livePhoto,
              stage != .completed || (primaryAssetID != nil && (source.kind != .livePhoto || motionAssetID != nil))
        else { throw PhotoBackupStateError.invalidJournal }
    }

    /// 仅queued可开始；调用者须先持久化该转换，再读取PhotoKit或发HTTP。
    mutating func begin() throws {
        guard stage == .queued else { throw PhotoBackupStateError.invalidTransition }
        stage = .exporting
        attempts += 1
        failure = nil
    }

    /// 导出已完整验证当前源；Live Photo先传动态资源，其他类型直接传原始主体。
    mutating func exported() throws {
        guard stage == .exporting else { throw PhotoBackupStateError.invalidTransition }
        stage = source.kind == .livePhoto ? .uploadingMotion : .uploadingPrimary
    }

    /// assetID为服务器已确认的动态资源；持久化后才允许提交引用它的静态帧。
    mutating func recordMotion(_ assetID: UUID) throws {
        guard source.kind == .livePhoto, stage == .uploadingMotion else { throw PhotoBackupStateError.invalidTransition }
        motionAssetID = assetID
        stage = .uploadingPrimary
    }

    /// assetID/duplicate为已确认主体回执；尚不代表Live Photo配对已核对。
    mutating func recordPrimary(_ assetID: UUID, duplicate: Bool) throws {
        guard stage == .uploadingPrimary, source.kind != .livePhoto || motionAssetID != nil else { throw PhotoBackupStateError.invalidTransition }
        primaryAssetID = assetID
        primaryWasDuplicate = duplicate
        stage = .verifying
    }

    /// 调用者已通过真实上传回执及必要的静态帧关联读取确认完整性；单独动态资源永不算完成。
    mutating func confirmVerifiedReceipt() throws {
        guard stage == .verifying, primaryAssetID != nil,
              source.kind != .livePhoto || motionAssetID != nil else { throw PhotoBackupStateError.invalidTransition }
        stage = .completed
        failure = nil
    }

    /// 暂停未完成任务并保留所有已确认回执；完成/取消历史不因页面退出被改写。
    mutating func pause() {
        guard stage != .completed, stage != .cancelled, stage != .failed else { return }
        failure = stage.isInFlight ? .interrupted : nil
        stage = .paused
    }

    /// reason为安全错误分类；只标记尚未完成的当前操作，不删除已上传的服务端资源。
    mutating func fail(_ reason: PhotoBackupFailure) {
        guard stage != .completed, stage != .cancelled else { return }
        stage = .failed
        failure = reason
    }

    /// 取消只停止本地任务；未确认的远端写入可能已发生，之后显式重试仍需查重。
    mutating func cancel() {
        guard stage != .completed else { return }
        failure = stage.isInFlight ? .interrupted : nil
        stage = .cancelled
    }

    /// 用户明确恢复/重试，或明确新一轮相簿扫描要求重新查重；回执保留但不可用来跳过验证。
    mutating func queueForVerification() {
        guard !stage.isInFlight else { return }
        stage = .queued
        failure = nil
    }

    /// 只用于日志冷恢复，不会自动重发任何上传。
    mutating func recoverInterrupted() {
        guard stage.isInFlight else { return }
        stage = .paused
        failure = .interrupted
    }
}

/// 当前账号的备份日志；不含凭据/文件字节，资源在真正执行时从授权PhotoKit重新读取。
nonisolated struct PhotoBackupJournal: Codable, Sendable {
    /// 不含任务数组的日志头；热路径只检查版本/账号，完整任务由SQLite独立行保存。
    nonisolated struct Header: Codable, Sendable {
        let version: Int
        let namespace: String
        let selectedAlbumIDs: [String]
        let allowCloud: Bool
        let excludedAlbumIDs: [String]?

        /// version/namespace保留恢复格式与账号边界；excludedAlbumIDs缺省nil兼容旧格式，不用存储属性默认值遮蔽解码。
        init(version: Int, namespace: String, selectedAlbumIDs: [String], allowCloud: Bool, excludedAlbumIDs: [String]? = nil) {
            self.version = version
            self.namespace = namespace
            self.selectedAlbumIDs = selectedAlbumIDs
            self.allowCloud = allowCloud
            self.excludedAlbumIDs = excludedAlbumIDs
        }

        /// expected来自当前认证scope；未知格式或跨账号日志必须保留并报错，不能被热写覆盖。
        func validate(namespace expected: String) throws {
            let exclusions = excludedAlbumIDs ?? []
            let validIncludes = !selectedAlbumIDs.isEmpty && selectedAlbumIDs.allSatisfy { !$0.isEmpty }
                && Set(selectedAlbumIDs).count == selectedAlbumIDs.count
            guard [1, 2].contains(version), namespace == expected,
                  exclusions.allSatisfy({ !$0.isEmpty }), Set(exclusions).count == exclusions.count,
                  version == 1 ? exclusions.isEmpty : excludedAlbumIDs != nil && validIncludes else { throw PhotoBackupStateError.invalidJournal }
        }
    }

    private(set) var version: Int
    let namespace: String
    var selectedAlbumIDs: [String]
    var allowCloud: Bool
    private(set) var excludedAlbumIDs: [String]?
    private(set) var jobs: [PhotoBackupJob]

    /// namespace来自已认证MediaAccountScope；日志仅属于该账号，不使用email或设备相簿名推断身份。
    init(namespace: String) {
        version = 1
        self.namespace = namespace
        selectedAlbumIDs = []
        allowCloud = false
        excludedAlbumIDs = nil
        jobs = []
    }

    /// 从独立日志头与按扫描顺序读取的任务重建冷快照；调用方随后验证当前scope及完整集合。
    init(header: Header, jobs: [PhotoBackupJob]) {
        version = header.version
        namespace = header.namespace
        selectedAlbumIDs = header.selectedAlbumIDs
        allowCloud = header.allowCloud
        excludedAlbumIDs = header.excludedAlbumIDs
        self.jobs = jobs
    }

    /// 返回不随任务数增长的日志头；选择相簿列表仅在明确扫描时整体更新。
    var header: Header {
        .init(version: version, namespace: namespace, selectedAlbumIDs: selectedAlbumIDs, allowCloud: allowCloud, excludedAlbumIDs: excludedAlbumIDs)
    }

    /// scan已验证完整包含/排除集合，allowCloud来自本轮用户选择；原子保存前取消不再属于本轮选择的未完成项。
    /// 首次启用排除升级到格式2，让旧版本明确拒绝而非忽略规则后上传；清空规则也不自动降级格式。
    @discardableResult mutating func applyAlbumScan(_ scan: PhotoBackupAlbumScan, allowCloud: Bool) throws -> Int {
        try validate(namespace: namespace)
        guard !jobs.contains(where: \.stage.isInFlight) else { throw PhotoBackupStateError.invalidTransition }
        guard scan.selection.included.union(scan.selection.excluded).allSatisfy({ !$0.isEmpty }) else {
            throw PhotoBackupStateError.invalidJournal
        }
        selectedAlbumIDs = scan.selection.included.sorted()
        if !scan.selection.excluded.isEmpty {
            version = 2
        }
        excludedAlbumIDs = version == 1 ? nil : scan.selection.excluded.sorted()
        self.allowCloud = allowCloud
        let eligibleSources = Set(scan.sources)
        for index in jobs.indices where !eligibleSources.contains(jobs[index].source) {
            jobs[index].cancel()
        }
        return try enqueue(scan.sources)
    }

    /// expected为当前认证账号namespace；拒绝跨账号、未知版本或重复任务ID的日志，不静默清空。
    func validate(namespace expected: String) throws {
        try header.validate(namespace: expected)
        guard Set(jobs.map(\.id)).count == jobs.count,
              Set(jobs.map(\.source)).count == jobs.count else { throw PhotoBackupStateError.invalidJournal }
        for job in jobs {
            try job.validate()
        }
    }

    /// sources为一次明确扫描的去重源快照；同版本完成项也重新查重，不能假定服务器永远保留旧备份。
    /// 返回本次新建/重排任务数；旧版本未完成任务取消，避免把不同版本资源拼成Live Photo。
    @discardableResult mutating func enqueue(_ sources: [PhotoBackupSource]) throws -> Int {
        let groups = Dictionary(grouping: sources, by: \.localID)
        guard groups.allSatisfy({ !$0.key.isEmpty && Set($0.value).count == 1 }) else { throw PhotoBackupStateError.invalidJournal }
        var indexesByLocalID: [String: [Int]] = [:]
        var indexBySource: [PhotoBackupSource: Int] = [:]
        for (index, job) in jobs.enumerated() {
            indexesByLocalID[job.source.localID, default: []].append(index)
            indexBySource[job.source] = index
        }
        // 保留调用方按拍摄时间给定的顺序；索引避免全相簿扫描时为每项遍历整个历史。
        var seen = Set<PhotoBackupSource>()
        var count = 0
        for source in sources where seen.insert(source).inserted {
            for index in indexesByLocalID[source.localID] ?? [] where jobs[index].source != source && jobs[index].stage != .completed {
                jobs[index].cancel()
            }
            if let index = indexBySource[source] {
                guard !jobs[index].stage.isInFlight else { continue }
                jobs[index].queueForVerification()
            } else {
                indexesByLocalID[source.localID, default: []].append(jobs.count)
                indexBySource[source] = jobs.count
                jobs.append(.init(source: source))
            }
            count += 1
        }
        return count
    }

    /// id为已存在任务，change仅修改该任务；持久化由调用方在执行任何外部副作用前完成。
    mutating func update(_ id: UUID, _ change: (inout PhotoBackupJob) throws -> Void) throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw PhotoBackupStateError.invalidTransition }
        try change(&jobs[index])
    }

    /// id为nil时明确恢复可重试项；指定id时只运行这一项，其他queued暂停，避免单项重试隐式启动整队。
    /// 单次线性转换供显式恢复使用，不进入逐项上传热循环；完成/取消历史保持不动。
    mutating func resumeForVerification(only id: UUID? = nil) throws {
        if let id {
            guard jobs.contains(where: { $0.id == id && [.queued, .paused, .failed].contains($0.stage) }) else {
                throw PhotoBackupStateError.invalidTransition
            }
        }
        for index in jobs.indices {
            if id == nil || jobs[index].id == id {
                if [.queued, .paused, .failed].contains(jobs[index].stage) {
                    jobs[index].queueForVerification()
                }
            } else if jobs[index].stage == .queued {
                jobs[index].pause()
            }
        }
    }

    /// 进程中断后恢复为可明确继续的暂停状态；已完成/失败/取消保持原样。
    mutating func recoverInterrupted() {
        for index in jobs.indices {
            jobs[index].recoverInterrupted()
        }
    }
}
