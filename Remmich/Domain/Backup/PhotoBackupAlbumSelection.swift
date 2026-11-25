import Foundation

/// 一次手机相簿枚举的合成边界；只携带稳定源身份/版本和排序日期，不持有PhotoKit对象或媒体字节。
nonisolated struct PhotoBackupScannedAsset: Equatable, Sendable {
    let source: PhotoBackupSource
    let capturedAt: Date?
}

/// id为已重新确认可访问的手机相簿；assets仅包含本轮授权可见的照片/视频，空数组表示真实空相簿。
nonisolated struct PhotoBackupAlbumSnapshot: Sendable {
    let id: String
    let assets: [PhotoBackupScannedAsset]
}

/// 相簿消失、选择损坏或枚举中源版本变化都应要求重新扫描，不能忽略排除规则后继续上传。
nonisolated enum PhotoBackupAlbumSelectionError: Error, Equatable, Sendable {
    case invalidSelection, unavailableAlbum, changedSource
}

/// 明确扫描的选择规则；排除优先于包含，即使同一照片同时属于两类相簿也不会进入本轮队列。
/// 规则在扫描时生效；后续相簿成员变化需要新的扫描，不承诺冻结的队列实时跟随系统照片库。
nonisolated struct PhotoBackupAlbumSelection: Equatable, Sendable {
    let included: Set<String>
    let excluded: Set<String>

    /// included至少一项，excluded可为空；所有ID来自授权PhotoKit集合，不接受空ID。
    init(included: Set<String>, excluded: Set<String>) throws {
        guard !included.isEmpty, included.union(excluded).allSatisfy({ !$0.isEmpty }) else {
            throw PhotoBackupAlbumSelectionError.invalidSelection
        }
        self.included = included
        self.excluded = excluded
    }

    /// snapshots必须完整覆盖两种集合；结果包括排除后的有序源和需要取消旧待执行项的本地身份。
    /// 仅做一次线性枚举/去重与排序，不进入上传逐项检查点；缺失相簿或不同版本冲突均抛错。
    func scan(_ snapshots: [PhotoBackupAlbumSnapshot]) throws -> PhotoBackupAlbumScan {
        guard Set(snapshots.map(\.id)).count == snapshots.count else { throw PhotoBackupAlbumSelectionError.invalidSelection }
        let byAlbum = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.assets) })
        guard included.union(excluded).allSatisfy({ byAlbum[$0] != nil }) else {
            throw PhotoBackupAlbumSelectionError.unavailableAlbum
        }
        let excludedSources = Set(excluded.flatMap { byAlbum[$0] ?? [] }.map(\.source.localID))
        var byAsset: [String: PhotoBackupScannedAsset] = [:]
        for id in included.sorted() {
            for candidate in byAlbum[id] ?? [] {
                let sourceID = candidate.source.localID
                guard !sourceID.isEmpty else { throw PhotoBackupAlbumSelectionError.invalidSelection }
                if excludedSources.contains(sourceID) {
                    continue
                }
                if let previous = byAsset[sourceID], previous != candidate {
                    throw PhotoBackupAlbumSelectionError.changedSource
                }
                byAsset[sourceID] = candidate
            }
        }
        let sources = byAsset.values.sorted {
            let lhs = $0.capturedAt ?? .distantPast, rhs = $1.capturedAt ?? .distantPast
            return lhs == rhs ? $0.source.localID < $1.source.localID : lhs < rhs
        }.map(\.source)
        return .init(selection: self, sources: sources, excludedSourceIDs: excludedSources)
    }
}

/// 完整扫描结果只由选定规则生成；排除身份可取消旧未完成项，不能用于删除已上传资产或手机原片。
nonisolated struct PhotoBackupAlbumScan: Sendable {
    let selection: PhotoBackupAlbumSelection
    let sources: [PhotoBackupSource]
    let excludedSourceIDs: Set<String>

    /// 仅本文件的完整扫描可构造结果；selection为已验证规则，sources已去重排序，excludedSourceIDs仅供取消旧任务。
    fileprivate init(selection: PhotoBackupAlbumSelection, sources: [PhotoBackupSource], excludedSourceIDs: Set<String>) {
        self.selection = selection
        self.sources = sources
        self.excludedSourceIDs = excludedSourceIDs
    }
}
