import Foundation
import PhotosUI
import Testing
import UIKit
@testable import Remmich

/// 真实Coordinator/Container/PhotosUI delegate路径的命令测试；不创建PHLivePhoto，也不证明系统实际媒体可播。
@Suite("Local Live Photo playback lifecycle")
@MainActor struct LocalLivePhotoPlaybackViewTests {
    /// 准备完成但未按住只停在ready；sound开关更新真实native属性，不隐式start或生成结束事件。
    @Test(arguments: [false, true])
    func idleBindingDoesNotAutoplay(_ sound: Bool) {
        let fixture = LocalLivePlaybackFixture()
        defer { fixture.close() }
        fixture.update(held: false, sound: sound)
        #expect(fixture.native.starts.isEmpty && fixture.native.stops == 0)
        #expect(fixture.native.isMuted == !sound && fixture.coordinator.playbackState.phase == .ready)
        #expect(fixture.events.began.isEmpty && fixture.events.ended.isEmpty)
    }

    /// 一次外层长按仅请求一次full；自然结束不循环，松手后下一次长按才允许重播。
    @Test func oneHoldPlaysOnceAndNewHoldCanReplay() throws {
        let fixture = LocalLivePlaybackFixture()
        defer { fixture.close() }
        fixture.update(held: true)
        let first = try #require(fixture.native.delegate as? LocalLivePhotoPlaybackDelegate)
        fixture.update(held: true)
        #expect(fixture.native.starts == [.full] && fixture.coordinator.playbackState.playbackCount == 1)
        first.livePhotoView(fixture.native, willBeginPlaybackWith: .full)
        first.livePhotoView(fixture.native, willBeginPlaybackWith: .full)
        first.livePhotoView(fixture.native, didEndPlaybackWith: .full)
        first.livePhotoView(fixture.native, didEndPlaybackWith: .full)
        #expect(fixture.events.began == [fixture.identity] && fixture.events.ended == [fixture.identity])
        #expect(fixture.coordinator.playbackState.phase == .finishedWhileHeld && fixture.native.delegate == nil)
        fixture.update(held: true)
        #expect(fixture.native.starts == [.full])
        fixture.update(held: false)
        fixture.update(held: true)
        #expect(fixture.native.starts == [.full, .full] && fixture.coordinator.playbackState.playbackCount == 2)
    }

    /// 松手先撤delegate再stop；即使停止同步投递旧didEnd，也不能伪造一次自然播放结束。
    @Test func releaseStopsBeforeOldDelegateCanPublish() throws {
        let fixture = LocalLivePlaybackFixture()
        defer { fixture.close() }
        fixture.update(held: true)
        let old = try #require(fixture.native.delegate as? LocalLivePhotoPlaybackDelegate)
        fixture.native.onStop = { old.livePhotoView(fixture.native, didEndPlaybackWith: .full) }
        fixture.update(held: false)
        #expect(fixture.native.stops == 1 && fixture.native.delegateWasNilAtStop == [true])
        #expect(fixture.coordinator.playbackState.phase == .ready && fixture.events.ended.isEmpty)
        #expect(!old.livePhotoView(fixture.native, canBeginPlaybackWith: .full))
        fixture.native.onStop = nil
    }

    /// 同native view的新长按有独立relay token；旧willBegin/didEnd不能开始或终止新播放。
    @Test func priorHoldRelayCannotFinishNewHold() throws {
        let fixture = LocalLivePlaybackFixture()
        defer { fixture.close() }
        fixture.update(held: true)
        let old = try #require(fixture.native.delegate as? LocalLivePhotoPlaybackDelegate)
        fixture.update(held: false)
        fixture.update(held: true)
        let current = try #require(fixture.native.delegate as? LocalLivePhotoPlaybackDelegate)
        #expect(current !== old)
        old.livePhotoView(fixture.native, willBeginPlaybackWith: .full)
        old.livePhotoView(fixture.native, didEndPlaybackWith: .full)
        #expect(fixture.coordinator.playbackState.phase == .playing && fixture.events.began.isEmpty && fixture.events.ended.isEmpty)
        current.livePhotoView(fixture.native, willBeginPlaybackWith: .full)
        current.livePhotoView(fixture.native, didEndPlaybackWith: .full)
        #expect(fixture.events.began == [fixture.identity] && fixture.events.ended == [fixture.identity])
    }

