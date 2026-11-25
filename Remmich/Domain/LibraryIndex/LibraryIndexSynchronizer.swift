import Foundation

nonisolated enum LibraryIndexSyncMode: Sendable {
    case recent
    case historical
    case incremental
    case fullReconciliation
}

nonisolated struct LibraryIndexSyncResult: Sendable {
    let mode: LibraryIndexSyncMode
    let generation: Int64
    let indexedAssetCount: Int
    let indexedPhotoCount: Int
    let indexedVideoCount: Int
    let expectedAssetCount: Int
    let hasMoreHistory: Bool
    let cleanup: LibraryIndexGenerationCleanup
    var hasPendingBucketChanges = false
    var removedBucketKeys: [String] = []
    var removedBucketAssetCount = 0

    var isComplete: Bool {
        !hasMoreHistory && !hasPendingBucketChanges
    }
}

nonisolated struct LibraryIndexProgress: Sendable {
    let indexedAssetCount: Int
    let indexedPhotoCount: Int
    let indexedVideoCount: Int
    let expectedAssetCount: Int
}

actor LibraryIndexSynchronizer {
    private let source: any TimelineReading
    private let store: any LibraryIndexStoring
    private let batchSize: Int

    init(source: any TimelineReading, store: any LibraryIndexStoring, batchSize: Int = 2) {
        self.source = source
        self.store = store
        self.batchSize = max(1, batchSize)
    }

    /// scope为隔离账号；recentOnly保留原短同步范围，dateProjections额外强制已验证日期的旧/新月。
    /// validateContext在异步边界拒绝退休上下文，nil保持原行为；progress报告已读取数量，返回原子接受结果。
    func synchronizeRecent(
        scope: MediaAccountScope,
        recentOnly: Bool = false,
        dateProjections: [AssetMetadataDateProjection] = [],
        validateContext: (@Sendable () async throws -> Void)? = nil,
        progress: (@Sendable (LibraryIndexProgress) async -> Void)? = nil
    ) async throws -> LibraryIndexSyncResult {
        let snapshot = try await store.snapshot(scope: scope)
        return try await synchronize(
            scope: scope,
            mode: snapshot == nil ? .recent : .incremental,
            fullReconciliation: false,
            recentOnly: recentOnly,
            dateProjections: dateProjections,
            validateContext: validateContext,
            progress: progress
        )
    }

    func resumeHistorical(
        scope: MediaAccountScope,
        progress: (@Sendable (LibraryIndexProgress) async -> Void)? = nil
    ) async throws -> LibraryIndexSyncResult {
        try await synchronize(
            scope: scope,
            mode: .historical,
            fullReconciliation: false,
            progress: progress
        )
    }

    /// scope指定账号；显式全量同步仍读所有桶，日期需求另须fresh完整性核对，context失效则拒绝接受。
    /// progress为原进度回调，返回本次接受代际；空dateProjections与nil validator保持原有契约。
    func fullSyncAndVerify(
        scope: MediaAccountScope,
        dateProjections: [AssetMetadataDateProjection] = [],
        validateContext: (@Sendable () async throws -> Void)? = nil,
        progress: (@Sendable (LibraryIndexProgress) async -> Void)? = nil
    ) async throws -> LibraryIndexSyncResult {
        try await synchronize(
            scope: scope,
            mode: .fullReconciliation,
            fullReconciliation: true,
            dateProjections: dateProjections,
            validateContext: validateContext,
            progress: progress
        )
    }

    /// 按mode/范围读取完整桶并复用原接受事务；可选日期投影及context只为日期pass增加写前一致性门禁。
    /// scope隔离持久数据，fullReconciliation决定是否复制旧代际，recentOnly限制普通选择，progress报告读取进度。
    private func synchronize(
        scope: MediaAccountScope,
        mode: LibraryIndexSyncMode,
        fullReconciliation: Bool,
        recentOnly: Bool = false,
        dateProjections: [AssetMetadataDateProjection] = [],
        validateContext: (@Sendable () async throws -> Void)? = nil,
        progress: (@Sendable (LibraryIndexProgress) async -> Void)?
    ) async throws -> LibraryIndexSyncResult {
        try await validateContext?()
        try await store.prepare(scope: scope)
        let previous = try await store.snapshot(scope: scope)
        guard previous?.syncState.isPaused != true else {
            guard dateProjections.isEmpty else { throw AssetMetadataError.dateRefreshUnavailable }
            return .init(
                mode: mode,
                generation: previous?.generation ?? 0,
                indexedAssetCount: previous?.syncState.indexedAssetCount ?? 0,
                indexedPhotoCount: previous?.assets.count { $0.kind == .image } ?? 0,
                indexedVideoCount: previous?.assets.count { $0.kind == .video } ?? 0,
                expectedAssetCount: previous?.syncState.expectedAssetCount ?? 0,
                hasMoreHistory: previous?.syncState.historicalCursor != nil,
                cleanup: .init(
                    generation: previous?.generation ?? 0,
                    removedGenerations: 0,
                    removedAssetRows: 0,
                    removedGroupRows: 0
                )
            )
        }

        do {
            // 日期需求只使用原仓库代际绑定的前台读取器，不能重播持久GET或集合缓存。
            try await validateContext?()
            let reader: any TimelineReading
            if dateProjections.isEmpty {
                reader = source
            } else {
                guard let provider = source as? any ManagementTimelineProviding else {
                    throw AssetMetadataError.dateRefreshUnavailable
                }
                reader = try await provider.managementTimelineReader()
            }
            let summaries = try await reader.bucketSummaries(query: .init())
                .sorted { $0.id.rawValue > $1.id.rawValue }
            try await validateContext?()
            let expectedCount = summaries.reduce(0) { $0 + $1.assetCount }
            let serverBucketKeys = Set(summaries.map(\.id.rawValue))
            let removedBuckets = Set(previous?.assets.map(\.bucketKey) ?? []).subtracting(serverBucketKeys)
            let removedAssetCount = previous?.assets.count { removedBuckets.contains($0.bucketKey) } ?? 0
            let ordinary = bucketsToFetch(
                summaries: summaries,
                previous: previous,
                mode: mode,
                fullReconciliation: fullReconciliation,
                recentOnly: recentOnly
            )
            // 旧桶只来自真正accepted记录，新桶只匹配fresh详情的服务器墙上年月。
            let dateAssetIDs = Set(dateProjections.map { $0.assetID.lowercased() })
            let oldDateBuckets = Set(previous?.assets.filter { dateAssetIDs.contains($0.id.lowercased()) }.map(\.bucketKey) ?? [])
            let forced = summaries.filter { summary in
                oldDateBuckets.contains(summary.id.rawValue) || dateProjections.contains { $0.occupiesMonth(summary.id) }
            }
            let forcedKeys = Set(forced.map(\.id.rawValue))
            let selected = Self.deduplicate(ordinary + forced)
            try Task.checkCancellation()

            // Refreshing a bucket does not remove its accepted local records.
            // Replace its contribution only after its new response arrives.
            let acceptedBuckets = Dictionary(grouping: fullReconciliation ? [] : previous?.assets ?? [], by: \.bucketKey)
            let retainedAssets = previous?.assets.filter { !removedBuckets.contains($0.bucketKey) } ?? []
            var progressCounts = Self.progress(from: fullReconciliation ? [] : retainedAssets, expectedAssetCount: expectedCount)
            // The complete summary response can omit months whose last asset
            // was removed. Empty replacements retire those copied local rows
            // only after every requested bucket has successfully loaded.
            var replacements = Dictionary(uniqueKeysWithValues: removedBuckets.map { ($0, [LibraryIndexAssetRecord]()) })
            var dateMembers: [TimelineAssetSummary] = []
            for summary in selected {
                try Task.checkCancellation()
                let assets = try await reader.assets(in: summary.id, query: .init())
                try await validateContext?()
                if forcedKeys.contains(summary.id.rawValue) {
                    guard assets.count == summary.assetCount,
                          Set(assets.map { $0.id.lowercased() }).count == assets.count,
                          assets.allSatisfy({ Self.belongsToMonth($0.captureLocalDate, bucket: summary.id) })
                    else {
                        throw AssetMetadataError.dateProjectionChanged
                    }
                    dateMembers.append(contentsOf: assets)
                }
                let records = assets.map {
                    LibraryIndexAssetRecord(asset: $0, bucketID: summary.id)
                }
                replacements[summary.id.rawValue] = records
                progressCounts = progressCounts.replacing(acceptedBuckets[summary.id.rawValue] ?? [], with: records)
                await progress?(progressCounts)
            }

            // 同query缺少stack子项不允许手工插入；任何目标日期变化/半桶都保留原accepted代际。
            for projection in dateProjections {
                let matches = dateMembers.filter { $0.id.lowercased() == projection.assetID.lowercased() }
                guard matches.count == 1 else { throw AssetMetadataError.dateAssetNotVisible }
                guard projection.matches(matches[0]) else { throw AssetMetadataError.dateProjectionChanged }
            }

            // 串行完整月仍可能在并发迁移中重复非目标资产；先核全局唯一，避免SQLite覆盖行而groups重复计数。
            let verifiedDateAssets = dateProjections.isEmpty ? nil : mergedAssets(
                previous: fullReconciliation ? nil : previous,
                replacing: replacements
            )
            if let verifiedDateAssets {
                guard Set(verifiedDateAssets.map { $0.id.lowercased() }).count == verifiedDateAssets.count else {
                    throw AssetMetadataError.dateProjectionChanged
                }
            }

            // Durable transfers may be replayed after suspension. Do not copy an
            // accepted generation until every selected response is available.
            try Task.checkCancellation()
            try await validateContext?()
            let generation = if fullReconciliation {
                try await store.beginReconciliation(scope: scope)
            } else {
                try await store.beginGeneration(scope: scope)
            }
            try await store.removeAssets(
                in: Set(replacements.keys),
                generation: generation,
                scope: scope
            )
            for records in replacements.values {
                try await store.upsert(assets: records, generation: generation, scope: scope)
            }
            let stagedAssets = verifiedDateAssets ?? mergedAssets(
                previous: fullReconciliation ? nil : previous,
                replacing: replacements
            )
            let stagedCounts = Dictionary(grouping: stagedAssets, by: \.bucketKey).mapValues(\.count)
            let hasPendingBucketChanges = recentOnly && summaries.contains {
                stagedCounts[$0.id.rawValue, default: 0] != $0.assetCount
            }
            try await store.replace(
                groups: LibraryIndexCatalogBuilder.build(from: stagedAssets),
                generation: generation,
                scope: scope
            )
            let nextCursor = fullReconciliation ? nil : summaries
                .first { !Set(stagedAssets.map(\.bucketKey)).contains($0.id.rawValue) }?
                .id.rawValue
            try Task.checkCancellation()
            try await validateContext?()
            try Task.checkCancellation()
            let cleanup = try await store.acceptGeneration(
                generation,
                watermark: stagedAssets.map(\.updatedAt).max(),
                historicalCursor: nextCursor,
                expectedAssetCount: expectedCount,
                scope: scope
            )
            try await store.setLastError(nil, scope: scope)
            return .init(
                mode: mode,
                generation: generation,
                indexedAssetCount: stagedAssets.count,
                indexedPhotoCount: stagedAssets.count { $0.kind == .image },
                indexedVideoCount: stagedAssets.count { $0.kind == .video },
                expectedAssetCount: expectedCount,
                hasMoreHistory: nextCursor != nil,
                cleanup: cleanup,
                hasPendingBucketChanges: hasPendingBucketChanges,
                removedBucketKeys: removedBuckets.sorted(),
                removedBucketAssetCount: removedAssetCount
            )
        } catch {
            if !(error is CancellationError) {
                try? await store.setLastError(Self.message(for: error), scope: scope)
            }
            throw error
        }
    }

    /// date是实际成员的墙上日期；只在现有桶的UTC年月内接受完整替换，不自造桶或改变过滤范围。
    private static func belongsToMonth(_ date: Date, bucket: TimelineBucketID) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite, let start = bucket.displayDate else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.year, .month], from: date) == calendar.dateComponents([.year, .month], from: start)
    }

    private func bucketsToFetch(
        summaries: [TimelineBucketSummary],
        previous: LibraryIndexSnapshot?,
        mode: LibraryIndexSyncMode,
        fullReconciliation: Bool,
        recentOnly: Bool
    ) -> [TimelineBucketSummary] {
        if recentOnly {
            return Array(summaries.prefix(batchSize))
        }
        guard !fullReconciliation else { return summaries }
        switch mode {
        case .recent:
            return Array(summaries.prefix(batchSize))
        case .historical:
            let indexed = Set(previous?.assets.map(\.bucketKey) ?? [])
            return Array(summaries.filter { !indexed.contains($0.id.rawValue) }.prefix(batchSize))
        case .incremental:
            let indexedCounts = Dictionary(grouping: previous?.assets ?? [], by: \.bucketKey)
                .mapValues(\.count)
            let suspect = summaries.filter { indexedCounts[$0.id.rawValue] != $0.assetCount }
            return Self.deduplicate(Array(summaries.prefix(batchSize)) + suspect)
        case .fullReconciliation:
            return summaries
        }
    }

    private func mergedAssets(
        previous: LibraryIndexSnapshot?,
        replacing replacements: [String: [LibraryIndexAssetRecord]]
    ) -> [LibraryIndexAssetRecord] {
        let replacedBuckets = Set(replacements.keys)
        let retained = previous?.assets.filter { !replacedBuckets.contains($0.bucketKey) } ?? []
        return (retained + replacements.values.flatMap(\.self))
            .sorted { lhs, rhs in
                lhs.capturedAt == rhs.capturedAt ? lhs.id < rhs.id : lhs.capturedAt < rhs.capturedAt
            }
    }

    private static func deduplicate(_ summaries: [TimelineBucketSummary]) -> [TimelineBucketSummary] {
        var seen = Set<TimelineBucketID>()
        return summaries.filter { seen.insert($0.id).inserted }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static func progress(
        from assets: [LibraryIndexAssetRecord],
        expectedAssetCount: Int
    ) -> LibraryIndexProgress {
        .init(
            indexedAssetCount: assets.count,
            indexedPhotoCount: assets.count { $0.kind == .image },
            indexedVideoCount: assets.count { $0.kind == .video },
            expectedAssetCount: expectedAssetCount
        )
    }
}

