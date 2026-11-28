import Foundation

/// 仅三类已知资产元数据的原始身份事件；Cloud ID、完整元组和字节证明由消费方分别核验。
nonisolated enum LocalPhotoDisplayIdentityEvent: Equatable, Sendable {
    case upsert(assetID: UUID, key: String, value: Data, ack: String)
    case delete(assetID: UUID, key: String, ack: String)

    var assetID: UUID {
        switch self { case let .upsert(id, _, _, _), let .delete(id, _, _): id }
    }

    var key: String {
        switch self { case let .upsert(_, key, _, _), let .delete(_, key, _): key }
    }

    var ack: String {
        switch self { case let .upsert(_, _, _, ack), let .delete(_, _, ack): ack }
    }
}

/// 只有SyncComplete与正常EOF均通过才签发；计数匿名，不证明Photos已完成匹配。
nonisolated struct LocalPhotoDisplayStreamReceipt: Codable, Equatable, Sendable {
    let completeAck: String
    /// 所有非空JSONL frame，包括最终SyncComplete。
    let rawRowCount: Int
    /// 已识别三类key的upsert/delete数量。
    let recognizedEventCount: Int
    let ignoredMetadataEventCount: Int
    let batchCount: Int
}

/// HTTP状态沿用LibraryWriteError.http，传输错误保留URLError；此类型只表示覆盖/协议边界。
nonisolated enum LocalPhotoDisplayIdentityStreamError: Error, Equatable, Sendable {
    case metadataCheckpointExists
    case invalidAckResponse
    case invalidResponse
    case invalidFrame
    case unexpectedFrame
    case frameAfterComplete
    case resetRequired
    case incomplete
    case lineLimitExceeded
    case responseLimitExceeded
}

/// 独立展示身份JSONL解码器；只保留一行，不累计候选或将流前缀视作完整证据快照。
nonisolated struct LocalPhotoDisplayIdentityStreamDecoder {
    private let maximumLineBytes: Int
    private let maximumResponseBytes: Int
    private var receivedBytes = 0
    private var line: [UInt8] = []
    private var completeAck: String?
    private(set) var rawRowCount = 0
    private(set) var recognizedEventCount = 0
    private(set) var ignoredMetadataEventCount = 0

    init(maximumLineBytes: Int = 262_144, maximumResponseBytes: Int = 536_870_912) throws {
        guard maximumLineBytes > 0, maximumResponseBytes > 0 else { throw LocalPhotoDisplayIdentityStreamError.invalidResponse }
        self.maximumLineBytes = maximumLineBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    /// ACK是当前Bearer认证session的checkpoint；读取不授予修改、删除或重置该session进度的权限。
    static func requireUncheckpointedMetadata(_ data: Data) throws {
        struct Ack: Decodable { let type: String; let ack: String }
        guard let acks = try? JSONDecoder().decode([Ack].self, from: data),
              acks.allSatisfy({ !$0.type.isEmpty && !$0.ack.isEmpty }) else { throw LocalPhotoDisplayIdentityStreamError.invalidAckResponse }
        guard !acks.contains(where: { $0.type == "AssetMetadataV1" || $0.type == "AssetMetadataDeleteV1" }) else {
            throw LocalPhotoDisplayIdentityStreamError.metadataCheckpointExists
        }
    }

    static func isKnownMetadataKey(_ key: String) -> Bool {
        key == "mobile-app" || key == LocalMediaDisplayCloudIdentity.metadataKey || key.hasPrefix(PhotoBackupOrigin.keyPrefix)
    }

    /// bytes可跨任意UTF8/JSON网络分块；只有完整换行后才产生单个typed事件。
    mutating func append(_ byte: UInt8) throws -> LocalPhotoDisplayIdentityEvent? {
        guard receivedBytes < maximumResponseBytes else { throw LocalPhotoDisplayIdentityStreamError.responseLimitExceeded }
        receivedBytes += 1
        guard byte == 10 else {
            guard line.count < maximumLineBytes else { throw LocalPhotoDisplayIdentityStreamError.lineLimitExceeded }
            line.append(byte)
            return nil
        }
        if line.last == 13 {
            line.removeLast()
        }
        guard !line.isEmpty else { return nil }
        let data = Data(line)
        line.removeAll(keepingCapacity: true)
        return try consume(data)
    }

    /// 仅HTTP正常EOF后调用；batchCount只计已交给consumer的批次，consumer失败时调用方不能返回此receipt。
    func finish(batchCount: Int) throws -> LocalPhotoDisplayStreamReceipt {
        guard let completeAck, line.isEmpty, batchCount >= 0 else { throw LocalPhotoDisplayIdentityStreamError.incomplete }
        return .init(completeAck: completeAck, rawRowCount: rawRowCount, recognizedEventCount: recognizedEventCount,
                     ignoredMetadataEventCount: ignoredMetadataEventCount, batchCount: batchCount)
    }

    private mutating func consume(_ data: Data) throws -> LocalPhotoDisplayIdentityEvent? {
        guard completeAck == nil else { throw LocalPhotoDisplayIdentityStreamError.frameAfterComplete }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = envelope["type"] as? String,
              let ack = envelope["ack"] as? String, ack.hasPrefix(type + "|"), ack.utf8.count <= 512,
              ack.utf8.count > type.utf8.count + 1,
              let payload = envelope["data"] as? [String: Any] else { throw LocalPhotoDisplayIdentityStreamError.invalidFrame }
        rawRowCount += 1
        switch type {
        case "SyncResetV1":
            throw LocalPhotoDisplayIdentityStreamError.resetRequired
        case "SyncCompleteV1":
            guard UUID(uuidString: String(ack.dropFirst(type.count + 1))) != nil, payload.isEmpty else {
                throw LocalPhotoDisplayIdentityStreamError.invalidFrame
            }
            completeAck = ack
            return nil
        case "AssetMetadataV1", "AssetMetadataDeleteV1":
            guard let id = payload["assetId"] as? String, let assetID = UUID(uuidString: id),
                  let key = payload["key"] as? String, !key.isEmpty else { throw LocalPhotoDisplayIdentityStreamError.invalidFrame }
            let value: Data?
            if type == "AssetMetadataV1" {
                guard let object = payload["value"] as? [String: Any],
                      let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                else {
                    throw LocalPhotoDisplayIdentityStreamError.invalidFrame
                }
                value = encoded
            } else {
                value = nil
            }
            guard Self.isKnownMetadataKey(key) else {
                ignoredMetadataEventCount += 1
                return nil
            }
            recognizedEventCount += 1
            if let value {
                return .upsert(assetID: assetID, key: key, value: value, ack: ack)
            }
            return .delete(assetID: assetID, key: key, ack: ack)
        default:
            throw LocalPhotoDisplayIdentityStreamError.unexpectedFrame
        }
    }
}
