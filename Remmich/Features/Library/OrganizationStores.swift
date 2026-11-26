import Foundation
import Observation

/// 只持有当前账号的一批随机照片；刷新成功才替换，失败保留旧批次与明确错误，不伪造无限分页。
@MainActor @Observable
final class RandomPhotosStore {
    private(set) var assets: [TimelineAssetSummary] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var wasCancelled = false
    private var generation = UUID()
    private var operation: Task<Void, Never>?

    /// 账号/端点变化清空结果并撤销所有旧响应的发布权，不取消或改写共享索引。
    func invalidate() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        assets = []
        isLoading = false
        hasLoaded = false
        error = nil
        wasCancelled = false
    }

    /// 用户停止等待时退休当前抽样；保留已确认批次，不把取消伪装成空结果或服务端失败。
    func cancel() {
        guard isLoading else { return }
        generation = UUID()
        operation?.cancel()
        operation = nil
        isLoading = false
        wasCancelled = true
        error = nil
    }

    /// source是当前账号读取器；每次明确抽样取消旧Task并取代发布权，去重保留服务端顺序。
    /// 调用方取消也向实际读取传播；不合作的迟到成功/失败仍由本轮代际拒绝。
    func refresh(source: any OrganizationReading) async {
        operation?.cancel()
        generation = UUID()
        let owner = generation
        isLoading = true
        error = nil
        wasCancelled = false
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if owner == generation {
                    isLoading = false
                    operation = nil
                }
            }
            do {
                let values = try await source.randomPhotos()
                try Task.checkCancellation()
                guard owner == generation else { return }
                var seen = Set<String>()
                assets = values.filter { seen.insert($0.id.lowercased()).inserted }
                hasLoaded = true
            } catch {
                guard owner == generation, !Task.isCancelled, !(error is CancellationError),
                      (error as? TimelineReadError) != .staleGeneration else { return }
                self.error = (error as? NativeSearchError)?.errorDescription
                    ?? "Random photos could not be loaded. Check permissions and connection."
            }
        }
        operation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// 本人待整理相簿的发布状态；不支持、空列表与失败分开，不沿用其他账号候选。
@MainActor @Observable
final class PendingAlbumsStore {
    private(set) var albums: [AlbumSummary] = []
    private(set) var supported: Bool?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private var generation = UUID()

    /// 撤销旧账号/端点读取的发布权，清除能力和列表，避免迟到结果重新出现。
    func invalidate() {
        generation = UUID()
        albums = []
        supported = nil
        isLoading = false
        hasLoaded = false
        error = nil
    }

    /// source提供真实相簿读取，ownerID是已登录用户；只有成功响应才能确认空列表或缺扩展。
    func load(source: any OrganizationReading, ownerID: String) async {
        guard !isLoading else { return }
        let owner = generation
        isLoading = true
        error = nil
        defer {
            if owner == generation {
                isLoading = false
            }
        }
        do {
            let values = try await source.pendingAlbums(ownerID: ownerID)
            try Task.checkCancellation()
            guard owner == generation else { return }
            supported = values != nil
            albums = values ?? []
            hasLoaded = true
        } catch {
            guard owner == generation, !Task.isCancelled, !(error is CancellationError),
                  (error as? TimelineReadError) != .staleGeneration else { return }
            self.error = (error as? NativeSearchError)?.errorDescription
                ?? "Pending albums could not be loaded. Check permissions and connection."
        }
    }
}