    /// 换asset、换context或同身份换native表面均退休旧事件；只允许新绑定身份进入宿主回调。
    @Test(arguments: ["asset", "generation", "surface"])
    func replacementRejectsRetiredNativeAndRelay(_ change: String) throws {
        let fixture = LocalLivePlaybackFixture()
        defer { fixture.close() }
        fixture.update(held: true)
        let old = try #require(fixture.native.delegate as? LocalLivePhotoPlaybackDelegate)
        let nextIdentity = LocalLivePhotoPlaybackIdentity(assetID: change == "asset" ? "synthetic-next-asset" : fixture.identity.assetID,
                                                          contextGeneration: change == "generation" ? UUID() : fixture.identity.contextGeneration)
        let next = LocalLivePlaybackNativeView(frame: .zero)
        fixture.coordinator.bindPreparedView(next, identity: nextIdentity)
        fixture.container.installPreparedView(next)
        fixture.update(held: true)
        let current = try #require(next.delegate as? LocalLivePhotoPlaybackDelegate)
        #expect(fixture.native.stops == 1 && fixture.native.delegate == nil && fixture.native.superview == nil)
        old.livePhotoView(fixture.native, willBeginPlaybackWith: .full)
        old.livePhotoView(fixture.native, didEndPlaybackWith: .full)
        current.livePhotoView(fixture.native, didEndPlaybackWith: .full)
        #expect(fixture.events.began.isEmpty && fixture.events.ended.isEmpty && fixture.coordinator.playbackState.phase == .playing)
        current.livePhotoView(next, willBeginPlaybackWith: .full)
        current.livePhotoView(next, didEndPlaybackWith: .full)
        #expect(fixture.events.began == [nextIdentity] && fixture.events.ended == [nextIdentity] && next.starts == [.full])
    }

    /// 系统hint或错误view不拥有外层full播放权；不会因为错误结束事件把当前播放提前停止。
    @Test(arguments: ["hint", "foreign-view"])
    func unrelatedNativeEventsCannotChangeCurrentPlayback(_ kind: String) throws {
        let fixture = LocalLivePlaybackFixture()
        defer { fixture.close() }
        fixture.update(held: true)
        let relay = try #require(fixture.native.delegate as? LocalLivePhotoPlaybackDelegate)
        let view = kind == "foreign-view" ? LocalLivePlaybackNativeView(frame: .zero) : fixture.native
        let style: PHLivePhotoViewPlaybackStyle = kind == "hint" ? .hint : .full
        #expect(!relay.livePhotoView(view, canBeginPlaybackWith: style))
        relay.livePhotoView(view, willBeginPlaybackWith: style)
        relay.livePhotoView(view, didEndPlaybackWith: style)
        #expect(fixture.native.stops == 0 && fixture.coordinator.playbackState.phase == .playing)
        #expect(fixture.events.began.isEmpty && fixture.events.ended.isEmpty)
    }

    /// 播放中开关声音仅变更isMuted，不另一次start或把音量偏好当作原生音频播放成功证明。
    @Test func soundPreferenceChangesWithoutRestartingPlayback() {
        let fixture = LocalLivePlaybackFixture()
        defer { fixture.close() }
        fixture.update(held: true)
        #expect(fixture.native.isMuted)
        fixture.update(held: true, sound: true)
        #expect(!fixture.native.isMuted)
        fixture.update(held: true, sound: false)
        #expect(fixture.native.isMuted && fixture.native.starts == [.full])
    }

    /// 真实容器配置使用UIView的aspectFit、禁用系统手势并填满父bounds；不依赖macOS专有contentMode枚举。
    @Test func nativeSurfaceUsesPassiveAspectFitLayout() {
        let fixture = LocalLivePlaybackFixture()
        defer { fixture.close() }
        fixture.container.frame = CGRect(x: 0, y: 0, width: 280, height: 180)
        fixture.container.layoutIfNeeded()
        #expect(fixture.native.contentMode == UIView.ContentMode.scaleAspectFit)
        #expect(fixture.native.frame == fixture.container.bounds && fixture.native.superview === fixture.container)
        #expect(!fixture.container.isUserInteractionEnabled && !fixture.native.isUserInteractionEnabled)
        #expect(!fixture.native.playbackGestureRecognizer.isEnabled && fixture.native.clipsToBounds)
    }

