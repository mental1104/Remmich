import Foundation
import Photos
import Synchronization
import Testing
@testable import Remmich

/// 自动化只调度安全的新/未尝试项；真实Controller、Coordinator、Worker、HTTP客户端和SQLite保留各自生产职责。
@Suite("Foreground automatic backup")
struct PhotoBackupAutomaticTests {
    /// 旧头缺少可选开关时关闭；启用必须已有明确保存选择，回写不能改动包含/排除或iCloud同意。
    @Test func legacyDefaultAndSavedConsent() throws {
        var empty = PhotoBackupJournal(namespace: "synthetic")
        #expect(empty.foregroundAutomaticEnabled == nil)
        let legacy = try JSONDecoder().decode(PhotoBackupJournal.Header.self, from: Data(#"{"version":1,"namespace":"synthetic","selectedAlbumIDs":[],"allowCloud":false}"#.utf8))
        #expect(legacy.foregroundAutomaticEnabled == nil)
        #expect(throws: PhotoBackupStateError.invalidJournal) { try empty.setForegroundAutomaticEnabled(true) }
        let selection = try PhotoBackupAlbumSelection(included: ["include"], excluded: ["exclude"])
        try empty.applyAlbumScan(selection.scan([.init(id: "include", assets: []), .init(id: "exclude", assets: [])]), allowCloud: true)
        try empty.setForegroundAutomaticEnabled(true)
        let restored = try JSONDecoder().decode(PhotoBackupJournal.Header.self, from: JSONEncoder().encode(empty.header))
        #expect(restored.foregroundAutomaticEnabled == true && restored.allowCloud)
        #expect(restored.selectedAlbumIDs == ["include"] && restored.excludedAlbumIDs == ["exclude"])
        try empty.setForegroundAutomaticEnabled(false)
        #expect(empty.foregroundAutomaticEnabled == false && empty.allowCloud)
    }

    /// 不恢复失败/取消/已有尝试或部分Live回执；完成项保持完成，安全未尝试项可排队，排除项取消。
    @Test func automaticPlanPreservesHistoryAndPartialPairs() throws {
        let names = ["completed", "failed", "cancelled", "attempted", "partial-live", "safe", "excluded"]
        let sources = names.map { PhotoBackupSource(localID: $0, modifiedAt: nil, kind: $0 == "partial-live" ? .livePhoto : .photo) }
        let selection = try PhotoBackupAlbumSelection(included: ["include"], excluded: ["exclude"])
        var journal = PhotoBackupJournal(namespace: "synthetic")
        let snapshots = [PhotoBackupAlbumSnapshot(id: "include", assets: sources.map { .init(source: $0, capturedAt: nil) }), .init(id: "exclude", assets: [])]
        try journal.applyAlbumScan(selection.scan(snapshots), allowCloud: false)
        let ids = journal.jobs.map(\.id)
        try journal.update(ids[0]) { job in
            try job.begin(); try job.exported(); try job.recordPrimary(UUID(), duplicate: true); try job.confirmVerifiedReceipt()
        }
        try journal.update(ids[1]) { $0.fail(.network) }
        try journal.update(ids[2]) { $0.cancel() }
        try journal.update(ids[3]) { try $0.begin(); $0.pause() }
        let motion = UUID()
        try journal.update(ids[4]) { try $0.begin(); try $0.exported(); try $0.recordMotion(motion); $0.pause() }
        try journal.update(ids[5]) { $0.pause() }
        let fresh = PhotoBackupSource(localID: "fresh", modifiedAt: nil, kind: .photo)
        let changedCancelled = PhotoBackupSource(localID: "cancelled", modifiedAt: Date(timeIntervalSince1970: 20), kind: .photo)
        let actual = try selection.scan([
            .init(id: "include", assets: (sources + [fresh, changedCancelled]).filter { $0.localID != "cancelled" || $0.modifiedAt != nil }.map { .init(source: $0, capturedAt: nil) }),
            .init(id: "exclude", assets: [.init(source: sources[6], capturedAt: nil)]),
        ])
        try journal.setForegroundAutomaticEnabled(true)
        #expect(try journal.applyAutomaticAlbumScan(actual) == 1)
        #expect(journal.jobs.prefix(7).map(\.stage) == [.completed, .failed, .cancelled, .paused, .paused, .queued, .cancelled])
        #expect(journal.jobs[4].motionAssetID == motion && journal.jobs[4].primaryAssetID == nil)
        #expect(journal.jobs.last?.source == fresh && journal.jobs.last?.attempts == 0)
        #expect(journal.jobs.filter { $0.source.localID == "cancelled" }.count == 1)
        try journal.validate(namespace: "synthetic")
    }

    /// 自动扫描不能凭调用方草稿扩大范围；精确保存规则不一致时任何既有任务都不改变。
    @Test func refusesDifferentSavedSelection() throws {
        var journal = PhotoBackupJournal(namespace: "synthetic")
        let saved = try PhotoBackupAlbumSelection(included: ["include"], excluded: ["exclude"])
        try journal.applyAlbumScan(saved.scan([.init(id: "include", assets: []), .init(id: "exclude", assets: [])]), allowCloud: false)
        try journal.setForegroundAutomaticEnabled(true)
        let wider = try PhotoBackupAlbumSelection(included: ["include"], excluded: [])
        #expect(throws: PhotoBackupStateError.invalidTransition) { try journal.applyAutomaticAlbumScan(wider.scan([.init(id: "include", assets: [])])) }
        #expect(journal.jobs.isEmpty && journal.excludedAlbumIDs == ["exclude"])
    }

    /// 手动重排后仍为queued的已尝试项也是未知历史；自动计划不能借新版本绕过同localID保护。
    @Test func manuallyRequeuedAttemptCannotBecomeAnAutomaticNewVersion() throws {
        let old = PhotoBackupSource(localID: "attempted", modifiedAt: Date(timeIntervalSince1970: 1), kind: .photo)
        let newer = PhotoBackupSource(localID: "attempted", modifiedAt: Date(timeIntervalSince1970: 2), kind: .photo)
        let selection = try PhotoBackupAlbumSelection(included: ["include"], excluded: [])
        var journal = PhotoBackupJournal(namespace: "synthetic")
        try journal.applyAlbumScan(selection.scan([.init(id: "include", assets: [.init(source: old, capturedAt: nil)])]), allowCloud: false)
        let id = try #require(journal.jobs.first?.id)
        try journal.update(id) { try $0.begin(); $0.pause(); $0.queueForVerification() }
        try journal.setForegroundAutomaticEnabled(true)
        #expect(try journal.applyAutomaticAlbumScan(selection.scan([.init(id: "include", assets: [.init(source: newer, capturedAt: nil)])])) == 0)
        #expect(journal.jobs.count == 1 && journal.jobs.first?.source == old && journal.jobs.first?.stage == .cancelled)
        #expect(journal.jobs.first?.attempts == 1)
    }

    /// 默认关闭及权限未授予均不扫描、不导出、不发请求；自动入口不调用会弹授权的相簿列表读取器。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor func disabledOrDeniedDoesNotReadPhotos(_ denied: Bool) async throws {
        try await withAutomaticBackupFixture(enabled: denied) { fixture in
            fixture.port.authorization = denied ? .denied : .authorized
            await fixture.activate()?.value
            #expect(fixture.port.scans == 0 && fixture.port.permissionPrompts == 0)
            #expect(fixture.exporter.observations.isEmpty && fixture.server.counts == [0, 0])
            #expect(try await fixture.coldJournal().foregroundAutomaticEnabled == denied)
        }
    }

    /// 已保存排除相簿失效时停止并保存关闭，不能按空排除扩大备份范围；原规则完整保留。
    @Test(.timeLimit(.minutes(1))) @MainActor func missingExclusionDisablesAutomationBeforeAnyExport() async throws {
        try await withAutomaticBackupFixture(enabled: true) { fixture in
            fixture.port.exclusionMissing = true
            await fixture.activate()?.value
            let cold = try await fixture.coldJournal()
            #expect(cold.foregroundAutomaticEnabled == false && cold.excludedAlbumIDs == ["exclude"] && cold.jobs.isEmpty)
            #expect(fixture.exporter.observations.isEmpty && fixture.server.counts == [0, 0])
            #expect(!fixture.controller.foregroundAutomaticEnabled && !fixture.controller.running)
        }
    }

    /// 已保存iCloud选项原样交给真实Worker；实际SHA1/官方查重/fresh GET成功后才落盘完成，重触发不重传。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor func usesSavedConsentAndCoalescesNewPhotoEvents(_ cloud: Bool) async throws {
        try await withAutomaticBackupFixture(enabled: true, cloud: cloud) { fixture in
            await fixture.activate()?.value
            #expect(fixture.exporter.observations.map(\.allowCloud) == [cloud])
            #expect(fixture.exporter.observations.map(\.stage) == [.exporting])
            #expect(fixture.server.counts == [1, 1])
            let completed = try await fixture.coldJournal()
            #expect(completed.jobs.map(\.stage) == [.completed] && completed.jobs.first?.attempts == 1)
            #expect(fixture.controller.completed == 1 && fixture.controller.duplicates == 1)
            await fixture.request()?.value
            #expect(fixture.server.counts == [1, 1] && fixture.exporter.observations.count == 1)
            fixture.port.sources.append(.init(localID: "new-screenshot", modifiedAt: nil, kind: .photo))
            await fixture.request()?.value
            #expect(fixture.server.counts == [2, 2] && fixture.exporter.observations.count == 2)
            #expect(try await fixture.coldJournal().jobs.allSatisfy { $0.stage == .completed })
            #expect(fixture.port.permissionPrompts == 0 && fixture.exporter.directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    /// 开关只保存自动化同意，不把未扫描草稿保存；同账号重读与下一次自动事件也不能覆盖草稿。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor func draftBlocksEnableAndExistingAutomation(_ previouslyEnabled: Bool) async throws {
        try await withAutomaticBackupFixture(enabled: previouslyEnabled) { fixture in
            await fixture.controller.load(using: fixture.manager)
            fixture.controller.excluded = ["draft-exclude"]
            fixture.controller.allowCloud = true
            await fixture.activate()?.value
            await fixture.controller.setForegroundAutomaticEnabled(true, using: fixture.manager)
            await fixture.request()?.value
            await fixture.controller.load(using: fixture.manager)
            #expect(fixture.controller.excluded == ["draft-exclude"] && fixture.controller.allowCloud && fixture.controller.requiresSelectionScan)
            let cold = try await fixture.coldJournal()
            #expect(cold.foregroundAutomaticEnabled == previouslyEnabled && cold.excludedAlbumIDs == ["exclude"] && !cold.allowCloud)
            #expect(fixture.port.scans == 0 && fixture.server.counts == [0, 0])
        }
    }

    /// 用户明确开启只更新当前账号日志头并调度一次；此前保存的包含/排除和iCloud同意不改写。
    @Test(.timeLimit(.minutes(1))) @MainActor func explicitEnablePersistsAndRunsTheSavedSelection() async throws {
        try await withAutomaticBackupFixture(enabled: false, cloud: true) { fixture in
            await fixture.controller.load(using: fixture.manager)
            await fixture.activate()?.value
            #expect(fixture.exporter.observations.isEmpty)
            await fixture.controller.setForegroundAutomaticEnabled(true, using: fixture.manager)
            await fixture.request()?.value
            let cold = try await fixture.coldJournal()
            #expect(cold.foregroundAutomaticEnabled == true && cold.allowCloud)
            #expect(cold.selectedAlbumIDs == ["include"] && cold.excludedAlbumIDs == ["exclude"])
            #expect(cold.jobs.map(\.stage) == [.completed] && fixture.exporter.observations.map(\.allowCloud) == [true])
            #expect(fixture.server.counts == [1, 1] && !fixture.controller.configuringAutomatic)
        }
    }

    /// Worker真实await期间多次照片事件只合并下一次扫描；同源只导出/查重/回读一次，没有第二个并发上传器。
    @Test(.timeLimit(.minutes(1))) @MainActor func repeatedEventsShareOneWorkerAndOnePendingScan() async throws {
        try await withAutomaticBackupFixture(enabled: true) { fixture in
            fixture.exporter.hold = true
            let first = fixture.activate()
            try #require(await fixture.exporter.waitUntilHeld())
            let second = fixture.request(), third = fixture.request()
            fixture.exporter.release()
            await first?.value; await second?.value; await third?.value
            #expect(fixture.port.scans == 2 && fixture.exporter.observations.count == 1 && fixture.server.counts == [1, 1])
            #expect(try await fixture.coldJournal().jobs.first?.stage == .completed)
            #expect(!fixture.controller.running && !fixture.manager.busy)
        }
    }

    /// 旧自动Task等待真实手动Worker退役时再次退役/激活；已取消旧epoch不能先消费最新周期的pending请求。
    @Test(.timeLimit(.minutes(1))) @MainActor func cancelledRetirementWaitersCannotConsumeTheNewActiveRequest() async throws {
        try await withAutomaticBackupFixture(enabled: true) { fixture in
            var saved = try await fixture.coldJournal()
            try saved.enqueue(fixture.port.sources)
            try await fixture.store.savePhotoBackups(saved, scope: fixture.scope)
            await fixture.controller.load(using: fixture.manager)
            fixture.exporter.hold = true
            let manual = fixture.resumeManually()
            try #require(await fixture.exporter.waitUntilHeld())
            let oldAutomatic = fixture.activate()
            await fixture.exporter.waitUntilCancellation()
            let inactive = fixture.controller.automaticConditionsChanged(using: fixture.manager, scope: fixture.scope, active: false)
            let latest = fixture.activate()
            fixture.port.sources.append(.init(localID: "new-active-cycle", modifiedAt: nil, kind: .photo))
            fixture.exporter.hold = false
            fixture.exporter.release()
            await manual?.value; await oldAutomatic?.value; await inactive?.value; await latest?.value
            let cold = try await fixture.coldJournal()
            #expect(cold.jobs.map(\.stage) == [.paused, .completed] && cold.foregroundAutomaticEnabled == true)
            #expect(fixture.port.scans == 1 && fixture.exporter.observations.map(\.localID) == ["first", "new-active-cycle"])
            #expect(fixture.server.counts == [1, 1] && !fixture.controller.running && !fixture.manager.busy)
        }
    }

    /// 已进入真实导出await时产生草稿，取消旧周期；迟到资源不能上传，重读和后续事件都保留未保存草稿。
    @Test(.timeLimit(.minutes(1))) @MainActor func draftDuringExportRetiresWithoutSavingDraft() async throws {
        try await withAutomaticBackupFixture(enabled: true) { fixture in
            fixture.exporter.hold = true
            let old = fixture.activate()
            try #require(await fixture.exporter.waitUntilHeld())
            fixture.controller.excluded = ["draft-exclude"]
            fixture.controller.allowCloud = true
            await fixture.exporter.waitUntilCancellation()
            fixture.exporter.release()
            await old?.value
            await fixture.controller.load(using: fixture.manager)
            await fixture.request()?.value
            let cold = try await fixture.coldJournal()
            #expect(cold.foregroundAutomaticEnabled == true && cold.jobs.first?.stage == .paused)
            #expect(cold.excludedAlbumIDs == ["exclude"] && !cold.allowCloud)
            #expect(fixture.controller.excluded == ["draft-exclude"] && fixture.controller.allowCloud && fixture.controller.requiresSelectionScan)
            #expect(fixture.exporter.observations.count == 1 && fixture.server.counts == [0, 0])
        }
    }

    /// A账号真实await期间换到B；旧回执和配置不能发布到B，B默认关闭且其冷日志为空，A仅保留中断事实。
    @Test(.timeLimit(.minutes(1))) @MainActor func accountRetirementRejectsLateResourcesAndKeepsSettingsIsolated() async throws {
        try await withAutomaticBackupFixture(enabled: true, cloud: true) { fixture in
            fixture.exporter.hold = true
            let old = fixture.activate()
            try #require(await fixture.exporter.waitUntilHeld())
            let session = AccountSession(apiURL: fixture.endpoint, accessToken: "foreground-other", userID: "88888888-8888-4888-8888-888888888888",
                                         userEmail: "other@example.invalid", name: "Other", isAdmin: false,
                                         serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
            let other = MediaAccountScope(session: session)
            fixture.manager.configure(session: session, endpoint: fixture.endpoint)
            // 换号只退役scope，保留实际active值；新账号不得继承A的自动规则或iCloud同意。
            let next = fixture.controller.automaticConditionsChanged(using: fixture.manager, scope: other)
            fixture.exporter.release()
            await next?.value; await old?.value
            await fixture.controller.load(using: fixture.manager)
            let coldA = try await fixture.coldJournal()
            let coldB = try await SQLiteLibraryIndexStore(databaseURL: fixture.database).loadPhotoBackups(scope: other)
            #expect(coldA.foregroundAutomaticEnabled == true && coldA.allowCloud && coldA.jobs.first?.stage == .exporting)
            #expect(coldA.jobs.first?.primaryAssetID == nil)
            #expect(coldB.foregroundAutomaticEnabled == nil && coldB.jobs.isEmpty && !coldB.allowCloud)
            #expect(fixture.controller.jobs.isEmpty && !fixture.controller.foregroundAutomaticEnabled && !fixture.controller.allowCloud)
            #expect(!fixture.controller.running && !fixture.manager.busy && fixture.server.counts == [0, 0])
        }
    }

    /// 实际导出await中撤销Photos授权，即使旧系统边界返回资源也不发HTTP或发布成功，冷日志保留未知状态并关闭规则。
    @Test(.timeLimit(.minutes(1))) @MainActor func permissionRetirementRejectsLateResources() async throws {
        try await withAutomaticBackupFixture(enabled: true) { fixture in
            fixture.exporter.hold = true
            let old = fixture.activate()
            try #require(await fixture.exporter.waitUntilHeld())
            fixture.port.authorization = .denied
            fixture.exporter.release()
            await old?.value
            let cold = try await fixture.coldJournal()
            #expect(cold.foregroundAutomaticEnabled == false && cold.jobs.first?.stage == .exporting)
            #expect(cold.jobs.first?.primaryAssetID == nil && fixture.controller.completed == 0)
            #expect(!fixture.controller.running && !fixture.manager.busy && fixture.server.counts == [0, 0])
        }
    }

    /// 真正停在Worker导出await后手动停止；先取消并退役再保存关闭，重启读取仍关闭，Photos事件不复活任务。
    @Test(.timeLimit(.minutes(1))) @MainActor func manualStopPersistsOffAfterAwaitedWorkerRetirement() async throws {
        try await withAutomaticBackupFixture(enabled: true) { fixture in
            fixture.exporter.hold = true
            let old = fixture.activate()
            try #require(await fixture.exporter.waitUntilHeld())
            #expect(fixture.controller.automaticRunning && fixture.manager.busy)
            let repeated = fixture.request()
            let stop = fixture.stopManually()
            // stop先进入取消路径，等待真实worker退役；导出门随后只释放旧资源，不替业务任务提供成功。
            await fixture.exporter.waitUntilCancellation()
            fixture.exporter.release()
            await stop.value; await old?.value; await repeated?.value
            let cold = try await fixture.coldJournal()
            #expect(cold.foregroundAutomaticEnabled == false && cold.jobs.first?.stage == .paused && cold.jobs.first?.attempts == 1)
            #expect(cold.jobs.first?.primaryAssetID == nil && !fixture.controller.running && !fixture.manager.busy)
            await fixture.request()?.value
            #expect(fixture.exporter.observations.count == 1 && fixture.server.counts == [0, 0])
        }
    }

    /// 后台取消保留开关但不自动重试已经开始的未知项；新前台周期只处理尚未尝试的新资源。
    @Test(.timeLimit(.minutes(1))) @MainActor func backgroundCancellationDoesNotRetryAnAttemptedSource() async throws {
        try await withAutomaticBackupFixture(enabled: true) { fixture in
            fixture.exporter.hold = true
            let old = fixture.activate()
            try #require(await fixture.exporter.waitUntilHeld())
            let retirement = fixture.controller.automaticConditionsChanged(using: fixture.manager, scope: fixture.scope, active: false)
            fixture.exporter.release()
            await retirement?.value; await old?.value
            #expect(try await fixture.coldJournal().foregroundAutomaticEnabled == true)
            fixture.exporter.hold = false
            fixture.port.sources.append(.init(localID: "after-background", modifiedAt: nil, kind: .photo))
            await fixture.activate()?.value
            let cold = try await fixture.coldJournal()
            #expect(cold.jobs.map(\.stage) == [.paused, .completed])
            #expect(cold.jobs.map(\.attempts) == [1, 1] && fixture.server.counts == [1, 1])
            #expect(fixture.exporter.observations.map(\.localID) == ["first", "after-background"])
        }
    }

    /// 真实HTTP非成功回执自动关闭规则；后续Photos事件保持失败事实，不触发网络重试或伪造完成。
    @Test(.timeLimit(.minutes(1))) @MainActor func unconfirmedHTTPStopsWithoutAutomaticRetry() async throws {
        try await withAutomaticBackupFixture(enabled: true, failingHTTP: true) { fixture in
            await fixture.activate()?.value
            let cold = try await fixture.coldJournal()
            #expect(cold.jobs.first?.stage == .failed && cold.jobs.first?.primaryAssetID == nil)
            #expect(cold.foregroundAutomaticEnabled == false && fixture.controller.completed == 0 && fixture.controller.failed == 1)
            await fixture.request()?.value
            #expect(fixture.server.counts == [1, 0] && fixture.exporter.observations.count == 1)
        }
    }
}

/// 断网后的明确尾队列恢复复用真实Controller/Worker/客户端；未知项仍须由用户选择原单项核查路径。
@Suite("Explicit unattempted backup recovery")
struct PhotoBackupUnattemptedRecoveryTests {
    /// 计数完整划分队列；部分Live回执/手动重排未知项不伪装未尝试，恢复只排原队列仍符合保存规则的安全项。
    @Test func summaryAndPlanKeepUnknownAndTerminalHistory() throws {
        let names = ["completed", "failed", "cancelled", "partial", "requeued", "safe", "moved-out"]
        let sources = names.map { PhotoBackupSource(localID: $0, modifiedAt: nil, kind: $0 == "partial" ? .livePhoto : .photo) }
        let selection = try PhotoBackupAlbumSelection(included: ["include"], excluded: ["exclude"])
        var journal = PhotoBackupJournal(namespace: "synthetic")
        try journal.applyAlbumScan(selection.scan([.init(id: "include", assets: sources.map { .init(source: $0, capturedAt: nil) }), .init(id: "exclude", assets: [])]), allowCloud: true)
        let ids = journal.jobs.map(\.id)
        try journal.update(ids[0]) { try $0.begin(); try $0.exported(); try $0.recordPrimary(UUID(), duplicate: true); try $0.confirmVerifiedReceipt() }
        try journal.update(ids[1]) { $0.fail(.network) }
        try journal.update(ids[2]) { $0.cancel() }
        let motion = UUID()
        try journal.update(ids[3]) { try $0.begin(); try $0.exported(); try $0.recordMotion(motion); $0.pause() }
        try journal.update(ids[4]) { try $0.begin(); $0.pause(); $0.queueForVerification() }
        try journal.update(ids[5]) { $0.pause() }
        try journal.update(ids[6]) { $0.pause() }
        let summary = PhotoBackupUnattemptedSummary(jobs: journal.jobs)
        #expect(summary.eligibleJobIDs == Set([ids[5], ids[6]]))
        #expect(summary.failed == 1 && summary.cancelled == 1 && summary.completed == 1 && summary.attemptedOrUnconfirmed == 2)
        let new = PhotoBackupSource(localID: "not-in-the-saved-queue", modifiedAt: nil, kind: .photo)
        let scan = try selection.scan([.init(id: "include", assets: (Array(sources.dropLast()) + [new]).map { .init(source: $0, capturedAt: nil) }), .init(id: "exclude", assets: [])])
        #expect(try journal.resumeUnattempted(scan) == 1)
        #expect(journal.jobs.map(\.stage) == [.completed, .failed, .cancelled, .paused, .paused, .queued, .cancelled])
        #expect(journal.jobs.count == 7 && journal.jobs[3].motionAssetID == motion && journal.allowCloud)
        #expect(journal.jobs[4].attempts == 1 && journal.jobs[1].failure == .network)
    }

    /// 实际自动周期收到503后关闭规则；新SQLite/controller仅继续未尝试尾项，随后明确单项重试仍重新SHA1查重/fresh GET。
    @Test(.timeLimit(.minutes(1))) @MainActor func networkFailureColdRecoveryAndExplicitUnknownRetryRemainSeparate() async throws {
        try await withAutomaticBackupFixture(enabled: true, cloud: true, failingHTTP: true) { fixture in
            fixture.port.sources.append(.init(localID: "unattempted-tail", modifiedAt: nil, kind: .photo))
            await fixture.activate()?.value
            let interrupted = try await fixture.coldJournal()
            #expect(interrupted.jobs.map(\.stage) == [.failed, .paused] && interrupted.jobs.map(\.attempts) == [1, 0])
            #expect(interrupted.foregroundAutomaticEnabled == false && fixture.server.counts == [1, 0])
            fixture.server.setFailing(false)
            let cold = fixture.coldController()
            await cold.load(using: fixture.manager)
            #expect(cold.unattemptedSummary.eligibleJobIDs.count == 1 && cold.unattemptedSummary.failed == 1)
            await fixture.resumeUnattempted(using: cold)?.value
            let resumed = try await fixture.coldJournal()
            #expect(resumed.jobs.map(\.stage) == [.failed, .completed] && resumed.jobs.map(\.attempts) == [1, 1])
            #expect(resumed.foregroundAutomaticEnabled == false && fixture.server.counts == [2, 1])
            #expect(fixture.exporter.observations.map(\.localID) == ["first", "unattempted-tail"])
            #expect(fixture.exporter.observations.allSatisfy(\.allowCloud))
            let failed = try #require(resumed.jobs.first?.id)
            await fixture.retry(failed, using: cold)?.value
            let verified = try await fixture.coldJournal()
            #expect(verified.jobs.map(\.stage) == [.completed, .completed] && verified.jobs.map(\.attempts) == [2, 1])
            #expect(fixture.server.counts == [3, 2] && fixture.exporter.observations.map(\.localID) == ["first", "unattempted-tail", "first"])
            #expect(verified.foregroundAutomaticEnabled == false)
        }
    }

    /// 已保存排除失效或授权不足均在导出前停止，原恢复资料/自动开关不变，不能静默扩大尾队列范围。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor func savedExclusionOrPermissionFailureDoesNotReplayTheQueue(_ denied: Bool) async throws {
        try await withAutomaticBackupFixture(enabled: false) { fixture in
            try await fixture.seedUnattemptedQueue()
            await fixture.controller.load(using: fixture.manager)
            fixture.port.authorization = denied ? .denied : .authorized
            fixture.port.exclusionMissing = !denied
            await fixture.resumeUnattempted(using: fixture.controller)?.value
            let cold = try await fixture.coldJournal()
            #expect(cold.jobs.first?.stage == .paused && cold.jobs.first?.attempts == 0 && cold.excludedAlbumIDs == ["exclude"])
            #expect(cold.foregroundAutomaticEnabled == false && fixture.server.counts == [0, 0] && fixture.exporter.observations.isEmpty)
        }
    }

    /// 新恢复入口挂起在真实导出后取消，不能发HTTP；冷恢复保留已尝试暂停，下一次仅未尝试操作只执行尾项。
    @Test(.timeLimit(.minutes(1))) @MainActor func cancellationLeavesAttemptedWorkForExplicitVerification() async throws {
        try await withAutomaticBackupFixture(enabled: false) { fixture in
            fixture.port.sources.append(.init(localID: "tail-after-cancel", modifiedAt: nil, kind: .photo))
            try await fixture.seedUnattemptedQueue()
            await fixture.controller.load(using: fixture.manager)
            fixture.exporter.hold = true
            let old = fixture.resumeUnattempted(using: fixture.controller)
            try #require(await fixture.exporter.waitUntilHeld())
            fixture.controller.cancel()
            await fixture.exporter.waitUntilCancellation()
            fixture.exporter.release()
            await old?.value
            let paused = try await fixture.coldJournal()
            #expect(paused.jobs.map(\.stage) == [.paused, .paused] && paused.jobs.map(\.attempts) == [1, 0])
            #expect(fixture.server.counts == [0, 0])
            fixture.exporter.hold = false
            let cold = fixture.coldController()
            await cold.load(using: fixture.manager)
            await fixture.resumeUnattempted(using: cold)?.value
            #expect(try await fixture.coldJournal().jobs.map(\.stage) == [.paused, .completed])
            #expect(fixture.exporter.observations.map(\.localID) == ["first", "tail-after-cancel"] && fixture.server.counts == [1, 1])
        }
    }

    /// 已读取账号配置后存在草稿时，明确尾队列恢复也不得保存草稿或启动Worker。
    @Test(.timeLimit(.minutes(1))) @MainActor func draftRemainsUnsavedAndBlocksRecovery() async throws {
        try await withAutomaticBackupFixture(enabled: false) { fixture in
            try await fixture.seedUnattemptedQueue()
            await fixture.controller.load(using: fixture.manager)
            fixture.controller.excluded = ["draft-exclude"]
            fixture.controller.allowCloud = true
            #expect(fixture.resumeUnattempted(using: fixture.controller) == nil)
            let cold = try await fixture.coldJournal()
            #expect(cold.excludedAlbumIDs == ["exclude"] && !cold.allowCloud && cold.jobs.first?.attempts == 0)
            #expect(fixture.controller.excluded == ["draft-exclude"] && fixture.controller.requiresSelectionScan)
            #expect(fixture.server.counts == [0, 0] && fixture.exporter.observations.isEmpty)
        }
    }

    /// 仅继续未尝试项已进入真实导出await后撤销权限，旧资源不得上传；冷恢复后它成为待核查而不能再从新入口重放。
    @Test(.timeLimit(.minutes(1))) @MainActor func permissionRetirementKeepsTheStartedItemUnknown() async throws {
        try await withAutomaticBackupFixture(enabled: false) { fixture in
            try await fixture.seedUnattemptedQueue()
            await fixture.controller.load(using: fixture.manager)
            fixture.exporter.hold = true
            let old = fixture.resumeUnattempted(using: fixture.controller)
            try #require(await fixture.exporter.waitUntilHeld())
            fixture.port.authorization = .denied
            fixture.exporter.release()
            await old?.value
            let unknown = try await fixture.coldJournal()
            #expect(unknown.jobs.first?.stage == .exporting && unknown.jobs.first?.attempts == 1 && unknown.jobs.first?.primaryAssetID == nil)
            #expect(unknown.foregroundAutomaticEnabled == false && fixture.server.counts == [0, 0])
            fixture.port.authorization = .authorized
            let cold = fixture.coldController()
            await cold.load(using: fixture.manager)
            #expect(cold.jobs.first?.stage == .paused && cold.unattemptedSummary.attemptedOrUnconfirmed == 1)
            #expect(fixture.resumeUnattempted(using: cold) == nil && fixture.exporter.observations.count == 1)
        }
    }
}

/// operation使用完全隔离的账号/数据库/磁盘/HTTP；错误及测试取消也必须退役任务并释放真实导出门。
@MainActor private func withAutomaticBackupFixture(enabled: Bool, cloud: Bool = false, failingHTTP: Bool = false,
                                                   operation: @MainActor (AutomaticBackupFixture) async throws -> Void) async throws
{
    let fixture = try await AutomaticBackupFixture(enabled: enabled, cloud: cloud, failingHTTP: failingHTTP)
    do {
        try await withTaskCancellationHandler { try await operation(fixture) } onCancel: {
            Task { @MainActor in await fixture.close() }
        }
    } catch {
        await fixture.close(); throw error
    }
    await fixture.close()
}

/// 只替代Photos授权/相簿快照，不替换自动计划、持久队列或Worker；真实权限读取器永远不应由自动周期调用。
@MainActor private final class AutomaticBackupPhotoPort {
    var sources: [PhotoBackupSource] = [.init(localID: "first", modifiedAt: nil, kind: .photo)]
    var authorization = PHAuthorizationStatus.authorized
    var scans = 0
    var permissionPrompts = 0
    var exclusionMissing = false

