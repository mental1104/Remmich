import Foundation
import Synchronization
import Testing
@testable import Remmich

/// 实际Controller→ViewerAudioSessionControlling异步边界；continuation故意不合作取消，以验证迟到发布权。
@Suite("Live Photo audio ownership")
@MainActor struct LivePhotoPlaybackAudioControllerTests {
    /// 真实激活完成前ready=false；当前成功才发布ready并返回true，不产生失败或自动停用。
    @Test func currentSuccessPublishesOnlyAfterActivationReturns() async throws {
        let fixture = LiveAudioFixture()
        defer { fixture.close() }
        let operation = fixture.activate()
        try await fixture.started(1)
        #expect(!fixture.controller.ready)
        #expect(fixture.session.complete(1, failed: false))
        let success = await operation.value
        #expect(success && fixture.controller.ready && fixture.context.failures == 0 && fixture.session.deactivations == 0)
    }

    /// 新激活已开始/已成功后，旧success或旧failure都只能返回false，不能停新会话或清新ready。
    @Test(arguments: [false, true], [false, true])
    func replacedCompletionCannotChangeNewActivation(_ oldFailure: Bool, _ newAlreadyReady: Bool) async throws {
        let fixture = LiveAudioFixture()
        defer { fixture.close() }
        let old = fixture.activate()
        try await fixture.started(1)
        let current = fixture.activate()
        try await fixture.started(2)
        #expect(old.isCancelled)
        if newAlreadyReady {
            #expect(fixture.session.complete(2, failed: false))
            let success = await current.value
            #expect(success && fixture.controller.ready)
        }
        #expect(fixture.session.complete(1, failed: oldFailure))
        let stale = await old.value
        #expect(!stale && fixture.controller.ready == newAlreadyReady)
        #expect(fixture.context.failures == 0 && fixture.session.deactivations == 0)
        if !newAlreadyReady {
            #expect(fixture.session.complete(2, failed: false))
            let success = await current.value
            #expect(success && fixture.controller.ready)
        }
    }

    /// 当前合法失败回调恰好一次；没有成功ready，也不把失败路径的清理扩展为一次系统deactivate。
    @Test func currentFailureReportsOnlyCurrentFailure() async throws {
        let fixture = LiveAudioFixture()
        defer { fixture.close() }
        let operation = fixture.activate()
        try await fixture.started(1)
        #expect(fixture.session.complete(1, failed: true))
        let success = await operation.value
        #expect(!success && !fixture.controller.ready && fixture.context.failures == 1 && fixture.session.deactivations == 0)
    }

    /// 进入前上下文已失效时不调用音频协议，也不能通知宿主关闭另一个播放的声音偏好。
    @Test func invalidContextBeforeStartDoesNotActivateSession() async {
        let fixture = LiveAudioFixture()
        defer { fixture.close() }
        fixture.context.valid = false
        let success = await fixture.activate().value
        #expect(!success && !fixture.controller.ready && fixture.session.requests == 0 && fixture.context.failures == 0)
    }

    /// 系统异步返回前宿主失效，success/failure均拒绝发布，且旧轮次不擅自deactivate当前会话。
    @Test(arguments: [false, true])
    func invalidatedContextRejectsBothCompletionPaths(_ failed: Bool) async throws {
        let fixture = LiveAudioFixture()
        defer { fixture.close() }
        let operation = fixture.activate()
        try await fixture.started(1)
        fixture.context.valid = false
        #expect(fixture.session.complete(1, failed: failed))
        let success = await operation.value
        #expect(!success && !fixture.controller.ready && fixture.context.failures == 0 && fixture.session.deactivations == 0)
    }

    /// 显式停声同步取消当前Task/ready并调用一次deactivate；非合作系统迟到完成不得复活或重复停止。
    @Test(arguments: [false, true])
    func deactivateRetiresPendingActivation(_ failed: Bool) async throws {
        let fixture = LiveAudioFixture()
        defer { fixture.close() }
        let operation = fixture.activate()
        try await fixture.started(1)
        fixture.controller.deactivate()
        #expect(operation.isCancelled && !fixture.controller.ready && fixture.session.deactivations == 1)
        #expect(fixture.session.complete(1, failed: failed))
        let success = await operation.value
        #expect(!success && !fixture.controller.ready && fixture.context.failures == 0 && fixture.session.deactivations == 1)
    }