    /// 真正Representable销毁入口同步停止/拆除native子view，旧relay之后调用也不能发布当前事件。
    @Test func dismantleStopsAndDetachesActualContainer() throws {
        let fixture = LocalLivePlaybackFixture()
        defer { fixture.close() }
        fixture.update(held: true)
        let old = try #require(fixture.native.delegate as? LocalLivePhotoPlaybackDelegate)
        LocalLivePhotoPlaybackView.dismantleUIView(fixture.container, coordinator: fixture.coordinator)
        #expect(fixture.native.stops == 1 && fixture.native.delegate == nil && fixture.native.superview == nil)
        #expect(fixture.container.nativeView == nil && fixture.coordinator.playbackState.phase == .released)
        old.livePhotoView(fixture.native, willBeginPlaybackWith: .full)
        old.livePhotoView(fixture.native, didEndPlaybackWith: .full)
        #expect(fixture.events.began.isEmpty && fixture.events.ended.isEmpty)
    }

    /// 松手后迟到的开始/结束不回传；再次bind准备但未按住也不能由旧系统事件触发播放。
    @Test func retiredEventsDoNotAutoplayReboundIdleSurface() throws {
        let fixture = LocalLivePlaybackFixture()
        defer { fixture.close() }
        fixture.update(held: true)
        let old = try #require(fixture.native.delegate as? LocalLivePhotoPlaybackDelegate)
        fixture.coordinator.release()
        fixture.coordinator.bindPreparedView(fixture.native, identity: fixture.identity)
        fixture.update(held: false)
        old.livePhotoView(fixture.native, willBeginPlaybackWith: .full)
        old.livePhotoView(fixture.native, didEndPlaybackWith: .full)
        #expect(fixture.native.starts == [.full] && fixture.coordinator.playbackState.phase == .ready)
        #expect(fixture.events.began.isEmpty && fixture.events.ended.isEmpty)
    }
}

/// 仅组合真实容器与真实协调器；native替身记录公开命令，未设置PHLivePhoto，不声称触发了系统媒体播放。
@MainActor private final class LocalLivePlaybackFixture {
    let container = LocalLivePhotoPlaybackContainer(frame: .zero)
    let coordinator = LocalLivePhotoPlaybackCoordinator()
    let native = LocalLivePlaybackNativeView(frame: .zero)
    let identity = LocalLivePhotoPlaybackIdentity(assetID: "synthetic-live-asset", contextGeneration: UUID())
    let events = LocalLivePlaybackEvents()

    /// 原生对象为空是明确测试限制；bind只准备真实状态机与事件门禁，不伪造PHLivePhoto正例。
    init() {
        container.installPreparedView(native)
        coordinator.bindPreparedView(native, identity: identity)
    }

    /// held/sound驱动实际产品协调器；两个回调只记入产品真实发出的身份。
    func update(held: Bool, sound: Bool = false) {
        coordinator.update(isHeld: held, soundEnabled: sound,
                           playbackBegan: { [events] asset, context in events.began.append(.init(assetID: asset, contextGeneration: context)) },
                           playbackEnded: { [events] asset, context in events.ended.append(.init(assetID: asset, contextGeneration: context)) })
    }

    /// 每个测试使用产品销毁入口同步收尾，没有等待任务、系统资源请求或遗留delegate。
    func close() {
        LocalLivePhotoPlaybackView.dismantleUIView(container, coordinator: coordinator)
    }
}

/// MainActor回调事实集合，不能由fixture预先推导产品应回传哪个身份。
@MainActor private final class LocalLivePlaybackEvents {
    var began: [LocalLivePhotoPlaybackIdentity] = []
    var ended: [LocalLivePhotoPlaybackIdentity] = []
}

/// 真正PhotosUI子类仅记录公开start/stop命令；没有payload，不调用super启动解码或伪造可播放媒体。
@MainActor private final class LocalLivePlaybackNativeView: PHLivePhotoView {
    private(set) var starts: [PHLivePhotoViewPlaybackStyle] = []
    private(set) var stops = 0
    private(set) var delegateWasNilAtStop: [Bool] = []
    var onStop: (@MainActor () -> Void)?

    /// playbackStyle为产品实际提交的命令；记录.full/.hint，不把命令发送计数当作系统播放成功。
    override func startPlayback(with playbackStyle: PHLivePhotoViewPlaybackStyle) {
        starts.append(playbackStyle)
    }

    /// 记录产品是否先撤delegate再stop，onStop可模拟同步迟到结束事件以验证真实发布门禁。
    override func stopPlayback() {
        stops += 1
        delegateWasNilAtStop.append(delegate == nil)
        onStop?()
    }
}