    /// ids必须等于完整已保存包含/排除并集；缺失排除不能靠空快照静默放宽。
    func scan(_ ids: Set<String>) throws -> [PhotoBackupAlbumSnapshot] {
        guard ids == ["include", "exclude"] else { throw PhotoBackupAlbumSelectionError.invalidSelection }
        scans += 1
        let included = PhotoBackupAlbumSnapshot(id: "include", assets: sources.map { .init(source: $0, capturedAt: nil) })
        return exclusionMissing ? [included] : [included, .init(id: "exclude", assets: [])]
    }

    /// 自动测试若意外进入手动权限入口立即失败，而非假装授予访问。
    func requestAlbums() async throws -> PhotoBackupController.AlbumCatalog {
        permissionPrompts += 1
        throw PhotoBackupController.AlbumReadError.permission
    }
}

/// 每例使用实际管理通道和SQLite冷读取；系统观察在测试中关闭，由相同公开事件入口精确触发。
@MainActor private final class AutomaticBackupFixture {
    let root: URL
    let database: URL
    let endpoint: URL
    let scope: MediaAccountScope
    let store: SQLiteLibraryIndexStore
    let manager: LibraryManagementController
    let controller: PhotoBackupController
    let port: AutomaticBackupPhotoPort
    let exporter: AutomaticBackupExporter
    let server: AutomaticBackupHTTPServer
    private var tasks: [Task<Void, Never>] = []
    private var observers: [Task<Void, Never>] = []
    private var closeTask: Task<Void, Never>?

