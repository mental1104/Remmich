import Foundation
import Testing
@testable import Remmich

/// 直接消费独立JSONL字节，证明匹配读取只接受完整快照，不把同步终止或元数据当备份确认。
@Suite("Local media metadata stream")
struct LocalMediaMetadataStreamTests {
    /// 任意网络分块不能截坏UTF8；筛选保留完整opaque ID与官方字符串坐标，不读取媒体。
    @Test func preservesRelevantMetadataAcrossByteBoundaries() throws {
        var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: ["照片:opaque-id"])
        try feed(localMetadataRow(cloudID: "other"), to: &decoder)
        try feed(localMetadataRow(cloudID: "照片:opaque-id"), to: &decoder)
        try feed(localMetadataComplete, to: &decoder)
        let records = try decoder.finish()
        #expect(records.count == 1)
        #expect(records.first?.assetID == UUID(uuidString: localMetadataAssetID))
        let record = try #require(records.first)
        let object = try JSONSerialization.jsonObject(with: record.value)
        let value = try #require(object as? [String: String])
        #expect(value == ["iCloudId": "照片:opaque-id", "createdAt": "2020-01-02T03:04:05Z", "latitude": "0", "longitude": "0"])
    }

    /// 重复cloud ID不能被传输层擅自选一个；领域匹配器必须看到全部候选后判歧义。
    @Test func retainsDuplicateCandidatesForAmbiguity() throws {
        var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: ["same"])
        try feed(localMetadataRow(cloudID: "same"), to: &decoder)
        try feed(localMetadataRow(cloudID: "same", assetID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"), to: &decoder)
        try feed(localMetadataComplete, to: &decoder)
        #expect(try decoder.finish().count == 2)
    }

    /// 未匹配的本机ID或其他metadata key都不是错误，也不能伪造关联。
    @Test func ignoresUnrelatedKeysAndCloudIDs() throws {
        var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: ["Wanted"])
        try feed(localMetadataRow(cloudID: "wanted"), to: &decoder)
        try feed(localMetadataRow(cloudID: "Wanted").replacingOccurrences(of: "mobile-app", with: "other-key"), to: &decoder)
        try feed(localMetadataComplete, to: &decoder)
        #expect(try decoder.finish().isEmpty)
    }

    /// 删除历史不能复活已删除关联；完整快照只接收当前upsert。
    @Test func deletionHistoryDoesNotCreateAMatch() throws {
        var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: ["same"])
        try feed("{\"type\":\"AssetMetadataDeleteV1\",\"data\":{\"assetId\":\"\(localMetadataAssetID)\",\"key\":\"mobile-app\"},\"ack\":\"AssetMetadataDeleteV1|\(localMetadataUpdateID)\"}\n", to: &decoder)
        try feed(localMetadataComplete, to: &decoder)
        #expect(try decoder.finish().isEmpty)
    }

    /// 正常EOF之前必须有完整终止行；网络断开不能交出此前已收集候选。
    @Test(arguments: [false, true]) func refusesIncompleteSnapshot(_ partialFinalLine: Bool) throws {
        var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: ["same"])
        try feed(localMetadataRow(cloudID: "same"), to: &decoder)
        if partialFinalLine {
            try feed(String(localMetadataComplete.dropLast()), to: &decoder)
        }
        #expect(throws: LocalMediaMetadataStreamError.incomplete) { try decoder.finish() }
    }

    /// 服务器要求reset时停止；测试不发送任何reset、ack或媒体请求来掩盖该状态。
    @Test func exposesResetRequired() throws {
        var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: ["same"])
        #expect(throws: LocalMediaMetadataStreamError.resetRequired) {
            try feed("{\"type\":\"SyncResetV1\",\"data\":{},\"ack\":\"SyncResetV1|reset\"}\n", to: &decoder)
        }
    }

    /// 非JSON、未知实体、错误ack与非对象payload都使完整读取失败，不能包装成零匹配。
    @Test(arguments: ["not-json\n", "{\"type\":\"FutureV1\",\"data\":{},\"ack\":\"FutureV1|id\"}\n",
                      "{\"type\":\"SyncCompleteV1\",\"data\":{},\"ack\":\"wrong\"}\n",
                      "{\"type\":\"SyncCompleteV1\",\"data\":[],\"ack\":\"SyncCompleteV1|id\"}\n"])
    func refusesInvalidProtocol(_ row: String) throws {
        var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: ["same"])
        #expect(throws: LocalMediaMetadataStreamError.invalidResponse) { try feed(row, to: &decoder) }
    }

    /// 终止之后再出现资源行是损坏流，不能悄悄追加或改变已声明的快照。
    @Test func refusesRowsAfterCompletion() throws {
        var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: ["same"])
        try feed(localMetadataComplete, to: &decoder)
        #expect(throws: LocalMediaMetadataStreamError.invalidResponse) { try feed(localMetadataRow(cloudID: "same"), to: &decoder) }
    }

    /// 单行和总量分别超界时必须失败，不允许截断后宣称未匹配。
    @Test(arguments: [true, false]) func enforcesResponseBounds(_ lineLimit: Bool) throws {
        var decoder = try LocalMediaMetadataStreamDecoder(cloudIDs: ["same"], maximumLineBytes: lineLimit ? 3 : 100,
                                                          maximumResponseBytes: lineLimit ? 100 : 3)
        #expect(throws: LocalMediaMetadataStreamError.limitExceeded) { try feed("1234", to: &decoder) }
    }

    /// metadata已有检查点时只能增量返回；拒绝该前提，保留其他同步实体进度而不重置。
    @Test(arguments: ["AssetMetadataV1", "AssetMetadataDeleteV1"])
    func rejectsPartialSnapshotCheckpoints(_ type: String) throws {
        let data = Data("[{\"type\":\"\(type)\",\"ack\":\"\(type)|\(localMetadataUpdateID)\"}]".utf8)
        #expect(throws: LocalMediaMetadataStreamError.metadataCheckpointExists) {
            try LocalMediaMetadataStreamDecoder.requireFullMetadataSnapshot(data)
        }
    }

    /// 新会话或只有其他实体进度时允许读取，未写入任何ack。
    @Test func acceptsUnacknowledgedMetadataOnly() throws {
        try LocalMediaMetadataStreamDecoder.requireFullMetadataSnapshot(Data("[]".utf8))
        try LocalMediaMetadataStreamDecoder.requireFullMetadataSnapshot(Data("[{\"type\":\"AssetV2\",\"ack\":\"AssetV2|id\"}]".utf8))
        #expect(throws: LocalMediaMetadataStreamError.invalidResponse) {
            try LocalMediaMetadataStreamDecoder.requireFullMetadataSnapshot(Data("{}".utf8))
        }
    }
}

private let localMetadataAssetID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let localMetadataUpdateID = "11111111-1111-4111-8111-111111111111"
private let localMetadataComplete = "{\"type\":\"SyncCompleteV1\",\"data\":{},\"ack\":\"SyncCompleteV1|11111111-1111-4111-8111-111111111111\"}\n"

/// cloudID为不透明合成标识，assetID是合成远端身份；完整wire固定写出，独立于生产编码器。
private func localMetadataRow(cloudID: String, assetID: String = localMetadataAssetID) -> String {
    "{\"type\":\"AssetMetadataV1\",\"data\":{\"assetId\":\"\(assetID)\",\"key\":\"mobile-app\",\"value\":{\"iCloudId\":\"\(cloudID)\",\"createdAt\":\"2020-01-02T03:04:05Z\",\"latitude\":\"0\",\"longitude\":\"0\"}},\"ack\":\"AssetMetadataV1|\(localMetadataUpdateID)\"}\n"
}

/// text为独立协议行；逐字节交付模拟任意UTF8分块，decoder在本函数内推进。
private func feed(_ text: String, to decoder: inout LocalMediaMetadataStreamDecoder) throws {
    for byte in text.utf8 {
        try decoder.append(byte)
    }
}
