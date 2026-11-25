import Foundation
import Observation

/// 标签树/关系管理的单命令状态机；fresh预检、精确写确认与fresh回读分开，不自动重试部分/未知结果。
@MainActor @Observable
final class AssetTagStore {
    private(set) var state: AssetTagState?
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var hasFreshData = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var confirmedChanges = 0
    private(set) var savedAccountGeneration: UUID?
    private var generation = UUID()
    private var readAccountGeneration: UUID?
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var writeWasSent = false
    private var writeWasConfirmed = false

    /// manager绑定当前账号；页面失效清空所有树/草稿发布权，同账号未知写入只使既有读者失效。
    func invalidate(manager: LibraryManagementController) {
        if writeWasSent, let account = readAccountGeneration {
            manager.publishChanges(ifGeneration: account)
        }
        generation = UUID(); readTask?.cancel(); writeTask?.cancel()
        readTask = nil; writeTask = nil; state = nil; readAccountGeneration = nil
        isLoading = false; isWorking = false; hasFreshData = false; error = nil; notice = nil
        writeWasSent = false; writeWasConfirmed = false; confirmedChanges = 0; savedAccountGeneration = nil
    }

    /// assetID指定真实照片；返回可等待任务，树/资源任何一边失败都不能把旧数据标记fresh。
    @discardableResult
    func reload(assetID: String, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard !isWorking else { return nil }
        guard let client = manager.client else { error = LibraryWriteError.unavailable.errorDescription; hasFreshData = false; return nil }
        readTask?.cancel(); generation = UUID()
        let owner = generation; let account = manager.generation
        state = nil; hasFreshData = false; readAccountGeneration = nil; isLoading = true; error = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if isCurrent(owner, account: account, manager: manager) {
                    isLoading = false; readTask = nil
                }
            }
            do {
                let fresh = try await Self.read(client, assetID: assetID)
                try Task.checkCancellation()
                guard isCurrent(owner, account: account, manager: manager) else { return }
                state = fresh; readAccountGeneration = account; hasFreshData = true
            } catch {
                guard isCurrent(owner, account: account, manager: manager), !Task.isCancelled else { return }
                self.error = Self.message(error)
            }
        }
        readTask = task; return task
    }

    /// command是用户明确选择的单命令；返回固定确认，无HTTP；全树删除/改名影响必须在View中展示。
    func prepare(_ command: AssetTagCommand, manager: LibraryManagementController) throws -> AssetTagPlan {
        guard hasFreshData, !isLoading, !isWorking, !manager.busy, readAccountGeneration == manager.generation,
              let state, let client = manager.client else { throw AssetTagError.reloadRequired }
        try Self.requireWritable(state, userID: client.userID); try command.validate(in: state)
        return .init(baseline: state, command: command, readGeneration: generation, accountGeneration: manager.generation)
    }

    /// plan为审阅时命令/快照；先fresh树+照片预检，一次写入，再fresh树+照片验证所选变化。
    @discardableResult
    func start(_ plan: AssetTagPlan, manager: LibraryManagementController) -> Task<Void, Never>? {
        guard plan.readGeneration == generation, plan.accountGeneration == manager.generation,
              hasFreshData, !isLoading, !isWorking, !manager.busy else { error = AssetTagError.reloadRequired.errorDescription; return nil }
        generation = UUID(); let owner = generation
        hasFreshData = false; isWorking = true; error = nil; notice = nil; writeWasSent = false; writeWasConfirmed = false
        let task = Task { [weak self] in
            guard let self else { return }
            var unknown = false
            defer {
                if isCurrent(owner, account: plan.accountGeneration, manager: manager) {
                    if writeWasConfirmed || unknown {
                        manager.publishChanges(ifGeneration: plan.accountGeneration)
                    }
                    if writeWasConfirmed {
                        confirmedChanges += 1; savedAccountGeneration = plan.accountGeneration
                    }
                    isWorking = false; writeTask = nil; writeWasSent = false; writeWasConfirmed = false
                }
            }
            do {
                let fresh = try await manager.perform(publishChange: false) { client in
                    let before = try await Self.read(client, assetID: plan.baseline.asset.id)
                    try await self.preflight(before, plan: plan, owner: owner, manager: manager, userID: client.userID)
                    try await self.markSent(owner: owner, account: plan.accountGeneration, manager: manager)
                    let result = try await Self.write(plan, client: client)
                    try await self.markConfirmed(owner: owner, account: plan.accountGeneration, manager: manager)
                    let after = try await Self.read(client, assetID: plan.baseline.asset.id)
                    try Task.checkCancellation()
                    try Self.requireWritable(after, userID: client.userID)
                    guard after.asset.type == before.asset.type, after.asset.livePhotoVideoId == before.asset.livePhotoVideoId,
                          Self.isConfirmed(plan, result: result, after: after) else { throw AssetTagError.changedRemotely }
                    return after
                }
                guard isCurrent(owner, account: plan.accountGeneration, manager: manager), !Task.isCancelled else { return }
                state = fresh; hasFreshData = true; readAccountGeneration = plan.accountGeneration
            } catch {
                guard isCurrent(owner, account: plan.accountGeneration, manager: manager) else { return }
                if writeWasConfirmed {
                    self.error = "Tag changes were saved, but current tags could not be confirmed. Reload before another change."
                } else {
                    self.error = Self.message(error); unknown = writeWasSent && Self.mayHaveChanged(error)
                }
            }
        }
        writeTask = task; return task
    }

    /// 只停止当前等待；已发送写入不被描述为回滚，恢复前台也不自动重发。
    func cancel() {
        writeTask?.cancel()
    }

    /// message仅允许本地输入错误，不接收服务端正文或原片信息。
    func showError(_ message: String) {
        error = message
    }

    /// before为刚完成的真实读取；验证页面/账号、所有权和审阅时树/关系仍未变化。
    private func preflight(_ before: AssetTagState, plan: AssetTagPlan, owner: UUID,
                           manager: LibraryManagementController, userID: String) throws
    {
        try Task.checkCancellation()
        guard isCurrent(owner, account: plan.accountGeneration, manager: manager) else { throw LibraryWriteError.changedAccount }
        try Self.requireWritable(before, userID: userID)
        guard before == plan.baseline else { throw AssetTagError.changedRemotely }
        try plan.command.validate(in: before)
    }

    /// owner/account在预检后、真正发送前再次核对；过时代际不能进入写阶段。
    private func markSent(owner: UUID, account: UUID, manager: LibraryManagementController) throws {
        try Task.checkCancellation()
        guard isCurrent(owner, account: account, manager: manager) else { throw LibraryWriteError.changedAccount }
        writeWasSent = true
    }

    /// 当前账号精确HTTP回执已通过；保存事实与之后的回读结果分别记录。
    private func markConfirmed(owner: UUID, account: UUID, manager: LibraryManagementController) throws {
        guard isCurrent(owner, account: account, manager: manager) else { throw LibraryWriteError.changedAccount }
        writeWasConfirmed = true; notice = "Tag changes saved. Library syncing is requested."
    }

    /// owner/account为任务启动时快照；返回是否仍能发布到当前页面。
    private func isCurrent(_ owner: UUID, account: UUID, manager: LibraryManagementController) -> Bool {
        owner == generation && account == manager.generation
    }

    /// client保持同一认证会话；顺序真实读取完整树和当前照片，不从本地选择反推标签关系。
    private nonisolated static func read(_ client: LibraryMutationClient, assetID: String) async throws -> AssetTagState {
        let tags = try await client.managedTags()
        try Task.checkCancellation()
        let asset = try await client.taggedAsset(assetID)
        try Task.checkCancellation()
        guard asset.tags.allSatisfy({ relation in tags.contains { $0.id == relation.id && $0.value == relation.value && $0.parentId == relation.parentId } }) else {
            throw AssetTagError.changedRemotely
        }
        return .init(asset: asset, tags: tags)
    }

    /// state为实际读取，userID为认证身份；本页只处理自有且未回收资源，不扩大官方权限。
    private nonisolated static func requireWritable(_ state: AssetTagState, userID: String) throws {
        guard state.asset.ownerId.lowercased() == userID.lowercased() else { throw AssetTagError.notOwned }
        guard !state.asset.isTrashed else { throw AssetTagError.trashed }
    }

    /// plan只表达一个命令；返回创建/改名/改色标签供后续验证，其他写入无虚构标签对象。
    private nonisolated static func write(_ plan: AssetTagPlan, client: LibraryMutationClient) async throws -> ManagedTag? {
        let tags = plan.baseline.tags
        switch plan.command {
        case let .create(name, parentID): return try await client.createManagedTag(name: name, parent: tags.first { $0.id == parentID })
        case let .rename(id, name):
            guard let tag = tags.first(where: { $0.id == id }) else { throw AssetTagError.reloadRequired }
            return try await client.renameManagedTag(tag, name: name)
        case let .color(id, change):
            guard let tag = tags.first(where: { $0.id == id }) else { throw AssetTagError.reloadRequired }
            return try await client.recolorManagedTag(tag, change: change)
        case let .delete(id): try await client.deleteManagedTag(id)
        case let .attach(id): try await client.setAssetTag(plan.baseline.asset.id, tagID: id, attached: true)
        case let .detach(id): try await client.setAssetTag(plan.baseline.asset.id, tagID: id, attached: false)
        }
        return nil
    }

    /// result为已确认写回执，after为真实回读；核颜色专用不变项及改名/删除的后代影响，不宣称sidecar全部完成。
    private nonisolated static func isConfirmed(_ plan: AssetTagPlan, result: ManagedTag?, after: AssetTagState) -> Bool {
        switch plan.command {
        case .create:
            guard let result else { return false }
            return after.tags.contains { $0.id == result.id && $0.name == result.name && $0.value == result.value && $0.parentId == result.parentId }
        case let .rename(id, _):
            guard let result, let old = plan.baseline.tags.first(where: { $0.id == id }) else { return false }
            let affected = plan.baseline.subtree(id)
            return plan.baseline.tags.filter { affected.contains($0.id) }.allSatisfy { previous in
                let expected = result.value + String(previous.value.dropFirst(old.value.count))
                return after.tags.contains { $0.id == previous.id && $0.parentId == previous.parentId && $0.value == expected }
            }
        case let .color(id, change):
            guard let result, change.matches(result), let target = after.tags.first(where: { $0.id == id }),
                  target.preservesDefinition(of: result), change.matches(target),
                  after.tags.count == plan.baseline.tags.count,
                  after.asset.tags.map(\.id) == plan.baseline.asset.tags.map(\.id) else { return false }
            // 只改色不能顺便改树或照片关系；目标可更新颜色/updatedAt，其余完整对象保持原样。
            let catalogMatches = plan.baseline.tags.allSatisfy { old in
                after.tags.contains { new in new.id == old.id && (old.id == id ? new.preservesDefinition(of: old) && change.matches(new) : new == old) }
            }
            return catalogMatches && plan.baseline.asset.tags.allSatisfy { old in
                after.asset.tags.contains { new in new.id == old.id && (old.id == id ? new.preservesDefinition(of: old) && change.matches(new) : new == old) }
            }
        case let .delete(id): return plan.baseline.subtree(id).isDisjoint(with: Set(after.tags.map(\.id)))
        case let .attach(id): return after.asset.tags.contains { $0.id == id }
        case let .detach(id): return !after.asset.tags.contains { $0.id == id }
        }
    }

    /// 明确4xx/duplicate/no_permission/not_found/validation没有成功确认；网络和unknown保守失效读者，不重发。
    private nonisolated static func mayHaveChanged(_ error: any Error) -> Bool {
        if case LibraryWriteError.http(400 ..< 500) = error {
            return false
        }
        if case let AssetTagError.membership(reason) = error {
            return reason == .unknown
        }
        return true
    }

    /// error只映射稳定本地原因/HTTP码；不显示服务端异常正文、私人标签或凭据。
    private nonisolated static func message(_ error: any Error) -> String {
        if let local = error as? AssetTagError {
            return local.errorDescription ?? "Reload tags before another change."
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return "Stopped waiting. Reload tags before another change; a sent request may have completed."
        }
        if case let LibraryWriteError.http(status) = error {
            return "The server returned HTTP \(status). Check permission and connection, then reload. No write was retried."
        }
        return "Tags could not be confirmed. Reload before another change; no write was retried."
    }
}
