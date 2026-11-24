import Foundation
import Testing
@testable import Remmich

/// 登记编解码必须保留缺省/null/真实值，不吞掉未知条件。
@Suite("Saved search conditions")
struct NativeSearchPresetTests {
    /// 暂未显示的已知字段也必须保留，避免未来改名时损坏登记条件。
    @Test func roundTripPreservesNullAndKnownExtraFields() throws {
        let json = #"{"id":"11111111-1111-4111-8111-111111111111","name":"Synthetic","conditions":{"rating":null,"tagIds":null,"country":"ZZ","mediaCategory":"steam-screenshot","orientation":"landscape","exifConditions":[{"field":"iso","operator":"gte","value":400}]}}"#
        let preset = try JSONDecoder().decode(NativeSearchPreset.self, from: Data(json.utf8))
        #expect(preset.conditions.rating == .null)
        #expect(preset.conditions.tagIds == .null)
        #expect(preset.conditions.mediaCategory == .steamScreenshot)
        #expect(preset.conditions.exifConditions?.first?.comparison == .atLeast)
        let data = try JSONEncoder().encode(preset.conditions)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["rating"] is NSNull)
        #expect(object["tagIds"] is NSNull)
        #expect(object["country"] as? String == "ZZ")
        #expect(object["mediaCategory"] as? String == "steam-screenshot")
        let exif = try #require(object["exifConditions"] as? [[String: Any]])
        #expect(exif.first?["operator"] as? String == "gte")
    }

    /// 缺省字段不能在保存时变成null或默认限制。
    @Test func absentFieldsStayAbsent() throws {
        let conditions = try JSONDecoder().decode(NativeSearchPresetConditions.self, from: Data("{}".utf8))
        #expect(conditions.rating == .missing)
        #expect(conditions.tagIds == .missing)
        let encoded = try JSONEncoder().encode(conditions)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object.isEmpty)
    }

    /// 新版未知规则不能先忽略，再以不完整条件覆盖原登记。
    @Test func rejectsUnknownConditions() throws {
        let json = #"{"id":"11111111-1111-4111-8111-111111111111","name":"Synthetic","conditions":{"futureRule":true}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(NativeSearchPreset.self, from: Data(json.utf8)) }
    }

    /// 零评分与真实标签数组都是指定值，不能误判为缺省。
    @Test func retainsZeroRatingAndTagIDs() throws {
        let json = #"{"rating":0,"tagIds":["11111111-1111-4111-8111-111111111111"]}"#
        let conditions = try JSONDecoder().decode(NativeSearchPresetConditions.self, from: Data(json.utf8))
        #expect(conditions.rating == .value(0))
        #expect(conditions.tagIds == .value(["11111111-1111-4111-8111-111111111111"]))
    }
}
