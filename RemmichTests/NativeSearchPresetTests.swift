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

    /// 保存后在相同时区恢复所有已支持条件，跨夏令时仍保持用户选定的日历日。
    @Test func restoresFullQueryAcrossDaylightSavingBoundary() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var conditions = NativeSearchPresetConditions()
        conditions.query = .init(value: "Synthetic", type: .ocr)
        conditions.city = "Synthetic City"
        conditions.country = "Synthetic Country"
        conditions.state = "Synthetic State"
        conditions.make = "Synthetic Make"
        conditions.model = "Synthetic Model"
        conditions.lensModel = "Synthetic Lens"
        conditions.personIds = ["11111111-1111-4111-8111-111111111111"]
        conditions.mediaType = .image
        conditions.albumStatus = .notInAlbum
        conditions.orientation = .landscape
        conditions.takenAfter = "2026-03-08"
        conditions.takenBefore = "2026-11-01"
        conditions.exifConditions = [.init(field: .iso, comparison: .atLeast, value: 400)]
        let query = try NativeSearchPresetCodec.restore(conditions, timeZone: zone)
        #expect(query.mode == .ocr)
        #expect(query.media == .image)
        #expect(query.hasAlbums == false)
        #expect(query.personIDs == conditions.personIds)
        let captured = try NativeSearchPresetCodec.capture(query)
        #expect(captured.takenAfter == "2026-03-08")
        #expect(captured.takenBefore == "2026-11-01")
        #expect(captured.city == conditions.city)
        #expect(captured.country == conditions.country)
        #expect(captured.state == conditions.state)
        #expect(captured.make == conditions.make)
        #expect(captured.model == conditions.model)
        #expect(captured.lensModel == conditions.lensModel)
        #expect(captured.orientation == .landscape)
        #expect(captured.exifConditions == conditions.exifConditions)
        #expect(try NativeSearchPresetCodec.restore(captured, timeZone: zone) == query)
    }

    /// 文件名登记使用服务端metadata类型，空查询不创建无意义登记。
    @Test func capturesFilenameAndRejectsEmptyQuery() throws {
        var query = NativeSearchQuery()
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.capture(query) }
        query.text = "  Synthetic.JPG  "
        let conditions = try NativeSearchPresetCodec.capture(query)
        #expect(conditions.query?.type == .metadata)
        #expect(conditions.query?.value == "Synthetic.JPG")
    }

    /// 单独收藏或归档条件可以保存；关闭开关须省略字段，不能写出服务端不支持的false。
    @Test func roundTripsFavoriteAndArchiveFlags() throws {
        for (favorites, archived) in [(true, false), (false, true), (true, true)] {
            var query = NativeSearchQuery()
            query.favoritesOnly = favorites
            query.archivedOnly = archived
            let conditions = try NativeSearchPresetCodec.capture(query)
            #expect(conditions.isFavorite == (favorites ? true : nil))
            #expect(conditions.isArchive == (archived ? true : nil))
            #expect(try NativeSearchPresetCodec.restore(conditions, timeZone: query.timeZone) == query)
        }
        var invalid = NativeSearchPresetConditions()
        invalid.isFavorite = false
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.restore(invalid, timeZone: .gmt) }
    }

    /// rating覆盖镜头独立及组合查询；无文本/型号也可保存，评分缺省/null/0/5不丢失。
    @Test(arguments: [NativeSearchRating.any, .unrated, .stars(0), .stars(5)])
    func roundTripsLensSearchWithRatings(_ rating: NativeSearchRating) throws {
        var query = NativeSearchQuery()
        query.lensModel = "Synthetic Lens"
        query.rating = rating
        let conditions = try NativeSearchPresetCodec.capture(query)
        #expect(conditions.lensModel == "Synthetic Lens")
        #expect(try NativeSearchPresetCodec.restore(conditions, timeZone: query.timeZone) == query)
    }

    /// 评分缺省/null/0/具体值在保存和复用后不互相混淆，越界评分明确拒绝。
    @Test func roundTripsAllRatingStates() throws {
        for rating in [NativeSearchRating.any, .unrated, .stars(0), .stars(1), .stars(5)] {
            var query = NativeSearchQuery()
            query.city = "Synthetic City"
            query.rating = rating
            let conditions = try NativeSearchPresetCodec.capture(query)
            let restored = try NativeSearchPresetCodec.restore(conditions, timeZone: query.timeZone)
            #expect(restored == query)
            switch rating {
            case .any: #expect(conditions.rating == .missing)
            case .unrated: #expect(conditions.rating == .null)
            case let .stars(value): #expect(conditions.rating == .value(value))
            }
        }
        var invalid = NativeSearchQuery()
        invalid.rating = .stars(6)
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.capture(invalid) }
    }

    /// 暂不支持的条件必须整组拒绝，不能把复用变成只有城市的部分搜索。
    @Test func rejectsPartialRestoration() throws {
        var conditions = NativeSearchPresetConditions()
        conditions.city = "Synthetic City"
        conditions.tagIds = .null
        #expect(throws: NativeSearchPresetConversionError.self) {
            try NativeSearchPresetCodec.restore(conditions, timeZone: .gmt)
        }
    }

    /// 非法日期、倒序日期及重复数值运算符均不能成为可执行搜索。
    @Test func rejectsInvalidConditions() throws {
        var conditions = NativeSearchPresetConditions()
        conditions.takenAfter = "2026-02-30"
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.restore(conditions, timeZone: .gmt) }
        conditions.takenAfter = "2026-11-02"
        conditions.takenBefore = "2026-11-01"
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.restore(conditions, timeZone: .gmt) }
        conditions.takenAfter = nil
        conditions.takenBefore = nil
        conditions.exifConditions = [.init(field: .iso, comparison: .atLeast, value: 400), .init(field: .iso, comparison: .atLeast, value: 800)]
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.restore(conditions, timeZone: .gmt) }
    }
}
