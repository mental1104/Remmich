import Foundation
import Synchronization

/// 一个扫描/设置发布代际的同步写许可；撤销与最终原子文件写按同一Mutex排序，旧任务不能迟到覆盖配置。
final nonisolated class LocalMediaSavePermit: Sendable {
    private let valid = Mutex(true)

    /// 取消/换号调用；返回后此许可不能再执行任何文件写。
    func invalidate() {
        valid.withLock { $0 = false }
    }

    /// operation只包含已编码资料的原子写；锁保护最后一次许可判断与文件提交，false表示已撤销而未写。
    func writeIfCurrent(_ operation: () throws -> Void) throws -> Bool {
        try valid.withLock { enabled in
            guard enabled else { return false }
            try operation(); return true
        }
    }
}

/// 按账号namespace保存的版本化只读关联；不保存token、远端媒体或任何上传/备份完成状态。
nonisolated struct LocalMediaAssociationDocument: Codable, Sendable {
    let formatVersion: Int
    let namespace: String
    let enabled: Bool
    let access: LocalPhotoLibraryAccess?
    let associations: [LocalMediaAssociation]

    /// scope限定服务器与账号；access是确认时授权范围，nil表示尚未完成可用扫描。
    init(scope: MediaAccountScope, enabled: Bool, access: LocalPhotoLibraryAccess?, associations: [LocalMediaAssociation]) {
        formatVersion = 1; namespace = scope.cacheNamespace; self.enabled = enabled; self.access = access; self.associations = associations
    }
}

/// Controller的独立恢复资料边界；实现必须检查版本/namespace且尊重撤销许可，测试仍使用真实原子JSON实现。
nonisolated protocol LocalMediaAssociationPersisting: Sendable {
    /// scope指定账号namespace；缺文件为nil，格式/内容问题抛错而非当作空配置。
    func load(scope: MediaAccountScope) async throws -> LocalMediaAssociationDocument?
    /// document只能写入同scope；permit撤销返回false且不写，未知旧格式或I/O失败抛错。
    func save(_ document: LocalMediaAssociationDocument, scope: MediaAccountScope, permit: LocalMediaSavePermit) async throws -> Bool
}

/// 只在Application Support/LocalMediaAssociations下按namespace写一个JSON；未知未来格式或损坏文件拒绝覆盖。
actor LocalMediaAssociationStore: LocalMediaAssociationPersisting {
    private let directory: URL

    /// directory仅供隔离临时目录测试；默认不接触SQLite、原片、Saved Photos回执或其他账号目录。
    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("LocalMediaAssociations", isDirectory: true)
    }

    /// 缺文件返回nil；坏版本/namespace/重复远端ID拒绝，不能把不可读恢复资料当作空配置。
    func load(scope: MediaAccountScope) throws -> LocalMediaAssociationDocument? {
        let path = file(scope)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let document = try JSONDecoder().decode(LocalMediaAssociationDocument.self, from: Data(contentsOf: path))
        try validate(document, scope: scope)
        return document
    }

    /// 编码和旧版本检查在actor内串行；最终目录创建/atomic写在许可临界区，取消后不提交迟到扫描结果。
    func save(_ document: LocalMediaAssociationDocument, scope: MediaAccountScope, permit: LocalMediaSavePermit) throws -> Bool {
        try Task.checkCancellation(); try validate(document, scope: scope)
        _ = try load(scope: scope)
        let data = try JSONEncoder().encode(document)
        try Task.checkCancellation()
        return try permit.writeIfCurrent {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(scope), options: .atomic)
        }
    }

    /// namespace仅由规范化服务器+用户SHA256产生，不使用用户可控文件名。
    private func file(_ scope: MediaAccountScope) -> URL {
        directory.appendingPathComponent(scope.cacheNamespace).appendingPathExtension("json")
    }

    /// document是只读关联文档；格式必须明确已知，不能用降级保存抹掉未来版本规则。
    private func validate(_ document: LocalMediaAssociationDocument, scope: MediaAccountScope) throws {
        guard document.formatVersion == 1, document.namespace == scope.cacheNamespace,
              Set(document.associations.map(\.remoteID)).count == document.associations.count else { throw LocalMediaMetadataError.invalidMetadata }
        for association in document.associations {
            guard association.remoteRevision.timeIntervalSince1970.isFinite, !association.localIdentity.localIdentifier.isEmpty,
                  let modified = association.localIdentity.modificationDate, modified.timeIntervalSince1970.isFinite,
                  let digest = Data(base64Encoded: association.checksum), digest.count == 20, digest.base64EncodedString() == association.checksum,
                  document.access == .full || document.access == .limited else { throw LocalMediaMetadataError.invalidMetadata }
        }
    }
}
