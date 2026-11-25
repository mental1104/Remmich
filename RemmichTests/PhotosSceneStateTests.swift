import Foundation
import Testing
@testable import Remmich

/// 主Photos的真实异步调度边界，源只控制证据而不替换Store的取消/发布/开关逻辑。
@Suite("Photos scene evidence lifecycle")
@MainActor struct PhotosSceneStateTests {
    /// 同月滚动只查一次；退出再进入必须fresh读取，开关关闭立即撤销所有隐藏权。
    @Test func coalescesWithinMonthButReentersFreshAndCanTurnOff() async {
        let source = PhotosSceneEvidenceSource(outcomes: [.success(.available([stateSceneGroup()])), .success(.available([stateSceneGroup()]))])
        let state = PhotosSceneState()
        let owner = UUID()
        await state.schedule(snapshots: [stateSceneSnapshot()], source: source, owner: owner, revision: 1)?.value
        #expect(state.renderPlan(owner: owner, revision: 1)?.evidence.count == 1)
        #expect(state.renderPlan(owner: UUID(), revision: 1) == nil)
        #expect(state.renderPlan(owner: owner, revision: 2) == nil)
        await state.schedule(snapshots: [stateSceneSnapshot()], source: source, owner: owner, revision: 1)?.value
        #expect(await source.requestedIDs.count == 1)
        #expect(state.toggle(stateSceneGroup().id))
        #expect(state.plan?.expanded == [stateSceneGroup().id])
        state.pause()
        await state.schedule(snapshots: [stateSceneSnapshot()], source: source, owner: owner, revision: 1)?.value
        #expect(await source.requestedIDs.count == 2)
        state.setEnabled(false)
        #expect(state.plan == nil && !state.enabled)
        #expect(!state.toggle(stateSceneGroup().id))
        #expect(state.schedule(snapshots: [stateSceneSnapshot()], source: source, owner: owner, revision: 1) == nil)
        #expect(await source.requestedIDs.count == 2)
    }

    /// 不完整/未加载月份不允许空ids ready探针，不能把配置存在误报为有效manifest。
    @Test func emptySnapshotMakesNoReaderOrQuery() async {
        let source = PhotosSceneEvidenceSource(outcomes: [])
        let state = PhotosSceneState()
        await state.schedule(snapshots: [], source: source, owner: UUID(), revision: 1)?.value
        #expect(await source.factoryCalls == 0)
        #expect(await source.requestedIDs.isEmpty)
        #expect(state.plan == nil && !state.checking && !state.hasFailure)
    }

    /// unsupported/unavailable/HTTP失败均展开全部照片，状态明确并等待Reload；不在后台自动重试。
    @Test(arguments: ["unsupported", "unavailable", "http", "invalid", "overlap"])
    func failedEvidenceUnfoldsEveryAcceptedMonthAndRequiresExplicitReload(_ mode: String) async {
        let outcome: Result<SceneStackAvailability, StateSceneFailure> = switch mode {
        case "unsupported": .success(.unsupported)
        case "unavailable": .success(.unavailable)
        case "http": .failure(.http)
        case "invalid": .success(.available([.init(id: "invalid", coverID: stateSceneA, memberIDs: [stateSceneA, stateSceneC])]))
        default: .success(.available([stateSceneGroup(), .init(id: "overlap", coverID: stateSceneB, memberIDs: [stateSceneB, stateSceneA])]))
        }
        let source = PhotosSceneEvidenceSource(outcomes: [.success(.available([stateSceneGroup()])), outcome, .success(.available([stateSceneGroup()]))])
        let state = PhotosSceneState(); let owner = UUID()
        await state.schedule(snapshots: [stateSceneSnapshot()], source: source, owner: owner, revision: 1)?.value
        #expect(state.plan != nil)
        var next = stateSceneSnapshot()
        next = .init(id: .init(rawValue: "2027-02-01"), revision: 1, assets: next.assets)
        await state.schedule(snapshots: [next], source: source, owner: owner, revision: 1)?.value
        #expect(state.plan == nil && state.hasFailure && !state.checking)
        #expect(!state.status.isEmpty)
        await state.schedule(snapshots: [stateSceneSnapshot()], source: source, owner: owner, revision: 1)?.value
        #expect(await source.requestedIDs.count == 2)
        state.reloadEvidence()
        await state.schedule(snapshots: [stateSceneSnapshot()], source: source, owner: owner, revision: 1)?.value
        #expect(state.plan != nil && !state.hasFailure)
        #expect(await source.requestedIDs.count == 3)
    }

