import Foundation

/// 备份源的稳定快照；localID只在当前手机照片库内有效，修改版本变化后必须成为新的任务。
nonisolated struct PhotoBackupSource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case photo, video, livePhoto, rawJPEG }
    let localID: String
    let modifiedAt: Date?
    let kind: Kind
    let rawJPEG: PhotoBackupRawJPEGSource?

    /// rawJPEG仅用于已明确识别的双原始静态图；默认nil保留旧照片/视频/Live Photo构造及解码兼容。
    init(localID: String, modifiedAt: Date?, kind: Kind, rawJPEG: PhotoBackupRawJPEGSource? = nil) {
        self.localID = localID; self.modifiedAt = modifiedAt; self.kind = kind; self.rawJPEG = rawJPEG
    }
}

/// 备份失败的可持久化原因，不保存token、原始HTTP响应或私人文件路径。
nonisolated enum PhotoBackupFailure: String, Codable, Sendable {
    case interrupted, sourceMissing, sourceChanged, unsupportedResources, permission, network
    case livePhotoMismatch, unconfirmedResponse, unavailable, storage, historyUnconfirmed
    /// 沿用Mac候选的待核查标记以保留往返读取；它不把未知历史升级为新上传许可。
    case historyNeedsReview

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
        case .historyUnconfirmed, .historyNeedsReview: "The previous backup could not be confirmed. No original was downloaded or uploaded."
        }
    }
}

/// 非法转换或损坏日志必须显式失败，不能以空队列覆盖已有恢复资料。
nonisolated enum PhotoBackupStateError: Error, Equatable, Sendable {
    case invalidTransition, invalidJournal
}

