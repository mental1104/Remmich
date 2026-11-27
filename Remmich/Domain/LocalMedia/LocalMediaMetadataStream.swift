import Foundation

/// 官方mobile-app关联的未验证快照；只有元数据，不含图片、视频、token或备份完成凭据。
nonisolated struct LocalMediaRemoteMetadataRecord: Equatable, Sendable {
    let assetID: UUID
    let value: Data
}

/// 只读匹配的稳定失败原因；不能把半条流、增量片段或需要重置的会话当作完整图库。
nonisolated enum LocalMediaMetadataStreamError: Error, Equatable, Sendable {
    case invalidInput, invalidResponse, incomplete, limitExceeded, metadataCheckpointExists, resetRequired
}

/// 按字节解析官方JSONL，只保留本轮本机cloud ID对应的关联；不确认同步、不改变远端检查点。
/// 每行/全流有限，结束标记和EOF均确认后才交出候选，网络中断不能发布部分匹配。
nonisolated struct LocalMediaMetadataStreamDecoder {
    private let cloudIDs: Set<String>?
    private let maximumLineBytes: Int
    private let maximumResponseBytes: Int
    private var receivedBytes = 0
    private var line: [UInt8] = []
    private var completed = false
    private var records: [LocalMediaRemoteMetadataRecord] = []
    private var backupRecords: [LocalMediaRemoteMetadataRecord] = []

    /// 相同资产/公开元组可由官方和本客户端同时记录；只合并跨来源的相同事实，不吞掉官方重复候选歧义。
    private struct CandidateIdentity: Hashable {
        let assetID: UUID
        let metadata: LocalMediaMobileMetadata
    }

    /// cloudIDs为本机公开Photos映射的完整不透明ID；nil先建立完整远端索引，仍受字节/候选数上限约束。
    init(cloudIDs: Set<String>?, maximumLineBytes: Int = 262_144, maximumResponseBytes: Int = 268_435_456) throws {
        guard cloudIDs.map({ !$0.isEmpty && $0.count <= 200_000 && $0.allSatisfy { !$0.isEmpty && $0.utf8.count <= 4096 } }) ?? true,
              maximumLineBytes > 0, maximumResponseBytes > 0 else { throw LocalMediaMetadataStreamError.invalidInput }
        self.cloudIDs = cloudIDs
        self.maximumLineBytes = maximumLineBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    /// data为本会话GET /sync/ack的完整200响应；已有元数据检查点意味着后续只会增量返回，禁止冒充全量快照。
    /// 其他实体检查点不变；调用者不得为此自动reset或删除任何会话进度。
    static func requireFullMetadataSnapshot(_ data: Data) throws {
        struct Ack: Decodable { let type: String; let ack: String }
        guard let acks = try? JSONDecoder().decode([Ack].self, from: data),
              acks.allSatisfy({ !$0.type.isEmpty && !$0.ack.isEmpty }) else { throw LocalMediaMetadataStreamError.invalidResponse }
        guard !acks.contains(where: { ["AssetMetadataV1", "AssetMetadataDeleteV1"].contains($0.type) }) else {
            throw LocalMediaMetadataStreamError.metadataCheckpointExists
        }
    }

    /// byte来自同一HTTP响应；保留跨网络分块的UTF8序列，直到换行才解码，过界立即失败。
    mutating func append(_ byte: UInt8) throws {
        receivedBytes += 1
        guard receivedBytes <= maximumResponseBytes else { throw LocalMediaMetadataStreamError.limitExceeded }
        if byte == 10 {
            // 官方serialize逐行终止；CRLF只去除结尾CR，不修改cloud ID或JSON内容。
            if line.last == 13 {
                line.removeLast()
            }
            if !line.isEmpty {
                try consume(Data(line))
            }
            line.removeAll(keepingCapacity: true)
        } else {
            guard line.count < maximumLineBytes else { throw LocalMediaMetadataStreamError.limitExceeded }
            line.append(byte)
        }
    }

    /// 仅在HTTP正常EOF调用；必须既收到终止标记又无残行。返回候选仍需本机版本及fresh资产状态验证。
    func finish() throws -> [LocalMediaRemoteMetadataRecord] {
        guard completed, line.isEmpty else { throw LocalMediaMetadataStreamError.incomplete }
        guard !backupRecords.isEmpty else { return records }
        let decoder = JSONDecoder()
        let official = Set(records.compactMap { record -> CandidateIdentity? in
            guard let metadata = try? decoder.decode(LocalMediaMobileMetadata.self, from: record.value) else { return nil }
            return .init(assetID: record.assetID, metadata: metadata)
        })
        return try records + backupRecords.filter { record in
            let metadata = try decoder.decode(LocalMediaMobileMetadata.self, from: record.value)
            return !official.contains(.init(assetID: record.assetID, metadata: metadata))
        }
    }

    /// data为一条完整UTF8 JSON行；只接受实际请求的实体，未知协议/错误内容不静默变成空匹配。
    private mutating func consume(_ data: Data) throws {
        guard !completed,
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String, let ack = event["ack"] as? String,
              ack.hasPrefix(type + "|"), ack.utf8.count <= 512,
              let payload = event["data"] as? [String: Any] else { throw LocalMediaMetadataStreamError.invalidResponse }
        switch type {
        case "SyncResetV1":
            throw LocalMediaMetadataStreamError.resetRequired
        case "SyncCompleteV1":
            guard UUID(uuidString: String(ack.dropFirst(type.count + 1))) != nil else { throw LocalMediaMetadataStreamError.invalidResponse }
            completed = true
        case "AssetMetadataDeleteV1":
            guard let id = payload["assetId"] as? String, UUID(uuidString: id) != nil,
                  payload["key"] is String else { throw LocalMediaMetadataStreamError.invalidResponse }
        // 未确认过metadata的全量读取只保留当前upsert；删除历史不能创建新的本地关联。
        case "AssetMetadataV1":
            guard let id = payload["assetId"] as? String, let assetID = UUID(uuidString: id),
                  let key = payload["key"] as? String,
                  let value = payload["value"] as? [String: Any] else { throw LocalMediaMetadataStreamError.invalidResponse }
            if key.hasPrefix(PhotoBackupOrigin.keyPrefix) {
                let origin = try JSONDecoder().decode(PhotoBackupOrigin.self, from: JSONSerialization.data(withJSONObject: value))
                try origin.validate()
                guard key == PhotoBackupOrigin.metadataKey(for: origin.metadata.cloudId) else { throw LocalMediaMetadataStreamError.invalidResponse }
                guard cloudIDs?.contains(origin.metadata.cloudId) ?? true else { return }
                guard records.count + backupRecords.count < 200_000 else { throw LocalMediaMetadataStreamError.limitExceeded }
                try backupRecords.append(.init(assetID: assetID, value: JSONEncoder().encode(origin.metadata)))
                return
            }
            guard key == "mobile-app", let cloudID = value["iCloudId"] as? String, cloudIDs?.contains(cloudID) ?? true else { return }
            guard records.count + backupRecords.count < 200_000 else { throw LocalMediaMetadataStreamError.limitExceeded }
            // 不按asset或cloud ID去重：多个候选必须留给领域匹配器明确判为歧义。
            try records.append(.init(assetID: assetID, value: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])))
        default:
            throw LocalMediaMetadataStreamError.invalidResponse
        }
    }
}
