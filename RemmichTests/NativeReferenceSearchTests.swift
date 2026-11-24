import Foundation
import Testing
@testable import Remmich

/// 参考图入口、完整登记复用和分页快照只使用合成身份，不访问图片或服务器。
@Suite("Native reference search")
struct NativeReferenceSearchTests {
    /// 选择参考图只替换文字来源；随后输入文字清除参考图，当前模式及全部筛选保留。
    @Test func switchesQuerySourceWithoutLosingFilters() throws {
        var query = referenceQuery()
        query.text = "synthetic"
        let original = query
        query.useReferenceAsset("22222222-2222-4222-8222-222222222222")
        #expect(query.text.isEmpty)
        #expect(query.mode == .smart)
        #expect(query.requiresForkSmartSearch)
        var expected = original
        expected.text = ""
        expected.mode = .smart
        expected.queryAssetID = "22222222-2222-4222-8222-222222222222"
        #expect(query == expected)

        let restored = try NativeSearchPresetCodec.restore(NativeSearchPresetCodec.capture(query), timeZone: query.timeZone)
        #expect(restored == query)
        query.useSearchText("another synthetic query")
        expected.queryAssetID = nil
        expected.text = "another synthetic query"
        #expect(query == expected)
        let textConditions = try NativeSearchPresetCodec.capture(query)
        #expect(textConditions.queryAssetId == nil)
        #expect(textConditions.query?.value == "another synthetic query")
    }

    /// 只有参考图也能保存；恢复后即使没有高级筛选，也必须使用独立Fork分页。
    @Test func restoresReferenceOnlyAndClearsItExplicitly() throws {
        var query = NativeSearchQuery()
        query.useReferenceAsset("22222222-2222-4222-8222-222222222222")
        let conditions = try NativeSearchPresetCodec.capture(query)
        #expect(conditions.query == nil)
        #expect(conditions.queryAssetId == query.queryAssetID)
        let bytes = try JSONEncoder().encode(conditions)
        let decoded = try JSONDecoder().decode(NativeSearchPresetConditions.self, from: bytes)
        let restored = try NativeSearchPresetCodec.restore(decoded, timeZone: query.timeZone)
        #expect(restored == query)
        #expect(restored.requiresForkSmartSearch)
        query.queryAssetID = nil
        #expect(!query.requiresForkSmartSearch)
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.capture(query) }
    }

    /// reference为无效UUID/版本/variant；保存和恢复都整组拒绝，不只应用剩下的筛选。
    @Test(arguments: ["", "not-an-asset", "00000000-0000-0000-0000-000000000000",
                      "22222222-2222-5222-8222-222222222222", "22222222-2222-4222-7222-222222222222"])
    func rejectsInvalidReferences(_ reference: String) throws {
        var query = referenceQuery()
        query.useReferenceAsset(reference)
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.capture(query) }
        var conditions = NativeSearchPresetConditions()
        conditions.queryAssetId = reference
        conditions.city = "Synthetic City"
        #expect(throws: NativeSearchPresetConversionError.self) {
            try NativeSearchPresetCodec.restore(conditions, timeZone: .gmt)
        }
    }

    /// 文字和参考图不是可叠加条件；非smart参考图同样不能变成丢失参考图的登记。
    @Test func rejectsConflictingSourcesAndModes() throws {
        var query = referenceQuery()
        query.useReferenceAsset("22222222-2222-4222-8222-222222222222")
        query.text = "synthetic"
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.capture(query) }
        query.text = ""
        query.mode = .ocr
        #expect(throws: NativeSearchPresetConversionError.self) { try NativeSearchPresetCodec.capture(query) }
        var conditions = NativeSearchPresetConditions()
        conditions.queryAssetId = query.queryAssetID
        conditions.query = .init(value: "synthetic", type: .smart)
        #expect(throws: NativeSearchPresetConversionError.self) {
            try NativeSearchPresetCodec.restore(conditions, timeZone: .gmt)
        }
    }

    /// store固定首屏的参考图/筛选快照；外部值变化不能让旧Fork游标带上新查询。
    @Test @MainActor func paginationUsesTheOriginalReferenceSnapshot() async {
        var query = referenceQuery()
        query.useReferenceAsset("22222222-2222-4222-8222-222222222222")
        let source = ReferencePageSource(expected: query)
        let store = NativeSearchStore()
        await store.search(query, source: source)
        #expect(store.continuation == .forkCursor("reference-next"))
        query.useReferenceAsset("33333333-3333-4333-8333-333333333333")
        await store.loadMore(source: source)
        #expect(store.continuation == nil)
        #expect(await source.calls == 2)
        #expect(store.error == nil)
    }
}

/// 返回覆盖全部既有原生筛选的合成查询；无设备相册、GPS或账号副作用。
private nonisolated func referenceQuery() -> NativeSearchQuery {
    var query = NativeSearchQuery()
    query.media = .image
    query.country = "Synthetic Country"
    query.state = "Synthetic State"
    query.city = "Synthetic City"
    query.cameraMake = "Synthetic Make"
    query.cameraModel = "Synthetic Model"
    query.lensModel = "Synthetic Lens"
    query.personIDs = ["11111111-1111-4111-8111-111111111111"]
    query.rating = .unrated
    query.favoritesOnly = true
    query.archivedOnly = true
    query.orientation = .landscape
    query.hasAlbums = false
    query.exifConditions = [.init(field: .iso, comparison: .atLeast, value: 400)]
    query.timeZone = .gmt
    query.takenAfter = Date(timeIntervalSince1970: 0)
    query.takenBefore = Date(timeIntervalSince1970: 0)
    return query
}

/// expected固定一次搜索的完整条件；记录页次并核对Fork游标，不执行网络。
private actor ReferencePageSource: NativeSearchReading {
    let expected: NativeSearchQuery
    private(set) var calls = 0

    /// expected为首屏快照，后续页必须逐字段相同。
    init(expected: NativeSearchQuery) {
        self.expected = expected
    }

    /// query必须等于首屏；continuation仅为nil或上页Fork令牌，返回不含私人资源的两页。
    func search(_ query: NativeSearchQuery, continuation: NativeSearchContinuation?) async throws -> NativeSearchPage {
        #expect(query == expected)
        calls += 1
        #expect(continuation == (calls == 1 ? nil : .forkCursor("reference-next")))
        return .init(assets: [], continuation: calls == 1 ? .forkCursor("reference-next") : nil)
    }
}
