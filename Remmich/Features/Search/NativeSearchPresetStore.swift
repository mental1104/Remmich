import Foundation
import Observation

/// 管理当前账户的登记列表与写入确认；不改变照片索引，也不自动重放写请求。
@MainActor @Observable
final class NativeSearchPresetStore {
    private(set) var presets: [NativeSearchPreset] = []
    private(set) var supported: Bool?
    private(set) var busy = false
    private(set) var hasFreshData = false
    private(set) var error: String?
    private var generation = UUID()

    /// 账户或端点变化时清除全部列表、能力和错误，旧请求失去发布权。
    func invalidate() {
        generation = UUID()
        presets = []
        supported = nil
        busy = false
        hasFreshData = false
        error = nil
    }

    /// manager提供当前账户通道；只有明确缺失路由标记unsupported，其他失败保持未知/原能力状态。
    func load(manager: LibraryManagementController) async {
        guard !busy else { return }
        hasFreshData = false
        _ = await run(manager: manager, operation: { try await $0.searchPresets() }) { values in
            self.supported = values != nil
            self.presets = values ?? []
            self.hasFreshData = values != nil
        }
    }

    /// name为草稿名、query为当前查询；返回是否由有效响应确认保存，失败时调用方保留草稿。
    func create(name: String, query: NativeSearchQuery, manager: LibraryManagementController) async -> Bool {
        guard ready() else { return false }
        do {
            let conditions = try NativeSearchPresetCodec.capture(query)
            return await run(manager: manager, operation: { try await $0.createSearchPreset(name: name, conditions: conditions) }) { self.install($0) }
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// preset为目标、name为新名；先重读最新完整条件，不用界面子集覆盖原条件；API本身没有CAS。
    func rename(_ preset: NativeSearchPreset, name: String, manager: LibraryManagementController) async -> Bool {
        guard ready() else { return false }
        return await run(manager: manager, operation: { client in
            let values = try await client.searchPresets()
            guard let current = values?.first(where: { $0.id == preset.id }) else { throw LibraryWriteError.http(404) }
            return try await client.updateSearchPreset(preset.id, name: name, conditions: current.conditions)
        }) { self.install($0) }
    }

    /// 用户明确确认后，用当前query完整替换preset条件，不伪装成保留原条件的改名。
    func replace(_ preset: NativeSearchPreset, query: NativeSearchQuery, manager: LibraryManagementController) async -> Bool {
        guard ready() else { return false }
        do {
            let conditions = try NativeSearchPresetCodec.capture(query)
            return await run(manager: manager, operation: { client in
                let values = try await client.searchPresets()
                guard let current = values?.first(where: { $0.id == preset.id }) else { throw LibraryWriteError.http(404) }
                return try await client.updateSearchPreset(preset.id, name: current.name, conditions: conditions)
            }) { self.install($0) }
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// 只删除指定登记；收到精确204且账户仍匹配时才移除本地行。
    func remove(_ preset: NativeSearchPreset, manager: LibraryManagementController) async -> Bool {
        guard ready() else { return false }
        return await run(manager: manager, operation: { try await $0.deleteSearchPreset(preset.id) }) { self.presets.removeAll { $0.id == preset.id } }
    }

    /// 拒绝基于未加载或失败后的数据写入，避免失败后盲目重发POST。
    private func ready() -> Bool {
        guard hasFreshData, supported == true else {
            error = "Reload saved searches before editing."
            return false
        }
        return true
    }

    /// operation为单个明确动作，apply仅在当前代际成功后运行；manager不触发照片索引刷新。
    private func run<Value: Sendable>(manager: LibraryManagementController,
                                      operation: @Sendable (LibraryMutationClient) async throws -> Value,
                                      apply: (Value) -> Void) async -> Bool
    {
        guard !busy else { return false }
        let owner = generation
        let account = manager.generation
        busy = true
        error = nil
        defer {
            if owner == generation {
                busy = false
            }
        }
        do {
            let result = try await manager.perform(publishChange: false, operation)
            guard owner == generation, account == manager.generation else { return false }
            apply(result)
            return true
        } catch {
            guard owner == generation, account == manager.generation else { return false }
            // 取消也可能发生在服务端接受写入之后；重新读取前不能把它当成可直接重发。
            hasFreshData = false
            guard !Task.isCancelled, !(error is CancellationError) else { return false }
            if case LibraryWriteError.http(409) = error {
                self.error = "A saved search with that name already exists. Your draft was kept."
            } else if case LibraryWriteError.http(403) = error {
                self.error = "This account does not have permission to edit saved searches."
            } else if case LibraryWriteError.http(401) = error {
                self.error = "Sign in again to access saved searches."
            } else if case LibraryWriteError.http(404) = error {
                self.error = "The saved search is unavailable. Reload the list."
            } else {
                self.error = "Saved search could not be confirmed. Reload before retrying a write."
            }
            return false
        }
    }

    /// 用服务端确认对象更新同ID行，保留其他项并按名称展示。
    private func install(_ preset: NativeSearchPreset) {
        presets.removeAll { $0.id == preset.id }
        presets.append(preset)
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