    /// 旧账号证据已在途时换号，迟到结果不覆盖新状态；gate必须真正到达，不以sleep碰运气。
    @Test func lateOldAccountCannotPublishOrHideNewAccountAssets() async {
        let source = PhotosSceneEvidenceSource(outcomes: [.success(.available([stateSceneGroup()])), .success(.available([]))], holdFirst: true)
        let state = PhotosSceneState(); let first = UUID(); let second = UUID()
        let old = state.schedule(snapshots: [stateSceneSnapshot()], source: source, owner: first, revision: 1)
        let watcher = Task { await old?.value; await source.finished() }
        guard await source.waitForGate() else { await watcher.value; Issue.record("Scene source must reach its held request"); return }
        state.invalidate()
        await state.schedule(snapshots: [stateSceneSnapshot()], source: source, owner: second, revision: 1)?.value
        await source.release(); await watcher.value
        #expect(state.renderPlan(owner: first, revision: 1) == nil)
        #expect(state.renderPlan(owner: second, revision: 1) == nil)
        #expect(state.metadataRevision == 1 && !state.hasFailure && !state.checking)
        #expect(await source.requestedIDs.count == 2)
    }

    /// 同一个actor turn取消尚未启动任务，不能先写入旧账号/metadata状态。
    @Test func cancelledBeforeStartCannotInstallOldContext() async {
        let source = PhotosSceneEvidenceSource(outcomes: [])
        let state = PhotosSceneState()
        let pending = state.schedule(snapshots: [stateSceneSnapshot()], source: source, owner: UUID(), revision: 8)
        state.invalidate()
        await pending?.value
        #expect(state.metadataRevision == nil && state.plan == nil)
        #expect(await source.factoryCalls == 0)
    }
}

private nonisolated let stateSceneA = "aaaaaaaa-0000-4000-8000-000000000001"
private nonisolated let stateSceneB = "aaaaaaaa-0000-4000-8000-000000000002"
private nonisolated let stateSceneC = "aaaaaaaa-0000-4000-8000-000000000003"

/// 合法不透明组，成员次序故意与源桶不同，主Photos应以桶顺序为准。
private nonisolated func stateSceneGroup() -> SceneStackGroup {
    .init(id: "scene:state-test/AbC", coverID: stateSceneA, memberIDs: [stateSceneA, stateSceneB])
}

/// 固定完整月份；源桶B在A之前，所有数据均合成。
private nonisolated func stateSceneSnapshot() -> PhotosSceneMonthSnapshot {
    let assets = [stateSceneB, stateSceneA].map { id in
        TimelineAssetSummary(id: id, ownerID: "synthetic", capturedAt: .distantPast, uploadedAt: .distantPast,
                             localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
                             isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
                             projectionType: nil, thumbhash: nil, thumbnailRevision: .distantPast)
    }
    return .init(id: .init(rawValue: "2027-01-01"), revision: 1, assets: assets)
}

/// 有限模拟传输错误，不混同unsupported状态。
private nonisolated enum StateSceneFailure: Error, Sendable { case http }

/// 每次factory/query都可观察；有限脚本缺项失败，实际调度与账号代际仍由生产State处理。
private actor PhotosSceneEvidenceSource: SceneStackProviding, SceneStackReading {
    private var outcomes: [Result<SceneStackAvailability, StateSceneFailure>]
    private let holdFirst: Bool
    private(set) var requestedIDs: [[String]] = []
    private(set) var factoryCalls = 0
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var completed = false
    /// outcomes逐次消费；holdFirst仅在第一次真实query边界挂起。
    init(outcomes: [Result<SceneStackAvailability, StateSceneFailure>], holdFirst: Bool = false) {
        self.outcomes = outcomes; self.holdFirst = holdFirst
    }

    /// 返回同一只读fixture，同时记录工厂调用，验证空快照没有探测。
    func sceneStackReader() async throws -> any SceneStackReading {
        factoryCalls += 1; return self
    }

    /// 本fixture不允许主Photos去扫描月份列表。
    func months() async throws -> [TimelineBucketSummary] {
        throw StateSceneFailure.http
    }

    /// 主Photos必须复用已有完整快照，不额外拉原桶。
    func assets(in _: TimelineBucketID) async throws -> [TimelineAssetSummary] {
        throw StateSceneFailure.http
    }

    /// assets是当前完整快照；返回有限结果，挂起不响应取消以检验生产端迟到响应守卫。
    func groups(for assets: [TimelineAssetSummary]) async throws -> SceneStackAvailability {
        requestedIDs.append(assets.map(\.id))
        guard !outcomes.isEmpty else { throw StateSceneFailure.http }
        let result = outcomes.removeFirst()
        if holdFirst, requestedIDs.count == 1 {
            await withCheckedContinuation { pending = $0; waiter?.resume(returning: true); waiter = nil }
        }
        return try result.get()
    }

    /// 等真实query挂起，若任务提前结束则失败返回，避免挂死掩盖错误。
    func waitForGate() async -> Bool {
        if pending != nil {
            return true
        }
        if completed {
            return false
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// 完成时唤醒没有到gate的等待者；不是把提前结束视为成功。
    func finished() {
        completed = true; waiter?.resume(returning: false); waiter = nil
    }

    /// 释放真实旧结果，之后生产Task必须自行拒绝发布。
    func release() {
        pending?.resume(); pending = nil
    }
}