    /// enabled/cloud模拟用户此前明确扫描保存的配置；failingHTTP仅改变实际查重状态码。
    init(enabled: Bool, cloud: Bool, failingHTTP: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ForegroundAutomatic-\(UUID())", directoryHint: .isDirectory)
        let endpoint = URL(string: "https://foreground-\(UUID().uuidString.lowercased()).invalid/api")!
        let session = AccountSession(apiURL: endpoint, accessToken: "foreground-fixture", userID: "99999999-9999-4999-8999-999999999999",
                                     userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
                                     serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
        let scope = MediaAccountScope(session: session)
        let database = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: database)
        let selection = try PhotoBackupAlbumSelection(included: ["include"], excluded: ["exclude"])
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.applyAlbumScan(selection.scan([.init(id: "include", assets: []), .init(id: "exclude", assets: [])]), allowCloud: cloud)
        try journal.setForegroundAutomaticEnabled(enabled)
        do {
            try await store.prepare(scope: scope); try await store.savePhotoBackups(journal, scope: scope)
        } catch {
            try? FileManager.default.removeItem(at: root); throw error
        }
        let manager = LibraryManagementController(configurationFactory: Self.configuration)
        let exporter = AutomaticBackupExporter(root: root.appending(path: "exports"), store: store, scope: scope)
        let server = AutomaticBackupHTTPServer(endpoint: endpoint, failing: failingHTTP)
        AutomaticBackupURLProtocol.install(server, endpoint: endpoint)
        manager.configure(session: session, endpoint: endpoint)
        self.root = root; self.database = database; self.endpoint = endpoint; self.scope = scope; self.store = store
        self.manager = manager; self.exporter = exporter; self.server = server
        let port = AutomaticBackupPhotoPort()
        self.port = port
        controller = PhotoBackupController(store: store, exporter: exporter, albumLoader: { try await port.requestAlbums() },
                                           albumScanner: { try port.scan($0) }, authorizationStatus: { port.authorization }, observeAutomaticPhotos: false)
    }

