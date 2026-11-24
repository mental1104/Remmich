import Foundation
import Testing
@testable import Remmich

/// 媒体筛选使用Web现有保存协议，单独与组合条件都必须完整恢复。
@Suite("Saved media search conditions")
struct NativeSearchMediaPresetTests {
    /// category/resolution遍历服务端现有有限值；文本、全景和基础条件在编码后不能丢失。
    @Test(arguments: NativeSearchMediaCategory.allCases, NativeSearchResolution.allCases)
    func roundTripsMediaConditions(_ category: NativeSearchMediaCategory, _ resolution: NativeSearchResolution) throws {
        var query = NativeSearchQuery()
        query.mode = .smart
        query.text = "synthetic"
        query.mediaCategory = category
        query.resolution = resolution
        query.panoramasOnly = true
        query.city = "Synthetic City"
        query.rating = .stars(0)
        let captured = try NativeSearchPresetCodec.capture(query)
        #expect(captured.mediaCategory == category)
        #expect(captured.resolution == resolution)
        #expect(captured.isPanorama == true)
        let encoded = try JSONEncoder().encode(captured)
        let decoded = try JSONDecoder().decode(NativeSearchPresetConditions.self, from: encoded)
        let restored = try NativeSearchPresetCodec.restore(decoded, timeZone: query.timeZone)
        #expect(restored == query)
        #expect(restored.requiresForkSmartSearch)
    }

    /// 单独一个媒体条件也可保存；不把开关关闭误写为isPanorama:false。
    @Test func roundTripsStandaloneMediaConditions() throws {
        var category = NativeSearchQuery()
        category.mediaCategory = .steamScreenshot
        var resolution = NativeSearchQuery()
        resolution.resolution = .fourK
        var panorama = NativeSearchQuery()
        panorama.panoramasOnly = true
        for query in [category, resolution, panorama] {
            let captured = try NativeSearchPresetCodec.capture(query)
            #expect(captured.isPanorama == (query.panoramasOnly ? true : nil))
            #expect(try NativeSearchPresetCodec.restore(captured, timeZone: query.timeZone) == query)
        }
        var invalid = NativeSearchPresetConditions()
        invalid.isPanorama = false
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.restore(invalid, timeZone: .gmt) }
    }
}