private extension LibraryIndexProgress {
    nonisolated func replacing(_ previous: [LibraryIndexAssetRecord], with assets: [LibraryIndexAssetRecord]) -> LibraryIndexProgress {
        .init(
            indexedAssetCount: indexedAssetCount - previous.count + assets.count,
            indexedPhotoCount: indexedPhotoCount - previous.count { $0.kind == .image } + assets.count { $0.kind == .image },
            indexedVideoCount: indexedVideoCount - previous.count { $0.kind == .video } + assets.count { $0.kind == .video },
            expectedAssetCount: expectedAssetCount
        )
    }
}

private nonisolated enum LibraryIndexCatalogBuilder {
    static func build(from assets: [LibraryIndexAssetRecord]) -> [LibraryIndexGroupRecord] {
        LibraryIndexMediaScope.allCases.flatMap { scope in
            let scopedAssets = assets.filter { scope == .videos ? $0.kind == .video : $0.kind != .video }
            return ["day", "week", "month", "year"].flatMap { level in
                build(level: level, assets: scopedAssets, mediaScope: scope)
            }
        }
    }

    private static func build(
        level: String,
        assets: [LibraryIndexAssetRecord],
        mediaScope: LibraryIndexMediaScope
    ) -> [LibraryIndexGroupRecord] {
        let groups = Dictionary(grouping: assets) { asset in
            switch level {
            case "day": asset.dayKey
            case "week": asset.weekKey
            case "month": asset.monthKey
            default: asset.yearKey
            }
        }
        return groups.compactMap { key, members in
            let sorted = members.sorted { $0.capturedAt < $1.capturedAt }
            guard let start = members.map(\.captureLocalDate).min(),
                  let end = members.map(\.captureLocalDate).max() else { return nil }
            return LibraryIndexGroupRecord(
                mediaScope: mediaScope,
                level: level,
                key: key,
                intervalStart: start,
                intervalEnd: end.addingTimeInterval(0.001),
                assetCount: sorted.count,
                owningBucketKeys: Array(Set(sorted.map(\.bucketKey))).sorted(),
                coverAssetIDs: boundedIDs(from: sorted, limit: 12),
                mosaicSeed: stableSeed("\(mediaScope.rawValue):\(level):\(key):\(sorted.count)")
            )
        }
        .sorted { $0.intervalStart < $1.intervalStart }
    }

    private static func boundedIDs(from assets: [LibraryIndexAssetRecord], limit: Int) -> [String] {
        guard assets.count > limit else { return assets.map(\.id) }
        return (0 ..< limit).map { slot in
            assets[slot * (assets.count - 1) / (limit - 1)].id
        }
    }

    private static func stableSeed(_ value: String) -> UInt64 {
        value.utf8.reduce(1_469_598_103_934_665_603) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

private extension LibraryIndexAssetRecord {
    nonisolated init(asset: TimelineAssetSummary, bucketID: TimelineBucketID) {
        let keys = LibraryIndexCaptureDateKeys(localDate: asset.captureLocalDate)
        self.init(
            id: asset.id,
            ownerID: asset.ownerID,
            kind: asset.mediaKind.libraryIndexKind,
            livePhotoVideoID: asset.livePhotoVideoID,
            capturedAt: asset.capturedAt,
            uploadedAt: asset.uploadedAt,
            updatedAt: asset.thumbnailRevision,
            checksum: nil,
            width: nil,
            height: nil,
            aspectRatio: asset.aspectRatio,
            durationMilliseconds: asset.durationMilliseconds,
            isFavorite: asset.isFavorite,
            visibility: asset.visibility.libraryIndexValue,
            isTrashed: false,
            isOffline: false,
            bucketKey: bucketID.rawValue,
            dayKey: keys.day,
            weekKey: keys.week,
            monthKey: keys.month,
            yearKey: keys.year,
            localOffsetHours: asset.localOffsetHours,
            stackID: asset.stack?.id,
            stackAssetCount: asset.stack?.assetCount,
            projectionType: asset.projectionType,
            thumbhash: asset.thumbhash
        )
    }
}

private extension TimelineVisibility {
    nonisolated var libraryIndexValue: String {
        switch self {
        case .archive: "archive"
        case .timeline: "timeline"
        case .hidden: "hidden"
        case .locked: "locked"
        case let .unknown(value): value
        }
    }
}
