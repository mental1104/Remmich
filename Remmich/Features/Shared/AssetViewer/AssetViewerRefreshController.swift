import Foundation
import Observation

/// 查看器显式读取/编辑后有限观察的状态机；不推断ready，不无界轮询，取消或旧上下文不能发布。
@MainActor
@Observable
final class AssetViewerRefreshController {
    private(set) var busy = false
    private(set) var message: String?
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    private let pause: @Sendable () async throws -> Void

    /// pause为相邻编辑后读取之间的间隔；生产一秒，测试可用actor闸门，无真实等待或网络重试。
    init(pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.pause = pause
    }

    /// 结束旧读取并清除上下文提示；底层URLSession读取遵守任务取消，不触发任何写入。
    func cancel() {
        requestID = UUID()
        task?.cancel(); task = nil
        busy = false
        message = nil
    }

    /// asset是启动时选中快照，afterEdit最多读四次，否则一次；read为真实短超时GET，isCurrent检查选择/账户/路由/可见性。
    /// publish接收验证后的新summary，返回false表示session已不接受；返回Task供宿主生命周期与测试等待，不保证派生完成。
    @discardableResult
    func refresh(asset: TimelineAssetSummary, afterEdit: Bool,
                 read: @escaping @Sendable () async throws -> AssetViewerFreshAsset,
                 isCurrent: @escaping @MainActor () -> Bool,
                 publish: @escaping @MainActor (TimelineAssetSummary) -> Bool) -> Task<Void, Never>
    {
        cancel()
        let owner = requestID
        busy = true
        message = afterEdit ? "编辑参数已保存，正在读取预览更新…" : "正在刷新照片…"
        let value = Task { [weak self] in
            guard let self else { return }
            defer {
                if owner == self.requestID {
                    self.busy = false; self.task = nil
                }
            }
            do {
                for index in 0 ..< (afterEdit ? 4 : 1) {
                    guard owner == requestID, isCurrent(), !Task.isCancelled else { return }
                    if index > 0 {
                        try await pause()
                    }
                    try Task.checkCancellation()
                    guard owner == requestID, isCurrent() else { return }
                    let fresh = try await read()
                    try Task.checkCancellation()
                    guard owner == requestID, isCurrent() else { return }
                    guard try publish(fresh.replacing(asset)) else { throw AssetViewerFreshReadError.invalid }
                }
                guard owner == requestID, isCurrent() else { return }
                message = afterEdit
                    ? "编辑参数已保存。预览可能仍在生成，可再次刷新。"
                    : "已读取当前照片；编辑预览可能仍在生成。"
            } catch {
                guard owner == requestID, isCurrent(), !Task.isCancelled else { return }
                // 读取失败不伪造缓存成功，不自动重试；保存参数本身可能已经成功，用户只需明确刷新。
                message = "刷新未完成，请再次刷新。\(error.localizedDescription)"
            }
        }
        task = value
        return value
    }
}