    /// 调用方直接取消返回Task仍禁止迟到ready/failure；系统停止权仍由显式deactivate拥有。
    @Test(arguments: [false, true])
    func callerCancellationCannotPublishLateCompletion(_ failed: Bool) async throws {
        let fixture = LiveAudioFixture()
        defer { fixture.close() }
        let operation = fixture.activate()
        try await fixture.started(1)
        operation.cancel()
        #expect(fixture.session.complete(1, failed: failed))
        let success = await operation.value
        #expect(!success && !fixture.controller.ready && fixture.context.failures == 0 && fixture.session.deactivations == 0)
    }

    /// 主执行器开始运行前已取消不会调用系统会话；不依赖sleep猜测Task是否已经进入。
    @Test func cancelledBeforeTaskEntryDoesNotActivate() async {
        let fixture = LiveAudioFixture()
        defer { fixture.close() }
        let operation = fixture.activate()
        operation.cancel()
        let success = await operation.value
        #expect(!success && fixture.session.requests == 0 && fixture.context.failures == 0 && !fixture.controller.ready)
    }

    /// 前一轮成功后重新activate会同步清ready，防止宿主在新音频会话未确认时沿用旧unmute许可。
    @Test func newActivationClearsPriorReadySynchronously() async throws {
        let fixture = LiveAudioFixture()
        defer { fixture.close() }
        let first = fixture.activate()
        try await fixture.started(1)
        #expect(fixture.session.complete(1, failed: false))
        let firstResult = await first.value
        #expect(firstResult && fixture.controller.ready)
        let next = fixture.activate()
        #expect(!fixture.controller.ready)
        try await fixture.started(2)
        #expect(fixture.session.complete(2, failed: false))
        let nextResult = await next.value
        #expect(nextResult && fixture.controller.ready)
    }

    /// failure允许宿主同步开始下一轮；旧Task的defer不能清新句柄，随后deactivate必须真正取消新Task。
    @Test func reentrantFailureKeepsNewTaskOwned() async throws {
        let fixture = LiveAudioFixture()
        defer { fixture.close() }
        let holder = LiveAudioTaskHolder()
        let first = fixture.controller.activate(validateContext: { true }, failure: { holder.task = fixture.activate() })
        try await fixture.started(1)
        #expect(fixture.session.complete(1, failed: true))
        let firstResult = await first.value
        #expect(!firstResult)
        try await fixture.started(2)
        let next = try #require(holder.task)
        fixture.controller.deactivate()
        #expect(next.isCancelled)
        #expect(fixture.session.complete(2, failed: false))
        let nextResult = await next.value
        #expect(!nextResult && !fixture.controller.ready && fixture.context.failures == 0 && fixture.session.deactivations == 1)
    }
}

/// 每例使用实际产品Controller及独立的异步音频协议来源，不触碰AVAudioSession或SwiftUI私有状态。
@MainActor private final class LiveAudioFixture {
    let session = ControlledLiveAudioSession()
    let context = LiveAudioContext()
    let controller: LivePhotoPlaybackAudioController
    /// 构造器只注入协议来源，没有预先设置Controller状态或成功结果。
    init() {
        controller = LivePhotoPlaybackAudioController(session: session)
    }

    /// 当前宿主布尔上下文与失败事实由测试控制；所有发布规则仍由真实Controller执行。
    func activate() -> Task<Bool, Never> {
        controller.activate(validateContext: { [context] in context.valid }, failure: { [context] in context.failures += 1 })
    }

    /// index为实际第几次协议调用；有界等待真实continuation安装，超时明确失败而非伪造已经开始。
    func started(_ index: Int) async throws {
        let reached = await session.waitForActivation(index)
        try #require(reached)
    }