/// 单个原片/视频/Live Photo/RAW+JPEG逻辑任务；只有全部所需原始资源和必要配对已确认才可完成。
nonisolated struct PhotoBackupJob: Codable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable {
        case queued, exporting, uploadingMotion, uploadingPrimary, verifying, paused, failed, cancelled, completed
        /// 服务端已有的匹配状态；不等于原片字节或完整上传回执，重新扫描后仍须核查。
        case existing

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
    /// 本次已实际导出并发送/查重的主体SHA1；旧任务缺字段保持nil，不能以旧UUID猜测原图证明。
    private(set) var primaryChecksum: String?
    private(set) var primaryWasDuplicate: Bool
    private(set) var failure: PhotoBackupFailure?
    private(set) var rawReceipt: PhotoBackupImageReceipt?
    private(set) var jpegReceipt: PhotoBackupImageReceipt?

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
        if source.kind == .rawJPEG {
            guard let pair = source.rawJPEG, let modified = source.modifiedAt, modified.timeIntervalSince1970.isFinite,
                  primaryAssetID == nil, primaryChecksum == nil, motionAssetID == nil else { throw PhotoBackupStateError.invalidJournal }
            try pair.validate(); try rawReceipt?.validate(); try jpegReceipt?.validate()
            guard stage != .completed || (rawReceipt != nil && jpegReceipt != nil && rawReceipt?.assetID != jpegReceipt?.assetID && rawReceipt?.checksum != jpegReceipt?.checksum)
            else { throw PhotoBackupStateError.invalidJournal }
        } else {
            guard source.rawJPEG == nil, rawReceipt == nil, jpegReceipt == nil else { throw PhotoBackupStateError.invalidJournal }
        }
        if let primaryChecksum {
            guard primaryAssetID != nil, let bytes = Data(base64Encoded: primaryChecksum), bytes.count == 20, bytes.base64EncodedString() == primaryChecksum else { throw PhotoBackupStateError.invalidJournal }
        }
        guard !source.localID.isEmpty, attempts >= 0,
              motionAssetID == nil || source.kind == .livePhoto,
              stage != .completed || source.kind == .rawJPEG || (primaryAssetID != nil && (source.kind != .livePhoto || motionAssetID != nil))
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

    /// assetID/duplicate为主体回执，checksum可附本次实际字节SHA1；nil保留旧调用兼容，尚不代表Live配对已核对。
    mutating func recordPrimary(_ assetID: UUID, duplicate: Bool, checksum: String? = nil) throws {
        guard source.kind != .rawJPEG, stage == .uploadingPrimary, source.kind != .livePhoto || motionAssetID != nil else { throw PhotoBackupStateError.invalidTransition }
        primaryAssetID = assetID
        primaryChecksum = checksum
        primaryWasDuplicate = duplicate
        stage = .verifying
    }

    /// 调用者已通过真实上传回执及必要的静态帧关联读取确认完整性；单独动态资源永不算完成。
    mutating func confirmVerifiedReceipt() throws {
        guard source.kind != .rawJPEG, stage == .verifying, primaryAssetID != nil,
              source.kind != .livePhoto || motionAssetID != nil else { throw PhotoBackupStateError.invalidTransition }
        stage = .completed
        failure = nil
    }

    /// 当前queued源已在服务器确认存在；只保留匹配状态，不增加上传次数、不伪造主体/动态/RAW回执。
    mutating func confirmExistingMatch() throws {
        guard stage == .queued else { throw PhotoBackupStateError.invalidTransition }
        stage = .existing; failure = nil
    }

    /// receipt已由本轮完整文件与fresh远端信息核对；逐份落盘，重试仍须重导出和查重，旧回执不是跳过依据。
    mutating func recordImage(_ receipt: PhotoBackupImageReceipt, role: PhotoBackupImageRole) throws {
        guard source.kind == .rawJPEG, stage == .uploadingPrimary else { throw PhotoBackupStateError.invalidTransition }
        try receipt.validate()
        if role == .raw {
            rawReceipt = receipt
        } else {
            jpegReceipt = receipt
        }
    }

    /// 本轮两份都已重新确认后进入最终核对；旧的部分回执不能通过此方法直接变成完成。
    mutating func imagesUploaded() throws {
        guard source.kind == .rawJPEG, stage == .uploadingPrimary, rawReceipt != nil, jpegReceipt != nil else {
            throw PhotoBackupStateError.invalidTransition
        }
        stage = .verifying
    }

    /// 调用者完成两份独立fresh回读；要求不同远端资产，双原图作为一个完整逻辑任务计数。
    mutating func confirmVerifiedImages() throws {
        guard source.kind == .rawJPEG, stage == .verifying, let rawReceipt, let jpegReceipt,
              rawReceipt.assetID != jpegReceipt.assetID, rawReceipt.checksum != jpegReceipt.checksum
        else {
            throw PhotoBackupStateError.invalidTransition
        }
        stage = .completed; failure = nil
    }

    /// 暂停未完成任务并保留所有已确认回执；完成/旧已有候选/取消历史不因页面退出被改写。
    mutating func pause() {
        guard stage != .completed, stage != .cancelled, stage != .failed, stage != .existing else { return }
        failure = stage.isInFlight ? .interrupted : nil
        stage = .paused
    }

    /// reason为安全错误分类；只标记尚未完成的当前操作，不删除已上传的服务端资源。
    mutating func fail(_ reason: PhotoBackupFailure) {
        guard stage != .completed, stage != .cancelled else { return }
        stage = .failed
        failure = reason
    }

    /// 取消只停止未确认本地任务；已上传/已匹配事实保留，未知远端写入以后仍需查重。
    mutating func cancel() {
        guard stage != .completed, stage != .existing else { return }
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

/// 当前队列的保守恢复摘要；eligibleJobIDs只包含从未尝试、无失败/回执且没有同源未知历史的既有任务。
/// 展示数是重新核相簿前的上限，不能代替本轮真实包含/排除扫描。
nonisolated struct PhotoBackupUnattemptedSummary: Sendable {
    let eligibleJobIDs: Set<UUID>
    let blockedLocalIDs: Set<String>
    let failed: Int
    let attemptedOrUnconfirmed: Int
    let cancelled: Int
    let completed: Int
    /// 只计服务端身份匹配，不将其解释为新上传成功。
    let matched: Int

    /// jobs来自当前账号完整冷快照；取消/失败和任何未完成尝试/回执都阻断同localID的新任务自动或批量重放。
    init(jobs: [PhotoBackupJob]) {
        let blocked = Set(jobs.filter {
            $0.stage == .cancelled || $0.stage == .failed || (![.completed, .existing].contains($0.stage)
                && ($0.attempts > 0 || $0.failure != nil || $0.motionAssetID != nil || $0.primaryAssetID != nil || $0.rawReceipt != nil || $0.jpegReceipt != nil))
        }.map(\.source.localID))
        blockedLocalIDs = blocked
        eligibleJobIDs = Set(jobs.filter {
            [.queued, .paused].contains($0.stage) && !blocked.contains($0.source.localID)
                && $0.attempts == 0 && $0.failure == nil && $0.motionAssetID == nil && $0.primaryAssetID == nil && $0.rawReceipt == nil && $0.jpegReceipt == nil
        }.map(\.id))
        failed = jobs.count { $0.stage == .failed }
        cancelled = jobs.count { $0.stage == .cancelled }
        completed = jobs.count { $0.stage == .completed || $0.stage == .existing }
        matched = jobs.count { $0.stage == .existing }
        attemptedOrUnconfirmed = jobs.count - eligibleJobIDs.count - failed - cancelled - completed
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
        let rawJPEGVersion: Int?
        let foregroundAutomaticEnabled: Bool?
        let backgroundAutomaticEnabled: Bool?
        let foregroundNetworkRecoveryEnabled: Bool?

        /// version/namespace保留恢复格式与账号边界；excludedAlbumIDs缺省nil兼容旧格式，不用存储属性默认值遮蔽解码。
        /// rawJPEGVersion仅格式3允许且必须为1；其他格式不得偷偷携带双图资料。
        /// foregroundAutomaticEnabled缺省nil表示默认关闭；旧读取器忽略后只会失去自动启用，不会扩大上传范围。
        /// backgroundAutomaticEnabled为独立系统后台同意；foregroundNetworkRecoveryEnabled为独立前台连接失败重核同意，缺省nil均关闭。
        init(version: Int, namespace: String, selectedAlbumIDs: [String], allowCloud: Bool, excludedAlbumIDs: [String]? = nil, rawJPEGVersion: Int? = nil,
             foregroundAutomaticEnabled: Bool? = nil, backgroundAutomaticEnabled: Bool? = nil, foregroundNetworkRecoveryEnabled: Bool? = nil)
        {
            self.version = version
            self.namespace = namespace
            self.selectedAlbumIDs = selectedAlbumIDs
            self.allowCloud = allowCloud
            self.excludedAlbumIDs = excludedAlbumIDs
            self.rawJPEGVersion = rawJPEGVersion
            self.foregroundAutomaticEnabled = foregroundAutomaticEnabled
            self.backgroundAutomaticEnabled = backgroundAutomaticEnabled
            self.foregroundNetworkRecoveryEnabled = foregroundNetworkRecoveryEnabled
        }

        /// expected来自当前认证scope；未知格式或跨账号日志必须保留并报错，不能被热写覆盖。
        func validate(namespace expected: String) throws {
            let exclusions = excludedAlbumIDs ?? []
            let validIncludes = !selectedAlbumIDs.isEmpty && selectedAlbumIDs.allSatisfy { !$0.isEmpty }
                && Set(selectedAlbumIDs).count == selectedAlbumIDs.count
            guard [1, 2, 3].contains(version), namespace == expected,
                  foregroundAutomaticEnabled != true || validIncludes,
                  backgroundAutomaticEnabled != true || validIncludes,
                  foregroundNetworkRecoveryEnabled != true || validIncludes,
                  version == 3 ? rawJPEGVersion == 1 : rawJPEGVersion == nil,
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
    private(set) var rawJPEGVersion: Int?
    private(set) var foregroundAutomaticEnabled: Bool?
    /// 独立系统后台同意；旧日志缺省nil为关闭，不借前台自动开关推导同意。
    private(set) var backgroundAutomaticEnabled: Bool?
    /// 独立前台网络恢复同意；旧日志缺省关闭，不借原自动开关扩大对失败项的操作范围。
    private(set) var foregroundNetworkRecoveryEnabled: Bool?

    /// namespace来自已认证MediaAccountScope；日志仅属于该账号，不使用email或设备相簿名推断身份。
    init(namespace: String) {
        version = 1
        self.namespace = namespace
        selectedAlbumIDs = []
        allowCloud = false
        excludedAlbumIDs = nil
        jobs = []
        rawJPEGVersion = nil
        foregroundAutomaticEnabled = nil
        backgroundAutomaticEnabled = nil
        foregroundNetworkRecoveryEnabled = nil
    }

    /// 从独立日志头与按扫描顺序读取的任务重建冷快照；调用方随后验证当前scope及完整集合。
    init(header: Header, jobs: [PhotoBackupJob]) {
        version = header.version
        namespace = header.namespace
        selectedAlbumIDs = header.selectedAlbumIDs
        allowCloud = header.allowCloud
        excludedAlbumIDs = header.excludedAlbumIDs
        self.jobs = jobs
        rawJPEGVersion = header.rawJPEGVersion
        foregroundAutomaticEnabled = header.foregroundAutomaticEnabled
        backgroundAutomaticEnabled = header.backgroundAutomaticEnabled
        foregroundNetworkRecoveryEnabled = header.foregroundNetworkRecoveryEnabled
    }

    /// 返回不随任务数增长的日志头；选择相簿列表仅在明确扫描时整体更新。
    var header: Header {
        .init(version: version, namespace: namespace, selectedAlbumIDs: selectedAlbumIDs, allowCloud: allowCloud, excludedAlbumIDs: excludedAlbumIDs,
              rawJPEGVersion: rawJPEGVersion, foregroundAutomaticEnabled: foregroundAutomaticEnabled,
              backgroundAutomaticEnabled: backgroundAutomaticEnabled, foregroundNetworkRecoveryEnabled: foregroundNetworkRecoveryEnabled)
    }

    /// enabled是用户对当前已保存选择的明确自动化同意；不修改相簿/iCloud草稿，也不恢复任何任务。
    mutating func setForegroundAutomaticEnabled(_ enabled: Bool) throws {
        try validate(namespace: namespace)
        guard !enabled || !selectedAlbumIDs.isEmpty else { throw PhotoBackupStateError.invalidJournal }
        foregroundAutomaticEnabled = enabled
    }

    /// enabled是当前账号对系统后台的独立同意；不改前台开关、相簿范围、iCloud选项或任务状态。
    mutating func setBackgroundAutomaticEnabled(_ enabled: Bool) throws {
        try validate(namespace: namespace)
        guard !enabled || !selectedAlbumIDs.isEmpty else { throw PhotoBackupStateError.invalidJournal }
        backgroundAutomaticEnabled = enabled
    }

    /// enabled为用户独立同意；只改已有账号日志头，不开启前台/后台规则、不修改保存范围或恢复任务。
    mutating func setForegroundNetworkRecoveryEnabled(_ enabled: Bool) throws {
        try validate(namespace: namespace)
        guard !enabled || !selectedAlbumIDs.isEmpty else { throw PhotoBackupStateError.invalidJournal }
        foregroundNetworkRecoveryEnabled = enabled
    }

    /// scan必须来自本轮完整保存范围/当前源；只在新验证网络事件和独立同意下由Controller调用一次。
    /// 返回重排数；保留所有字节/配对回执供原Worker重新导出、查重和fresh核验，取消/其他未知/版本变化不恢复。
    @discardableResult mutating func resumeNetworkFailures(_ scan: PhotoBackupAlbumScan) throws -> Int {
        try validate(namespace: namespace)
        guard foregroundAutomaticEnabled == true, foregroundNetworkRecoveryEnabled == true,
              !jobs.contains(where: \.stage.isInFlight), Set(selectedAlbumIDs) == scan.selection.included,
              Set(excludedAlbumIDs ?? []) == scan.selection.excluded else { throw PhotoBackupStateError.invalidTransition }
        let eligible = Set(scan.sources)
        let incomplete = jobs.filter { $0.stage != .completed }
        let blocked = Set(incomplete.filter {
            !($0.stage == .failed && $0.failure == .network)
                && ($0.stage == .cancelled || $0.attempts > 0 || $0.failure != nil || $0.motionAssetID != nil
                    || $0.primaryAssetID != nil || $0.rawReceipt != nil || $0.jpegReceipt != nil)
        }.map(\.source.localID))
        let histories = Dictionary(grouping: incomplete, by: { $0.source.localID })
        var count = 0
        for index in jobs.indices {
            let job = jobs[index]
            guard job.stage == .failed, job.failure == .network, eligible.contains(job.source),
                  let modified = job.source.modifiedAt, modified.timeIntervalSince1970.isFinite,
                  !blocked.contains(job.source.localID), histories[job.source.localID]?.count == 1 else { continue }
            jobs[index].queueForVerification(); count += 1
        }
        return count
    }

    /// scan须精确使用已保存的包含/排除规则；自动计划仅新增安全源，不重排完成项或恢复失败/取消/未知尝试。
    /// 返回新增逻辑源数；生命周期暂停且从未尝试的项目可排队，已有任何失败或用户取消的localID需手动处理。
    @discardableResult mutating func applyAutomaticAlbumScan(_ scan: PhotoBackupAlbumScan) throws -> Int {
        guard foregroundAutomaticEnabled == true else { throw PhotoBackupStateError.invalidTransition }
        return try mergeScheduledAlbumScan(scan)
    }

    /// scan来自已保存规则的本轮授权扫描；只有独立后台开关开启才允许新增安全任务，返回新增源数量。
    @discardableResult mutating func applyBackgroundAlbumScan(_ scan: PhotoBackupAlbumScan) throws -> Int {
        guard backgroundAutomaticEnabled == true else { throw PhotoBackupStateError.invalidTransition }
        return try mergeScheduledAlbumScan(scan)
    }

    /// 两种已同意的自动入口共用相同安全计划；不恢复失败、取消或已有未知上传回执的源。
    private mutating func mergeScheduledAlbumScan(_ scan: PhotoBackupAlbumScan) throws -> Int {
        try validate(namespace: namespace)
        guard !jobs.contains(where: \.stage.isInFlight),
              Set(selectedAlbumIDs) == scan.selection.included, Set(excludedAlbumIDs ?? []) == scan.selection.excluded
        else { throw PhotoBackupStateError.invalidTransition }
        let eligible = Set(scan.sources)
        let blockedIDs = PhotoBackupUnattemptedSummary(jobs: jobs).blockedLocalIDs
        let existing = Set(jobs.map(\.source))
        for index in jobs.indices where jobs[index].stage == .queued || jobs[index].stage == .paused {
            let job = jobs[index]
            if !eligible.contains(job.source) {
                jobs[index].cancel()
            } else if job.attempts == 0, job.failure == nil, job.motionAssetID == nil, job.primaryAssetID == nil,
                      job.rawReceipt == nil, job.jpegReceipt == nil, !blockedIDs.contains(job.source.localID)
            {
                jobs[index].queueForVerification()
            } else if job.stage == .queued {
                jobs[index].pause()
            }
        }
        // enqueue只接收从未出现过的完整源；不能把它的手动重验语义施加到既有完成/失败/取消任务。
        return try enqueue(scan.sources.filter { !existing.contains($0) && !blockedIDs.contains($0.localID) })
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
        if !scan.selection.excluded.isEmpty, version < 2 {
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
            guard version == 3 || job.source.kind != .rawJPEG else { throw PhotoBackupStateError.invalidJournal }
        }
    }

    /// sources为一次明确扫描的去重源快照；同版本完成项也重新查重，不能假定服务器永远保留旧备份。
    /// 返回本次新建/重排任务数；旧版本未完成任务取消，避免把不同版本资源拼成Live Photo。
    @discardableResult mutating func enqueue(_ sources: [PhotoBackupSource]) throws -> Int {
        try validate(namespace: namespace)
        let groups = Dictionary(grouping: sources, by: \.localID)
        guard groups.allSatisfy({ !$0.key.isEmpty && Set($0.value).count == 1 }) else { throw PhotoBackupStateError.invalidJournal }
        // 包含双原图的明确扫描原子升级格式；旧读取器必须先拒绝header，不能漏掉JPEG后继续上传。
        if sources.contains(where: { $0.kind == .rawJPEG }) {
            version = 3; rawJPEGVersion = 1; excludedAlbumIDs = excludedAlbumIDs ?? []
        }
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

    /// scan重新确认已保存的完整相簿规则；只恢复既有安全未尝试项，不新增源或重新发送任何未知历史。
    /// 返回实际排队数；失败/取消/完成及已尝试暂停保持原样，不再属于当前源快照的安全项仅取消本地任务。
    @discardableResult mutating func resumeUnattempted(_ scan: PhotoBackupAlbumScan) throws -> Int {
        try validate(namespace: namespace)
        guard !jobs.contains(where: \.stage.isInFlight), Set(selectedAlbumIDs) == scan.selection.included,
              Set(excludedAlbumIDs ?? []) == scan.selection.excluded else { throw PhotoBackupStateError.invalidTransition }
        let summary = PhotoBackupUnattemptedSummary(jobs: jobs)
        let current = Set(scan.sources)
        var count = 0
        for index in jobs.indices {
            if summary.eligibleJobIDs.contains(jobs[index].id) {
                if current.contains(jobs[index].source) {
                    jobs[index].queueForVerification(); count += 1
                } else {
                    jobs[index].cancel()
                }
            } else if jobs[index].stage == .queued {
                // 即便手动重排曾把未知项变成queued，本入口也不能让Worker顺带执行它。
                jobs[index].pause()
            }
        }
        return count
    }

    /// 进程中断后恢复为可明确继续的暂停状态；已完成/失败/取消保持原样。
    mutating func recoverInterrupted() {
        for index in jobs.indices {
            jobs[index].recoverInterrupted()
        }
    }
}