    /// 真实客户端只能进入本例私有URLProtocol，没有进程全局注册或真实网络后备。
    private nonisolated static func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [AutomaticBackupURLProtocol.self]; return value
    }

    /// 激活实际生命周期入口；记录任务并在早期失败时唤醒导出门观察者，避免靠sleep猜执行顺序。
    @discardableResult func activate() -> Task<Void, Never>? {
        track(controller.automaticConditionsChanged(using: manager, scope: scope, active: true))
    }

    /// 触发实际Photos事件入口；重复通知仍由生产Controller合并。
    @discardableResult func request() -> Task<Void, Never>? {
        track(controller.automaticLibraryChanged())
    }

    /// 使用真实停止入口，并把其等待/持久保存任务纳入失败及超时清理。
    func stopManually() -> Task<Void, Never> {
        let task = Task { await controller.stopManually(using: manager) }
        tasks.append(task)
        return task
    }

    /// 真实手动继续任务也纳入门和清理观察；用它建立非合作导出await，不模拟Controller的task字段。
    func resumeManually() -> Task<Void, Never>? {
        track(controller.resume(using: manager))
    }

    /// 仅构造明确保存且尚未尝试的暂停尾队列；用真实领域转换/SQLite，不编造上传回执或成功行。
    func seedUnattemptedQueue() async throws {
        var journal = try await coldJournal()
        try journal.enqueue(port.sources)
        for id in journal.jobs.map(\.id) {
            try journal.update(id) { $0.pause() }
        }
        try await store.savePhotoBackups(journal, scope: scope)
    }