    /// 失败或提前抛错也必须取消产品Task并释放所有系统替身continuation，不能留下无限挂起任务。
    func close() {
        controller.deactivate()
        session.releaseAll()
    }
}

/// 宿主上下文及失败回调事实仅在MainActor修改；不预先计算期望结果。
@MainActor private final class LiveAudioContext {
    var valid = true
    var failures = 0
}

/// 保留failure重入产生的真实Task，以验证旧defer没有丢弃新取消句柄。
@MainActor private final class LiveAudioTaskHolder {
    var task: Task<Bool, Never>?
}

/// 固定合成错误，只测试当前/迟到失败所有权，不伪造系统音频权限或硬件结果。
private nonisolated enum LiveAudioTestError: Error { case activation, cleanup }

/// 真实异步协议替身；Mutex只保护continuation和调用事实，故意不因Task.cancel提前恢复系统操作。
private final nonisolated class ControlledLiveAudioSession: ViewerAudioSessionControlling, Sendable {
    /// 每次请求和等待者均独立编号；continuation在锁外恢复，避免回调重入同一把锁。
    private struct State: Sendable {
        var requests = 0
        var deactivations = 0
        var closed = false
        var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
        var observers: [UUID: (index: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    }

    private let state = Mutex(State())
    /// 实际进入协议的次数，所有产品Task都必须真正调用activate才计数。
    var requests: Int {
        state.withLock { $0.requests }
    }

    /// 实际停止次数，不从Task取消或布尔状态推导。
    var deactivations: Int {
        state.withLock { $0.deactivations }
    }

    /// 不提供自动响应；取消后仍保留continuation，让测试按指定次序交付真实迟到success/error。
    func activate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let response = state.withLock { value in
                value.requests += 1
                guard !value.closed else { return (closed: true, observers: [CheckedContinuation<Bool, Never>]()) }
                value.pending[value.requests] = continuation
                let ready = value.observers.filter { $0.value.index <= value.requests }
                for token in ready.keys {
                    value.observers.removeValue(forKey: token)
                }
                return (closed: false, observers: ready.values.map(\.continuation))
            }
            if response.closed {
                continuation.resume(throwing: LiveAudioTestError.cleanup)
            }
            for observer in response.observers {
                observer.resume(returning: true)
            }
        }
    }

    /// 同步事实记录；不合作取消pending，避免替身替产品实现迟到门禁。
    func deactivate() {
        state.withLock { $0.deactivations += 1 }
    }

    /// index限定真实操作，failed选择成功/失败；未知或重复完成返回false，使测试明确报错。
    func complete(_ index: Int, failed: Bool) -> Bool {
        guard let continuation = state.withLock({ $0.pending.removeValue(forKey: index) }) else { return false }
        if failed {
            continuation.resume(throwing: LiveAudioTestError.activation)
        } else {
            continuation.resume()
        }
        return true
    }

    /// 最多等待5秒真实请求入场；watchdog只让错误测试终止，不代替成功入场事实。
    func waitForActivation(_ index: Int) async -> Bool {
        let token = UUID()
        var watchdog: Task<Void, Never>?
        let reached: Bool = await withCheckedContinuation { continuation in
            let immediate: Bool? = state.withLock { value in
                if value.requests >= index {
                    return true
                }
                if value.closed {
                    return false
                }
                value.observers[token] = (index, continuation)
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            } else {
                watchdog = Task { @Sendable [self] in
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    let observer = state.withLock { $0.observers.removeValue(forKey: token)?.continuation }
                    observer?.resume(returning: false)
                }
            }
        }
        watchdog?.cancel()
        return reached
    }

    /// 测试收尾释放所有实际等待，resume均在锁外执行；不会把未完成操作伪装成成功。
    func releaseAll() {
        let released = state.withLock { value in
            value.closed = true
            let pending = Array(value.pending.values)
            let observers = value.observers.values.map(\.continuation)
            value.pending = [:]
            value.observers = [:]
            return (pending, observers)
        }
        for continuation in released.0 {
            continuation.resume(throwing: LiveAudioTestError.cleanup)
        }
        for observer in released.1 {
            observer.resume(returning: false)
        }
    }
}
