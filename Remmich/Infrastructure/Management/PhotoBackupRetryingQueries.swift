import Foundation
import OSLog

/// 预检读取退避；生产调用可明确启用固定key/value匹配标记PUT重试，不接收媒体POST。
@MainActor struct PhotoBackupRetryingQueries: PhotoBackupContinuityQuerying {
    let base: any PhotoBackupContinuityQuerying
    var delays: [UInt64] = [1, 2, 4, 8, 16, 30, 30, 30].map { UInt64($0) * 1_000_000_000 }
    var validate: @MainActor () throws -> Void = {}
    var status: @MainActor (String.LocalizationValue) -> Void = { _ in }
    var keepWaiting = false
    var retryMatchedWrites = false
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "BackupReadRetry")

    func lookupBackupChecksums(_ queries: [PhotoBackupCachedChecksumQuery]) async throws -> [LocalMediaChecksumLookup] {
        try await read { try await base.lookupBackupChecksums(queries) }
    }

    func localMediaMetadata(cloudIDs: Set<String>) async throws -> [LocalMediaRemoteMetadataRecord] {
        try await read { try await base.localMediaMetadata(cloudIDs: cloudIDs) }
    }

    func localMediaMetadataSnapshot() async throws -> [LocalMediaRemoteMetadataRecord] {
        try await read { try await base.localMediaMetadataSnapshot() }
    }

    func localMediaAsset(_ id: String) async throws -> LocalMediaRemoteAsset {
        try await read { try await base.localMediaAsset(id) }
    }

    @MainActor func recordICloudMatches(_ matches: [UUID: String]) async throws {
        if retryMatchedWrites {
            try await read { try await base.recordICloudMatches(matches) }
            return
        }
        try Task.checkCancellation(); try validate()
        try await base.recordICloudMatches(matches)
        try Task.checkCancellation(); try validate()
    }

    private func read<Value: Sendable>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        if keepWaiting {
            return try await PhotoSyncRetry(validate: validate, status: status).call(operation)
        }
        var attempt = 0
        while true {
            try Task.checkCancellation(); try validate()
            do {
                let value = try await operation()
                try Task.checkCancellation(); try validate()
                return value
            } catch {
                try Task.checkCancellation(); try validate()
                guard attempt < delays.count, Self.isTransient(error) else { throw error }
                let seconds = Int(delays[attempt] / 1_000_000_000)
                attempt += 1
                status("连接暂时中断，\(seconds) 秒后重试读取（\(attempt) / \(delays.count)）；已确认匹配进度保留。")
                Self.logger.notice("Retrying backup read attempt=\(attempt) delaySeconds=\(seconds)")
                try await Task.sleep(nanoseconds: delays[attempt - 1])
            }
        }
    }

    static func isTransient(_ error: any Error) -> Bool {
        PhotoSyncRetry.isTransient(error)
    }
}