    /// 新Controller和SQLite连接模拟冷恢复；Photos与HTTP仍是同一例系统边界，恢复事实只能来自磁盘。
    func coldController() -> PhotoBackupController {
        PhotoBackupController(store: SQLiteLibraryIndexStore(databaseURL: database), exporter: exporter,
                              albumLoader: { [port] in try await port.requestAlbums() }, albumScanner: { [port] in try port.scan($0) },
                              authorizationStatus: { [port] in port.authorization }, observeAutomaticPhotos: false)
    }

    /// 记录实际新恢复任务，保证取消/超时也等待其Worker退役。
    func resumeUnattempted(using value: PhotoBackupController) -> Task<Void, Never>? {
        track(value.resumeUnattempted(using: manager))
    }

    /// 原单项明确核查路径也使用真实Controller并进入相同清理集合。
    func retry(_ id: UUID, using value: PhotoBackupController) -> Task<Void, Never>? {
        track(value.resume(using: manager, jobID: id))
    }

    /// task是实际Controller任务，不以测试自造运行状态替代；观察任务只负责解除提前失败时的测试等待。
    private func track(_ task: Task<Void, Never>?) -> Task<Void, Never>? {
        guard let task else { return nil }
        tasks.append(task)
        observers.append(Task { [exporter] in await task.value; exporter.workFinished() })
        return task
    }

