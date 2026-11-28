import Foundation
import Testing
@testable import Remmich

@Suite("Display identity bounded stream decoder")
struct LocalPhotoDisplayIdentityStreamTests {
    /// 任意UTF8分块保留完整opaque Cloud ID；三种key及delete均保留原始事件，其他key不能冒充身份。
    @Test func emitsAllKnownSourcesWithoutUpgradingEvidence() throws {
        var decoder = try LocalPhotoDisplayIdentityStreamDecoder()
        let marker = #"{"version":1,"method":"icloud-id","iCloudId":"路径:/L0/001","byteVerified":false}"#
        let backupKey = PhotoBackupOrigin.keyPrefix + String(repeating: "a", count: 64)
        let text = identityStreamRow(key: "mobile-app", value: #"{"iCloudId":"路径:/L0/001"}"#)
            + identityStreamRow(key: "remmich-icloud-match", value: marker)
            + identityStreamRow(key: backupKey, value: #"{"version":1,"method":"sha1","byteVerified":true,"checksum":"AQEBAQEBAQEBAQEBAQEBAQEBAQE=","metadata":{"iCloudId":"路径:/L0/001"}}"#)
            + identityStreamRow(key: "unrelated", value: #"{"iCloudId":"do-not-use"}"#)
            + #"{"type":"AssetMetadataDeleteV1","data":{"assetId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","key":"mobile-app"},"ack":"AssetMetadataDeleteV1|opaque-delete"}"# + "\r\n"
        let events = try identityStreamFeed(text, decoder: &decoder)
        #expect(events.count == 4 && events.map(\.key) == ["mobile-app", "remmich-icloud-match", backupKey, "mobile-app"])
        guard case let .upsert(_, _, value, ack) = events[1] else { Issue.record("Expected the original marker event"); return }
        let object = try JSONSerialization.jsonObject(with: value) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data(marker.utf8)) as? NSDictionary
        #expect(object == expected && ack == "AssetMetadataV1|opaque-update")
        #expect(throws: LocalPhotoDisplayIdentityStreamError.incomplete) { try decoder.finish(batchCount: 1) }
        _ = try identityStreamFeed(identityStreamComplete, decoder: &decoder)
        let receipt = try decoder.finish(batchCount: 1)
        #expect(receipt.rawRowCount == 6 && receipt.recognizedEventCount == 4 && receipt.ignoredMetadataEventCount == 1)
        #expect(try JSONDecoder().decode(LocalPhotoDisplayStreamReceipt.self, from: JSONEncoder().encode(receipt)) == receipt)
    }

    @Test(arguments: ["AssetMetadataV1", "AssetMetadataDeleteV1"])
    func refusesExistingMetadataCoverageCheckpoint(_ type: String) {
        let data = Data("[{\"type\":\"\(type)\",\"ack\":\"opaque-existing\"}]".utf8)
        #expect(throws: LocalPhotoDisplayIdentityStreamError.metadataCheckpointExists) {
            try LocalPhotoDisplayIdentityStreamDecoder.requireUncheckpointedMetadata(data)
        }
    }

    @Test func unrelatedSessionCheckpointsDoNotBlockMetadataSnapshot() throws {
        try LocalPhotoDisplayIdentityStreamDecoder.requireUncheckpointedMetadata(Data("[]".utf8))
        try LocalPhotoDisplayIdentityStreamDecoder.requireUncheckpointedMetadata(Data(#"[{"type":"AssetV2","ack":"opaque-other"}]"#.utf8))
        #expect(throws: LocalPhotoDisplayIdentityStreamError.invalidAckResponse) {
            try LocalPhotoDisplayIdentityStreamDecoder.requireUncheckpointedMetadata(Data("{}".utf8))
        }
    }

    @Test(arguments: ["not-json\n",
                      #"{"type":"AssetMetadataV1","data":{"assetId":"bad","key":"mobile-app","value":{}},"ack":"AssetMetadataV1|id"}"# + "\n",
                      #"{"type":"AssetMetadataV1","data":{"assetId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","key":"mobile-app","value":null},"ack":"AssetMetadataV1|id"}"# + "\n",
                      #"{"type":"AssetMetadataV1","data":{},"ack":"wrong-prefix"}"# + "\n"])
    func malformedFramesCannotBecomeAnEmptyCompleteSnapshot(_ text: String) throws {
        var decoder = try LocalPhotoDisplayIdentityStreamDecoder()
        #expect(throws: LocalPhotoDisplayIdentityStreamError.invalidFrame) { try identityStreamFeed(text, decoder: &decoder) }
    }

    @Test func rejectsUnexpectedResetAndPostCompleteFrames() throws {
        var unknown = try LocalPhotoDisplayIdentityStreamDecoder()
        #expect(throws: LocalPhotoDisplayIdentityStreamError.unexpectedFrame) {
            try identityStreamFeed(#"{"type":"AssetV2","data":{},"ack":"AssetV2|id"}"# + "\n", decoder: &unknown)
        }
        var reset = try LocalPhotoDisplayIdentityStreamDecoder()
        #expect(throws: LocalPhotoDisplayIdentityStreamError.resetRequired) {
            try identityStreamFeed(#"{"type":"SyncResetV1","data":{},"ack":"SyncResetV1|reset"}"# + "\n", decoder: &reset)
        }
        var completed = try LocalPhotoDisplayIdentityStreamDecoder()
        _ = try identityStreamFeed(identityStreamComplete, decoder: &completed)
        #expect(throws: LocalPhotoDisplayIdentityStreamError.frameAfterComplete) {
            try identityStreamFeed(identityStreamRow(), decoder: &completed)
        }
    }

    @Test(arguments: [true, false])
    func refusesBothMissingAndPartialCompletion(_ partial: Bool) throws {
        var decoder = try LocalPhotoDisplayIdentityStreamDecoder()
        _ = try identityStreamFeed(identityStreamRow(), decoder: &decoder)
        if partial {
            _ = try identityStreamFeed(String(identityStreamComplete.dropLast()), decoder: &decoder)
        }
        #expect(throws: LocalPhotoDisplayIdentityStreamError.incomplete) { try decoder.finish(batchCount: 0) }
    }

    @Test func boundsSingleLineAndTotalBytes() throws {
        var line = try LocalPhotoDisplayIdentityStreamDecoder(maximumLineBytes: 3, maximumResponseBytes: 100)
        #expect(throws: LocalPhotoDisplayIdentityStreamError.lineLimitExceeded) { try identityStreamFeed("1234", decoder: &line) }
        var response = try LocalPhotoDisplayIdentityStreamDecoder(maximumLineBytes: 100, maximumResponseBytes: 3)
        #expect(throws: LocalPhotoDisplayIdentityStreamError.responseLimitExceeded) { try identityStreamFeed("1234", decoder: &response) }
    }
}

private nonisolated let identityStreamComplete = #"{"type":"SyncCompleteV1","data":{},"ack":"SyncCompleteV1|11111111-1111-4111-8111-111111111111"}"# + "\n"

private nonisolated func identityStreamRow(key: String = "mobile-app", value: String = #"{"iCloudId":"synthetic-cloud"}"#) -> String {
    #"{"type":"AssetMetadataV1","data":{"assetId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","key":"\#(key)","value":\#(value)},"ack":"AssetMetadataV1|opaque-update"}"# + "\n"
}

private nonisolated func identityStreamFeed(_ text: String, decoder: inout LocalPhotoDisplayIdentityStreamDecoder) throws -> [LocalPhotoDisplayIdentityEvent] {
    var events: [LocalPhotoDisplayIdentityEvent] = []
    for byte in text.utf8 {
        if let event = try decoder.append(byte) {
            events.append(event)
        }
    }
    return events
}
