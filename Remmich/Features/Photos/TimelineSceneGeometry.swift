import CoreGraphics
import Foundation

/// 场景组解析为原catalog索引；这些索引仍供日期跳转、选择和Viewer使用，不创建第二个过滤catalog。
nonisolated struct ResolvedTimelineScenes: Sendable {
    /// id是不透明组键；children按原完整桶顺序，全部仍引用原asset索引。
    struct Group: Sendable {
        let id: String
        let cover: Int
        let children: [Int]
        let expanded: Bool
        var count: Int {
            children.count + 1
        }
    }

    let covers: [Int: Group]
    let coverByMember: [Int: Int]
    let completeRanges: [Range<Int>]

    /// plan是经服务器验证的完整月份；任何原摘要缺失/变化使该月整组失效，不能基于部分catalog隐藏照片。
    init(plan: TimelineScenePlan, catalog: TimelineSemanticCatalog) {
        var covers: [Int: Group] = [:]
        var membership: [Int: Int] = [:]
        var ranges: [Range<Int>] = []
        for evidence in plan.evidence {
            let originals = evidence.snapshot.assets
            guard !originals.isEmpty, originals.allSatisfy({ asset in
                guard let index = catalog.assetIndexes[asset.id] else { return false }
                return catalog.assets[index] == asset
            }) else { continue }
            let byID = Dictionary(originals.compactMap { asset -> (String, Int)? in
                catalog.assetIndexes[asset.id].map { (asset.id.lowercased(), $0) }
            }, uniquingKeysWith: { first, _ in first })
            var accepted = false
            for group in evidence.groups {
                guard let cover = byID[group.coverID] else { continue }
                let members = group.memberIDs.compactMap { byID[$0] }
                guard members.count == group.memberIDs.count, members.count >= 2,
                      members.contains(cover), members.allSatisfy({ membership[$0] == nil }) else { continue }
                let value = Group(id: group.id, cover: cover, children: members.filter { $0 != cover }, expanded: plan.expanded.contains(group.id))
                covers[cover] = value; members.forEach { membership[$0] = cover }; accepted = true
            }
            if accepted, let lower = byID.values.min(), let upper = byID.values.max() {
                ranges.append(lower ..< upper + 1)
            }
        }
        self.covers = covers; coverByMember = membership; completeRanges = ranges
    }

    /// 原始asset索引可能为已折叠成员，日期跳转/返回以真实封面为几何目标；展开成员仍保持自身索引。
    func visibleAnchor(for original: Int) -> Int {
        guard let cover = coverByMember[original], let group = covers[cover], !group.expanded else { return original }
        return cover
    }

    /// 非单调展开不能按原索引截半个月；凡与请求窗口相交的已验证月扩到完整范围，重叠范围迭代至稳定。
    func completeWindow(_ requested: Range<Int>) -> Range<Int> {
        var result = requested
        var changed = true
        while changed {
            changed = false
            for range in completeRanges where range.overlaps(result) {
                let next = min(result.lowerBound, range.lowerBound) ..< max(result.upperBound, range.upperBound)
                if next != result {
                    result = next; changed = true
                }
            }
        }
        return result
    }
}

/// 仅重排asset细网格几何；日期目录/原始索引/拍摄时间和分组卡片保持原值，关闭即走原投影。
nonisolated enum TimelineSceneGeometry {
    /// original为原完整几何，scenes引用其原catalog索引；所有非封面成员只在原封面日连续显示。
    /// 不修改原摘要，成员原日期仍由其原assetRange索引读取；空掉的显示日不留下幽灵标题。
    static func apply(to original: TimelineSemanticProjection, scenes: ResolvedTimelineScenes, size: CGSize, isPhone: Bool, dark: Bool) -> TimelineSemanticProjection {
        guard original.scale.isAssets, !original.items.isEmpty, size.width > 0, !scenes.covers.isEmpty else { return original }
        // 当前显示日暂存原header与单元；成员移入封面日只改此局部数组，不改变原目录日期。
        struct Day {
            let header: TimelineSemanticProjection.Item
            var cells: [TimelineSemanticProjection.Item]
        }
        var days: [Day] = []
        var byIndex: [Int: TimelineSemanticProjection.Item] = [:]
        for item in original.items {
            if item.isHeader {
                days.append(.init(header: item, cells: []))
            } else {
                byIndex[item.nodeIndex] = item
                if !days.isEmpty {
                    days[days.count - 1].cells.append(item)
                }
            }
        }
        let spacing: CGFloat = original.scale == .natural ? 8 : 2
        let columns = TimelineGridOrder.timelineColumnCount(availableSize: size, minimumLandscapeColumnWidth: isPhone ? 88 : 120, spacing: spacing)
        let baseSide = (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let inset = TimelineGridMetrics.horizontalInset(naturalAspectProgress: original.scale == .natural ? 1 : 0,
                                                        isPhone: isPhone, squareInset: 2, isDarkMode: dark)
        let side = TimelineGridMetrics.itemWidth(rowWidth: size.width, columns: columns, spacing: spacing, horizontalInset: inset)
        var y = TimelineSemanticProjection.topPadding
        var output: [TimelineSemanticProjection.Item] = []
        for day in days {
            var cells: [TimelineSemanticProjection.Item] = []
            var affected = false
            for item in day.cells {
                if let cover = scenes.coverByMember[item.nodeIndex] {
                    affected = true
                    guard item.nodeIndex == cover, let group = scenes.covers[cover] else { continue }
                    cells.append(item)
                    if group.expanded {
                        cells += group.children.compactMap { byIndex[$0] }
                    }
                } else {
                    cells.append(item)
                }
            }
            guard !cells.isEmpty else { continue }
            output.append(moving(day.header, to: CGRect(x: 0, y: y, width: size.width, height: day.header.frame.height)))
            y += day.header.frame.height
            if !affected {
                // 未受场景影响的日期保留原生未填满首行的槽位，只平移前面日期高度变化。
                let delta = y - day.header.frame.maxY
                output += cells.map { moving($0, to: $0.frame.offsetBy(dx: 0, dy: delta)) }
                y = (output.last?.frame.maxY ?? y) + spacing
                continue
            }
            // 原生网格的不足整行位于最旧的首行；连续成员按可视顺序填槽，跨行也不插入其他照片。
            let firstRow = cells.count % columns == 0 ? columns : cells.count % columns
            var position = 0
            var rowCapacity = firstRow
            while position < cells.count {
                let rowCount = min(rowCapacity, cells.count - position)
                for column in 0 ..< rowCount {
                    let frame = CGRect(x: inset + CGFloat(column) * (side + spacing), y: y, width: side, height: baseSide)
                    output.append(moving(cells[position + column], to: frame))
                }
                position += rowCount; rowCapacity = columns; y += baseSide + spacing
            }
        }
        return .init(scale: original.scale, nodeRange: original.nodeRange, items: output,
                     height: y + TimelineSemanticProjection.bottomPadding - spacing)
    }

    /// item的id/nodeIndex/assetRange保持原样，只改变当前显示坐标，不会把选择索引指向另一张照片。
    private static func moving(_ item: TimelineSemanticProjection.Item, to frame: CGRect) -> TimelineSemanticProjection.Item {
        .init(id: item.id, nodeIndex: item.nodeIndex, assetRange: item.assetRange, frame: frame,
              isHeader: item.isHeader, isFeatured: item.isFeatured)
    }
}
