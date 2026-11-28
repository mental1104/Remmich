import Foundation
import Photos

/// 临时服务器故障保持同一任务与检查点；退避封顶，取消和账号变更立即退出。
@MainActor struct PhotoSyncRetry {
    var delays: [UInt64] = [1, 2, 4, 8, 16, 30, 60].map { UInt64($0) * 1_000_000_000 }
    var keepWaiting = true
    var validate: @MainActor () throws -> Void = {}
    var status: @MainActor (String.LocalizationValue) -> Void = { _ in }

    func call<Value: Sendable>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        var attempt = 0
        while true {
            try Task.checkCancellation(); try validate()
            do {
                let value = try await operation()
                try Task.checkCancellation(); try validate()
                return value
            } catch {
                try Task.checkCancellation(); try validate()
                guard Self.isTransient(error), !delays.isEmpty, keepWaiting || attempt < delays.count else { throw error }
                let delay = delays[min(attempt, delays.count - 1)]
                attempt += 1
                status("服务器暂不可用，\(Int(delay / 1_000_000_000)) 秒后继续（重试 \(attempt)）；进度已保留，可随时暂停。")
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? LibraryWriteError, case let .http(code) = error {
            return (500 ... 599).contains(code) || code == 408 || code == 429
        }
        let value = error as NSError
        if value.domain == PHPhotosErrorDomain {
            // 3164要求用户允许云读取，不能靠重试扩大allowCloud；仅3169是明确的临时网络失败。
            return value.code == PHPhotosError.Code.networkError.rawValue
        }
        guard value.domain == NSURLErrorDomain else { return false }
        return [URLError.timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains { $0.rawValue == value.code }
    }
}

/// 仅在既有原片读取许可内重新导出同一源；真实Exporter负责每次重验版本及清理失败的私有目录。
@MainActor struct PhotoSyncRetryingExporter: PhotoBackupResourceExporting {
    let base: any PhotoBackupResourceExporting
    let retry: PhotoSyncRetry

    func export(_ source: PhotoBackupSource, allowCloud: Bool) async throws -> PhotoBackupResources {
        do {
            return try await retry.call { try await base.export(source, allowCloud: allowCloud) }
        } catch {
            guard PhotoSyncRetry.isTransient(error) else { throw error }
            try Task.checkCancellation(); try retry.validate()
            // 有限策略耗尽后沿用现有安全网络失败/恢复语义，不保存PhotoKit错误正文。
            throw PhotoBackupExportError(reason: .network)
        }
    }
}

/// 仅包装真实客户端：每次上传重试重新执行完整checksum查重，不直接重放媒体POST。
@MainActor struct PhotoSyncRetryingUploader: PhotoBackupUploading {
    let base: LibraryMutationClient
    let retry: PhotoSyncRetry

    @MainActor func upload(file: URL, filename: String, created: Date, modified: Date, favorite: Bool,
                           hidden: Bool, livePhotoVideoID: String?) async throws -> LibraryMutationClient.UploadResult
    {
        try await retry.call {
            try await base.upload(file: file, filename: filename, created: created, modified: modified,
                                  favorite: favorite, hidden: hidden, livePhotoVideoID: livePhotoVideoID)
        }
    }

    @MainActor func asset(_ id: String) async throws -> ManagedAsset {
        try await retry.call { try await base.asset(id) }
    }

    @MainActor func recordBackupOrigin(assetID: UUID, origin: PhotoBackupOrigin) async throws {
        // 固定asset/key/value的幂等PUT；不创建媒体或扩大写入范围。
        try await retry.call { try await base.recordBackupOrigin(assetID: assetID, origin: origin) }
    }
}

@MainActor struct LocalMediaRetryingQueries: LocalMediaMatchingReading {
    let base: any LocalMediaMatchingReading
    let retry: PhotoSyncRetry

    @MainActor func localMediaMetadata(cloudIDs: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord] {
        try await retry.call { try await base.localMediaMetadata(cloudIDs: cloudIDs) }
    }

    @MainActor func localMediaAsset(_ id: String) async throws -> LocalMediaRemoteAsset {
        try await retry.call { try await base.localMediaAsset(id) }
    }

    @MainActor func lookupLocalMediaChecksums(_ queries: [LocalMediaChecksumQuery]) async throws -> [LocalMediaChecksumLookup] {
        try await retry.call { try await base.lookupLocalMediaChecksums(queries) }
    }
}