    /// 新SQLite actor读取真实磁盘头与任务；不采用Controller已发布列表作为持久证据。
    func coldJournal() async throws -> PhotoBackupJournal {
        try await SQLiteLibraryIndexStore(databaseURL: database).loadPhotoBackups(scope: scope)
    }

    /// 只清理当前合成例；释放所有门、等待真实业务/观察任务结束，再删除账号目录。
    func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        let cleanup = Task { await closeOnce() }
        closeTask = cleanup
        await cleanup.value
    }

    /// 所有同时进入的close调用等待同一退役任务；不能因另一个调用已开始就提前返回并删除仍使用中的文件。
    private func closeOnce() async {
        let retirement = controller.automaticConditionsChanged(using: manager, scope: scope, active: false)
        controller.cancel(); tasks.forEach { $0.cancel() }; exporter.abort()
        await retirement?.value
        for task in tasks {
            await task.value
        }
        for task in observers {
            await task.value
        }
        manager.configure(session: nil, endpoint: nil)
        AutomaticBackupURLProtocol.remove(endpoint: endpoint)
        try? FileManager.default.removeItem(at: root)
    }
}

/// 仅替代PhotoKit字节；真正读取SQLite确认begin已落盘，取消门由真实Task取消握手建立。
@MainActor private final class AutomaticBackupExporter: PhotoBackupResourceExporting {
    /// 由实际持久任务读取的导出身份、阶段与iCloud选项，不自行创建成功回执。
    struct Observation { let localID: String; let stage: PhotoBackupJob.Stage; let allowCloud: Bool }
    let root: URL
    let store: SQLiteLibraryIndexStore
    let scope: MediaAccountScope
    var hold = false
    private(set) var observations: [Observation] = []
    private(set) var directories: [URL] = []
    private var held = false
    private var finished = false
    private var cancelled = false
    private var gate: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Bool, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    /// root只存合成文件；store/scope只读实际检查点，替身不回写任何成功状态。
    init(root: URL, store: SQLiteLibraryIndexStore, scope: MediaAccountScope) {
        self.root = root; self.store = store; self.scope = scope
    }

