import Foundation

/// 用户明确选择的稳定目标UUID；名称只供显示，不参与同名猜测、自动创建或改名。
nonisolated struct PhotoBackupAlbumMapping: Codable, Equatable, Sendable {
    let localAlbumID: String
    let targetID: UUID
    let targetName: String
}

/// 远端主体的组织证据；metadata的远端checksum不宣称本机字节已验证，Live只加primary。
nonisolated struct PhotoBackupAlbumSyncAsset: Codable, Hashable, Sendable {
    /// primary涵盖普通照片/视频及Live still，RAW/JPEG则固定两个独立角色。
    enum Role: String, Codable, Hashable, Sendable { case primary, raw, jpeg }
    /// 区分组织依据，不将metadata证明提升成本机原片备份回执。
    enum Proof: String, Codable, Hashable, Sendable { case metadataAssociation, checksumAssociation, originalReceipt }
    let role: Role
    let assetID: UUID
    let checksum: String
    let revision: Date?
    let proof: Proof
}

/// 相簿关系操作的安全失败分类；不持久化HTTP正文、token、私人路径或系统错误文本。
nonisolated enum PhotoBackupAlbumSyncFailure: String, Codable, Sendable {
    case permission, sourceChanged, unconfirmed, unavailable
}

/// 单个本地逻辑源在一个目标相簿内的独立组织状态；不修改上传完成或已有配对回执。
nonisolated struct PhotoBackupAlbumSyncOperation: Codable, Identifiable, Sendable {
    /// sending须在HTTP前落盘；冷恢复显示unknown，confirmed只在本轮全部fresh核查后产生。
    enum Phase: String, Codable, Sendable { case queued, sending, confirmed, unknown, failed, cancelled }
    let id: UUID
    let localAlbumID: String
    let targetID: UUID
    let source: PhotoBackupSource
    let assets: [PhotoBackupAlbumSyncAsset]
    /// 保留逐项历史确认供恢复；新一轮仍重核全部主体，不能单凭此集合重新完成整组。
    var confirmedAssetIDs: Set<UUID>
    var phase: Phase
    var failure: PhotoBackupAlbumSyncFailure?

    /// source/target/assets在建计划时固定；确认集合从空开始，不能拿上传完成冒充相簿组织完成。
    init(id: UUID = UUID(), localAlbumID: String, targetID: UUID, source: PhotoBackupSource, assets: [PhotoBackupAlbumSyncAsset]) {
        self.id = id; self.localAlbumID = localAlbumID; self.targetID = targetID; self.source = source; self.assets = assets
        confirmedAssetIDs = []; phase = .queued
    }

    /// 已知有限源版本、完整角色和canonical SHA1是计划前提；确认状态必须覆盖全部独立主体。
    func validate() throws {
        guard !localAlbumID.isEmpty, !source.localID.isEmpty, let modified = source.modifiedAt, modified.timeIntervalSince1970.isFinite,
              Set(assets.map(\.assetID)).count == assets.count, Set(assets.map(\.role)).count == assets.count,
              confirmedAssetIDs.isSubset(of: Set(assets.map(\.assetID))), phase != .confirmed || confirmedAssetIDs.count == assets.count
        else { throw PhotoBackupStateError.invalidJournal }
        if source.kind == .rawJPEG {
            guard let pair = source.rawJPEG, assets.count == 2, Set(assets.map(\.role)) == [.raw, .jpeg], Set(assets.map(\.checksum)).count == 2 else {
                throw PhotoBackupStateError.invalidJournal
            }
            try pair.validate()
        } else {
            guard source.rawJPEG == nil, assets.count == 1, assets.first?.role == .primary else { throw PhotoBackupStateError.invalidJournal }
        }
        for asset in assets {
            guard let bytes = Data(base64Encoded: asset.checksum), bytes.count == 20, bytes.base64EncodedString() == asset.checksum,
                  asset.revision.map(\.timeIntervalSince1970.isFinite) ?? true,
                  source.kind == .rawJPEG ? asset.proof == .originalReceipt : asset.proof != .originalReceipt && asset.revision != nil
            else { throw PhotoBackupStateError.invalidJournal }
        }
    }
}

/// 相簿组织账本与上传日志分离；映射头和逐组行仍存同一账号SQLite，未知格式不能覆盖恢复资料。
nonisolated struct PhotoBackupAlbumSyncState: Sendable {
    /// 轻量头只保存版本、账号与明确映射；逐组历史另行持久化。
    nonisolated struct Header: Codable, Sendable {
        let version: Int
        let namespace: String
        let mappings: [PhotoBackupAlbumMapping]
    }

    let version: Int
    let namespace: String
    var mappings: [PhotoBackupAlbumMapping]
    var operations: [PhotoBackupAlbumSyncOperation]

    /// namespace固定账号；仅新账本使用版本1，读取旧头时保留实际版本以便拒绝未来格式。
    init(namespace: String, mappings: [PhotoBackupAlbumMapping] = [], operations: [PhotoBackupAlbumSyncOperation] = [], version: Int = 1) {
        self.namespace = namespace; self.mappings = mappings; self.operations = operations; self.version = version
    }

    /// 小型映射头不含操作历史，用于热更新前检查未来版本/账号。
    var header: Header {
        .init(version: version, namespace: namespace, mappings: mappings)
    }

    /// expected来自当前认证scope；操作历史允许保留旧映射，但ID、版本、角色和回执必须始终完整。
    func validate(namespace expected: String) throws {
        guard version == 1, namespace == expected, mappings.allSatisfy({ !$0.localAlbumID.isEmpty }),
              Set(mappings.map(\.localAlbumID)).count == mappings.count, Set(operations.map(\.id)).count == operations.count else { throw PhotoBackupStateError.invalidJournal }
        for operation in operations {
            try operation.validate()
        }
    }
}
