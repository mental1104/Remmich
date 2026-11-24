import Foundation
import Testing
@testable import Remmich

/// 标签选择与登记的三态不能互换；全部测试只使用合成UUID与名称。
@Suite("Native search tag state")
struct NativeSearchTagTests {
    private static let firstID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private static let secondID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    /// 缺省/null/任一所选标签在metadata和smart登记中完整往返，smart只对激活标签使用Fork。
    @Test(arguments: [NativeSearchQuery.Mode.fileName, .smart])
    func roundTripsEveryTagState(_ mode: NativeSearchQuery.Mode) throws {
        for tags in [NativeSearchTagFilter.any, .untagged, .anyOf([Self.firstID, Self.secondID])] {
            var query = NativeSearchQuery()
            query.mode = mode
            query.text = "synthetic"
            query.tags = tags
            let conditions = try NativeSearchPresetCodec.capture(query)
            let restored = try NativeSearchPresetCodec.restore(conditions, timeZone: query.timeZone)
            #expect(restored == query)
            #expect(restored.requiresForkSmartSearch == (mode == .smart && tags != .any))
            switch tags {
            case .any: #expect(conditions.tagIds == .missing)
            case .untagged: #expect(conditions.tagIds == .null)
            case let .anyOf(ids): #expect(conditions.tagIds == .value(ids))
            }
        }
    }

    /// 单独“无标签”或标签集合就是有效查询，不能保存后因为没有文字而丢掉它。
    @Test func savesTagOnlySearchAndRejectsEmptyOrInvalidSets() throws {
        for tags in [NativeSearchTagFilter.untagged, .anyOf([Self.firstID])] {
            var query = NativeSearchQuery()
            query.tags = tags
            let conditions = try NativeSearchPresetCodec.capture(query)
            #expect(try NativeSearchPresetCodec.restore(conditions, timeZone: query.timeZone).tags == tags)
        }
        for ids in [[], ["invalid"], [Self.firstID, Self.firstID.uppercased()], Array(repeating: Self.firstID, count: 101)] {
            var conditions = NativeSearchPresetConditions()
            conditions.city = "Synthetic City"
            conditions.tagIds = .value(ids)
            #expect(throws: NativeSearchPresetConversionError.self) {
                try NativeSearchPresetCodec.restore(conditions, timeZone: .gmt)
            }
        }
    }

    /// 选择按UUID大小写不敏感；取消最后一项恢复不限制，未改变的绑定值不能清除另一态。
    @Test func selectionTransitionsPreserveMeaning() {
        var filter = NativeSearchTagFilter.untagged
        filter.setSelected(Self.firstID, selected: false)
        #expect(filter == .untagged)
        filter.setSelected(Self.firstID.uppercased(), selected: true)
        #expect(filter.contains(Self.firstID))
        let selected = filter
        filter.setSelected(Self.firstID, selected: true)
        #expect(filter == selected)
        filter.setSelected(Self.secondID, selected: true)
        #expect(filter.selectedIDs.count == 2)
        filter.setSelected(Self.firstID, selected: false)
        #expect(filter == .anyOf([Self.secondID]))
        filter.setSelected(Self.secondID, selected: false)
        #expect(filter == .any)
    }
}