    /// source/allowCloud完全来自实际Worker；门释放后仍检查真实取消，禁止旧结果继续发HTTP。
    func export(_ source: PhotoBackupSource, allowCloud: Bool) async throws -> PhotoBackupResources {
        let journal = try await store.loadPhotoBackups(scope: scope)
        try Task.checkCancellation()
        let job = try #require(journal.jobs.first { $0.source == source })
        observations.append(.init(localID: source.localID, stage: job.stage, allowCloud: allowCloud))
        if hold {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    gate = continuation; held = true
                    let values = holdWaiters; holdWaiters = []; values.forEach { $0.resume(returning: true) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.didCancel() }
            }
        }
        try Task.checkCancellation()
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let file = directory.appending(path: "synthetic.jpg")
        try Data("foreground automatic synthetic photo\n".utf8).write(to: file)
        return .init(directory: directory, primary: .init(file: file, name: "synthetic.jpg"), motion: nil,
                     created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0), favorite: false)
    }

    /// 等实际导出await已进入；早期业务失败返回false，不接受时间流逝作为已挂起证据。
    func waitUntilHeld() async -> Bool {
        if held {
            return true
        }
        if finished {
            return false
        }
        return await withCheckedContinuation { holdWaiters.append($0) }
    }

    /// 等实际取消处理器通知，不用yield/sleep假造停止已发生。
    func waitUntilCancellation() async {
        if cancelled || finished {
            return
        }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    /// 真实Task取消回调只通知门观察者；门由测试明确释放，便于验证Controller确实等待退役。
    private func didCancel() {
        cancelled = true
        let values = cancelWaiters; cancelWaiters = []; values.forEach { $0.resume() }
    }

    /// 只释放导出边界，不修改生产队列或伪造上传回执。
    func release() {
        gate?.resume(); gate = nil
    }

    /// 实际Controller任务提前结束也唤醒观察者，避免失败路径遗留continuation。
    func workFinished() {
        finished = true
        let values = holdWaiters; holdWaiters = []; values.forEach { $0.resume(returning: false) }
        let cancellations = cancelWaiters; cancelWaiters = []; cancellations.forEach { $0.resume() }
    }

    /// 失败/超时清理所有门；调用方随后等待真实任务退出。
    func abort() {
        release(); workFinished()
    }
}

