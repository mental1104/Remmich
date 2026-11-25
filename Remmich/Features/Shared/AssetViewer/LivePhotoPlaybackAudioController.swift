import Foundation
import Observation

/// 只拥有一次Live Photo音频激活的异步发布权；宿主仍负责长按/payload/账号上下文和何时停止音频。
/// 旧会话完成只能返回false，不能改变新轮ready、调用新轮failure或停用新轮音频。
@MainActor @Observable final class LivePhotoPlaybackAudioController {
    private(set) var ready = false
    private let session: any ViewerAudioSessionControlling
    private var generation = UUID()
    private var activation: Task<Bool, Never>?

    /// session默认复用现有播放器音频会话；注入仅用于实际协议异步测试，不改变系统音频配置策略。
    init(session: any ViewerAudioSessionControlling = ViewerAudioSessionController()) {
        self.session = session
    }

    /// validateContext在开始和await后验证宿主当前播放权；failure只在当前有效轮次的真实激活失败时调用。
    /// 返回本轮Task，true才允许调用方unmute；false不能被调用方用来清除更新轮次的状态。
    @discardableResult func activate(validateContext: @escaping @MainActor () -> Bool,
                                     failure: @escaping @MainActor () -> Void) -> Task<Bool, Never>
    {
        generation = UUID()
        let owner = generation
        activation?.cancel()
        ready = false
        let operation = Task { @MainActor in
            // failure回调可能同步开始下一轮；旧defer不得清掉那个新Task的取消句柄。
            defer {
                if generation == owner {
                    activation = nil
                }
            }
            guard isCurrent(owner, validateContext: validateContext) else { return false }
            do {
                try await session.activate()
                guard isCurrent(owner, validateContext: validateContext) else { return false }
                ready = true
                return true
            } catch {
                guard isCurrent(owner, validateContext: validateContext) else { return false }
                ready = false
                failure()
                return false
            }
        }
        activation = operation
        return operation
    }

    /// 宿主松手/停声/换payload时同步退休旧Task并清ready，再交现有会话停止；非合作取消的迟到结果仍无发布权。
    func deactivate() {
        generation = UUID()
        activation?.cancel()
        activation = nil
        ready = false
        session.deactivate()
    }

    /// owner是一次activate的不可变身份；先判本地取消/代际，再询问宿主，旧轮次不触碰当前UI上下文。
    private func isCurrent(_ owner: UUID, validateContext: @MainActor () -> Bool) -> Bool {
        generation == owner && !Task.isCancelled && validateContext()
    }
}
