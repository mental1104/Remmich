import Foundation
import Testing
@testable import Remmich

/// 从真实候选构建设备组，并在保存搜索时保留原始别名、其他条件和不支持端点的选择。
@Suite("Capture device groups")
struct NativeCaptureDeviceTests {
    /// 别名只合并已返回的型号；相机/软件不混入设备区，未知设备仍可选择。
    @Test func groupsOnlyModelsPresentInCandidates() throws {
        let options = NativeCaptureDeviceCatalog.options([
            "PP-101", "DJI OsmoPocket3", "PP-101", "AC004", "iPhone 15 Pro", "iPhone 9", "iPhone 10",
            "Insta360 X5", "Synthetic Device", "NIKON Z f", "Canon EOS R", "SONY A7", "ILCE-7M4", "ILCA-99", "DSC-RX1",
            "Lavf60.1", "ReplayKit", "", "   ",
        ])
        let pocket = try #require(options.first { $0.label == "DJI Pocket 3" })
        #expect(Set(pocket.models) == Set(["PP-101", "DJI OsmoPocket3"]))
        #expect(pocket.group == .action)
        let action = try #require(options.first { $0.label == "DJI Action 5 Pro" })
        #expect(action.models == ["AC004"])
        #expect(!action.models.contains("DJI OsmoAction5 Pro"))
        #expect(!options.contains { $0.label == "DJI Mini 4 Pro" })
        #expect(options.filter { $0.group == .iphone }.map(\.label) == ["iPhone 9", "iPhone 10", "iPhone 15 Pro"])
        #expect(options.filter { $0.group == .other }.map(\.label) == ["Synthetic Device"])
        #expect(options.contains { $0.label == "Insta360 X5" && $0.group == .action })
        #expect(NativeCaptureDeviceCatalog.options([]).isEmpty)
    }

    /// 产品名匹配忽略ASCII分隔符大小写，但请求/保存必须保留账号返回的原始字符串。
    @Test func keepsOriginalAliasSpellings() throws {
        let raw = ["dji osmo pocket 3", "PP_101"]
        let option = try #require(NativeCaptureDeviceCatalog.options(raw).first)
        #expect(option.label == "DJI Pocket 3")
        #expect(Set(option.models) == Set(raw))
        #expect(NativeCaptureDeviceCatalog.selectedTitle(raw) == "DJI Pocket 3")
        #expect(NativeCaptureDeviceCatalog.selectedTitle(["Synthetic Device"]) == "Synthetic Device")
    }

    /// 设备单独或组合条件可完整保存恢复；没有候选缓存也不能丢别名或把视频改成照片。
    @Test func roundTripsStandaloneAndCombinedDeviceQueries() throws {
        for smart in [false, true] {
            var query = NativeSearchQuery()
            query.deviceModels = ["DJI OsmoPocket3", "PP-101"]
            if smart {
                query.mode = .smart
                query.text = "synthetic"
                query.media = .video
                query.cameraMake = "Synthetic Make"
                query.cameraModel = "PP-101"
                query.lensModel = "Synthetic Lens"
                query.archivedOnly = true
                query.hasAlbums = false
            }
            let captured = try NativeSearchPresetCodec.capture(query)
            #expect(captured.deviceModels == query.deviceModels)
            let data = try JSONEncoder().encode(captured)
            let decoded = try JSONDecoder().decode(NativeSearchPresetConditions.self, from: data)
            let restored = try NativeSearchPresetCodec.restore(decoded, timeZone: query.timeZone)
            #expect(restored == query)
            #expect(restored.requiresForkSmartSearch == smart)
        }
        var emptyGroup = NativeSearchQuery()
        emptyGroup.text = "synthetic"
        #expect(try NativeSearchPresetCodec.capture(emptyGroup).deviceModels == nil)
    }

    /// 非法登记必须整组拒绝，不能只恢复城市而丢弃设备；上限50项有效。
    @Test func rejectsInvalidSavedAliasesWithoutPartialReuse() throws {
        for models in [[], [""], [" \n"], [String(repeating: "x", count: 257)], Array(repeating: "Synthetic", count: 51)] {
            var conditions = NativeSearchPresetConditions()
            conditions.city = "Synthetic City"
            conditions.deviceModels = models
            #expect(throws: NativeSearchPresetConversionError.self) {
                try NativeSearchPresetCodec.restore(conditions, timeZone: .gmt)
            }
        }
        var boundary = NativeSearchQuery()
        boundary.deviceModels = (1 ... 50).map { "Synthetic \($0)" }
        let captured = try NativeSearchPresetCodec.capture(boundary)
        #expect(try NativeSearchPresetCodec.restore(captured, timeZone: boundary.timeZone) == boundary)
    }
}