/// 私有合成HTTP响应，Mutex仅保护请求计数；不会替换生产鉴权/序列化/状态码解析与fresh核对。
private final nonisolated class AutomaticBackupHTTPServer: Sendable {
    let endpoint: URL
    private let failing: Mutex<Bool>
    private let requests = Mutex<[Int]>([0, 0])
    var counts: [Int] {
        requests.withLock { $0 }
    }

    /// endpoint固定随机.invalid主机，failing只用于失败状态码回归。
    init(endpoint: URL, failing: Bool) {
        self.endpoint = endpoint; self.failing = Mutex(failing)
    }

    /// 明确切换隔离HTTP服务的故障状态，用真实请求建立断网后恢复序列，不替换上传返回值。
    func setFailing(_ value: Bool) {
        failing.withLock { $0 = value }
    }

    /// request为URLSession真实请求；仅接受官方查重与fresh GET，未知方法/路径/认证/校验和均失败。
    func reply(_ request: URLRequest) throws -> (Int, Data) {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer foreground-fixture", let url = request.url else { throw URLError(.userAuthenticationRequired) }
        if request.httpMethod == "POST", url == endpoint.appending(path: "assets/bulk-upload-check") {
            let body = try Self.body(request)
            // 官方查重请求的有限JSON结构；nonce与校验和必须来自实际客户端正文。
            struct Check: Decodable { struct Item: Decodable { let id: String; let checksum: String }; let assets: [Item] }
            let value = try JSONDecoder().decode(Check.self, from: body)
            let item = try #require(value.assets.first)
            // 参考SHA1独立由Node crypto计算，不调用生产checksum生成预期答案。
            guard value.assets.count == 1, UUID(uuidString: item.id) != nil, item.checksum == "f0dfc36a29e0f039816e54ddb59e0c7fc202c11c" else { throw URLError(.cannotDecodeContentData) }
            requests.withLock { $0[0] += 1 }
            if failing.withLock({ $0 }) {
                return (503, Data(#"{"message":"synthetic unavailable"}"#.utf8))
            }
            let result = "{\"results\":[{\"id\":\"\(item.id)\",\"action\":\"reject\",\"assetId\":\"22222222-2222-4222-8222-222222222222\",\"isTrashed\":false}]}"
            return (200, Data(result.utf8))
        }
        if request.httpMethod == "GET", url == endpoint.appending(path: "assets/22222222-2222-4222-8222-222222222222") {
            requests.withLock { $0[1] += 1 }
            return (200, Data(#"{"id":"22222222-2222-4222-8222-222222222222","ownerId":"99999999-9999-4999-8999-999999999999","isFavorite":false,"visibility":"timeline","isTrashed":false,"type":"IMAGE","originalFileName":"synthetic.jpg","livePhotoVideoId":null,"exifInfo":null}"#.utf8))
        }
        throw URLError(.unsupportedURL)
    }

    /// JSON正文从实际body或stream读取，最多64KiB；不能在测试中重建本应由客户端发送的nonce/校验和。
    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeRawData) }
        stream.open(); defer { stream.close() }
        var result = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
            if count == 0 {
                return result
            }
            result.append(contentsOf: bytes.prefix(count))
            guard result.count <= 65536 else { throw URLError(.dataLengthExceedsMaximum) }
        }
    }
}

/// 仅安装于私有测试会话，所有未知主机也失败；同步有限响应无异步任务或待清理HTTP响应门。
private final nonisolated class AutomaticBackupURLProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Mutex<[String: AutomaticBackupHTTPServer]>([:])
    private let stopped = Mutex(false)

    /// 每例随机host只映射自己的服务器，不覆盖其他测试或使用进程全局注册。
    static func install(_ server: AutomaticBackupHTTPServer, endpoint: URL) {
        servers.withLock { $0[endpoint.host!] = server }
    }

    /// 真实任务退役后移除本例映射。
    static func remove(endpoint: URL) {
        _ = servers.withLock { $0.removeValue(forKey: endpoint.host!) }
    }

    /// 私有会话的任何路由都必须拦截，无真实网络后备。
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    /// 保留生产客户端实际请求，不修补路径或字段。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// 完整真实HTTP响应仍由URLSession和LibraryMutationClient解析；取消后不主动发布。
    override func startLoading() {
        do {
            guard let url = request.url, let server = Self.servers.withLock({ $0[url.host ?? ""] }) else { throw URLError(.badURL) }
            let (status, data) = try server.reply(request)
            guard !stopped.withLock({ $0 }), let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                                            headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            if !stopped.withLock({ $0 }) {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    /// URLSession取消只阻止响应交付，不修改持久队列事实。
    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}
