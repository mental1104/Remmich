import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit

/// 只展示已由调用方验证的本机PHLivePhoto；外层仍负责权限、账号、配对证明、读取失败与远端回退。
/// isHeld来自现有长按手势，soundEnabled只控制本视图静音；回调携带绑定身份，不能据此确认备份完成。
@MainActor struct LocalLivePhotoPlaybackView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let assetID: String
    let contextGeneration: UUID
    let isHeld: Bool
    let soundEnabled: Bool
    var playbackBegan: @MainActor (String, UUID) -> Void = { _, _ in }
    let playbackEnded: @MainActor (String, UUID) -> Void

    /// 每个SwiftUI表示实例只有一个协调器；系统delegate和播放状态均限定在MainActor。
    func makeCoordinator() -> LocalLivePhotoPlaybackCoordinator {
        LocalLivePhotoPlaybackCoordinator()
    }

    /// context提供当前协调器；返回无系统手势的容器，避免与Remmich外层长按重复驱动播放。
    func makeUIView(context: Context) -> LocalLivePhotoPlaybackContainer {
        let container = LocalLivePhotoPlaybackContainer(frame: .zero)
        updateUIView(container, context: context)
        return container
    }

    /// uiView只接收当前合法payload；身份/代际/对象替换会先退休旧native view，而非重绑其迟到delegate。
    func updateUIView(_ uiView: LocalLivePhotoPlaybackContainer, context: Context) {
        uiView.update(livePhoto: livePhoto, identity: .init(assetID: assetID, contextGeneration: contextGeneration),
                      coordinator: context.coordinator, isHeld: isHeld, soundEnabled: soundEnabled,
                      playbackBegan: playbackBegan, playbackEnded: playbackEnded)
    }

    /// SwiftUI销毁时先撤销delegate与播放权，再清除PHLivePhoto及子视图；不发布一次虚构的自然结束回调。
    static func dismantleUIView(_ uiView: LocalLivePhotoPlaybackContainer, coordinator: LocalLivePhotoPlaybackCoordinator) {
        coordinator.release()
        uiView.clear()
    }
}

/// 一个本机播放绑定的宿主身份；contextGeneration由账号/路由/页面拥有者提供，payload另按对象身份比较。
nonisolated struct LocalLivePhotoPlaybackIdentity: Equatable, Sendable {
    let assetID: String
    let contextGeneration: UUID
}

/// 每次payload或宿主身份变化均换一个真实PHLivePhotoView；旧view的系统事件无法误认成新payload事件。
@MainActor final class LocalLivePhotoPlaybackContainer: UIView {
    private var livePhoto: PHLivePhoto?
    private var identity: LocalLivePhotoPlaybackIdentity?
    private(set) var nativeView: PHLivePhotoView?

    /// frame为SwiftUI初始布局；父手势拥有触摸事件，此容器只提供被动的aspect-fit播放表面。
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    /// 本组件仅由UIViewRepresentable创建，不接受storyboard解码路径。
    required init?(coder _: NSCoder) {
        nil
    }

    /// livePhoto必须是真实读取结果；identity限定宿主，held/sound及两个回调只影响当前绑定。
    /// 相同payload的普通SwiftUI重算不会重播；替换先停止旧绑定，再安装全新native view和relay。
    func update(livePhoto: PHLivePhoto, identity: LocalLivePhotoPlaybackIdentity,
                coordinator: LocalLivePhotoPlaybackCoordinator, isHeld: Bool, soundEnabled: Bool,
                playbackBegan: @escaping @MainActor (String, UUID) -> Void,
                playbackEnded: @escaping @MainActor (String, UUID) -> Void)
    {
        if self.identity != identity || self.livePhoto !== livePhoto {
            coordinator.release()
            let view = PHLivePhotoView(frame: bounds)
            view.livePhoto = livePhoto
            installPreparedView(view)
            self.livePhoto = livePhoto
            self.identity = identity
            coordinator.bindPreparedView(view, identity: identity)
        }
        coordinator.update(isHeld: isHeld, soundEnabled: soundEnabled, playbackBegan: playbackBegan, playbackEnded: playbackEnded)
    }

    /// view已由生产update赋值真实payload；此窄布局路径也供无媒体fixture核对native配置，不证明可播放性。
    func installPreparedView(_ view: PHLivePhotoView) {
        nativeView?.removeFromSuperview()
        nativeView = view
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.playbackGestureRecognizer.isEnabled = false
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 协调器已经撤销播放权后清空容器；不保留旧Photos对象或delegate。
    func clear() {
        nativeView?.delegate = nil
        nativeView?.livePhoto = nil
        nativeView?.removeFromSuperview()
        nativeView = nil
        livePhoto = nil
        identity = nil
    }
}

/// 复用Remmich既有一次长按播放状态；delegate必须同时匹配native view、播放token和宿主身份才有发布权。
@MainActor final class LocalLivePhotoPlaybackCoordinator {
    private(set) var playbackState = LivePhotoPlaybackState()
    private weak var nativeView: PHLivePhotoView?
    private var identity: LocalLivePhotoPlaybackIdentity?
    private var relay: LocalLivePhotoPlaybackDelegate?
    private var playbackToken: UUID?
    private var reportedStart = false
    private var playbackBegan: @MainActor (String, UUID) -> Void = { _, _ in }
    private var playbackEnded: @MainActor (String, UUID) -> Void = { _, _ in }

    /// view是调用方已准备的表面，identity绑定回调归属；这里只准备状态，绝不自动start或生成PHLivePhoto。
    func bindPreparedView(_ view: PHLivePhotoView, identity: LocalLivePhotoPlaybackIdentity) {
        release()
        nativeView = view
        self.identity = identity
        playbackState = LivePhotoPlaybackState()
        let preparation = playbackState.preparationStarted()
        _ = playbackState.preparationSucceeded(generation: preparation)
        view.isMuted = true
    }

    /// held从外层现有手势传入；soundEnabled可在播放中改变，回调只在当前真实delegate事件发生时调用。
    func update(isHeld: Bool, soundEnabled: Bool,
                playbackBegan: @escaping @MainActor (String, UUID) -> Void,
                playbackEnded: @escaping @MainActor (String, UUID) -> Void)
    {
        self.playbackBegan = playbackBegan
        self.playbackEnded = playbackEnded
        nativeView?.isMuted = !soundEnabled
        handle(playbackState.setHeld(isHeld))
    }

    /// 销毁或替换时先撤销所有事件身份，再停止/清除旧payload；系统同步或迟到didEnd都不能发布回调。
    func release() {
        _ = playbackState.release()
        stopCurrentPlayback()
        nativeView?.livePhoto = nil
        nativeView = nil
        identity = nil
        playbackBegan = { _, _ in }
        playbackEnded = { _, _ in }
    }

    /// view/token必须属于当前full播放；hint、旧表面、已释放或同次长按已结束的事件均拒绝。
    func canBegin(_ view: PHLivePhotoView, token: UUID, style: PHLivePhotoViewPlaybackStyle) -> Bool {
        nativeView === view && playbackToken == token && style == .full && playbackState.phase == .playing && playbackState.isHeld
    }

    /// 开始只回传一次当前绑定身份；重复willBegin不产生重复宿主事件。
    func didBegin(_ view: PHLivePhotoView, token: UUID, style: PHLivePhotoViewPlaybackStyle) {
        guard canBegin(view, token: token, style: style), !reportedStart, let identity else { return }
        reportedStart = true
        playbackBegan(identity.assetID, identity.contextGeneration)
    }

    /// 真正自然结束先停回静态画面，再回传绑定身份；仍按住时保持finishedWhileHeld，禁止自动循环。
    func didEnd(_ view: PHLivePhotoView, token: UUID, style: PHLivePhotoViewPlaybackStyle) {
        guard canBegin(view, token: token, style: style), let identity else { return }
        let ended = playbackEnded
        handle(playbackState.playbackFinished())
        ended(identity.assetID, identity.contextGeneration)
    }

    /// 将既有状态命令映射到公开PhotosUI接口；准备失败/重试仍由上层reader拥有，本组件不请求资源。
    private func handle(_ command: LivePhotoPlaybackState.Command) {
        switch command {
        case .play:
            guard let nativeView else { return }
            let token = UUID()
            playbackToken = token
            reportedStart = false
            let relay = LocalLivePhotoPlaybackDelegate(coordinator: self, token: token)
            self.relay = relay
            nativeView.delegate = relay
            nativeView.startPlayback(with: .full)
        case .pauseAndReset, .release:
            stopCurrentPlayback()
        case .none, .retryPreparation:
            break
        }
    }

    /// 先解绑delegate/token再stop，避免停止触发的同步结束被误当自然完成；保留still供松手后显示。
    private func stopCurrentPlayback() {
        playbackToken = nil
        reportedStart = false
        nativeView?.delegate = nil
        relay = nil
        nativeView?.stopPlayback()
    }
}

/// 每次start独立的弱引用delegate；PhotosUI主线程事件必须通过协调器验证其原始token才能回传宿主。
@MainActor final class LocalLivePhotoPlaybackDelegate: NSObject, PHLivePhotoViewDelegate {
    private weak var coordinator: LocalLivePhotoPlaybackCoordinator?
    private let token: UUID

    /// coordinator不由delegate保活；token唯一标识一次明确full播放，与后续同view新播放区分。
    init(coordinator: LocalLivePhotoPlaybackCoordinator, token: UUID) {
        self.coordinator = coordinator
        self.token = token
    }

    /// 系统询问的view/style仍必须属于当前外层长按；不启用系统hint或自有手势。
    func livePhotoView(_ livePhotoView: PHLivePhotoView, canBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) -> Bool {
        coordinator?.canBegin(livePhotoView, token: token, style: playbackStyle) == true
    }

    /// 系统开始事件保留原始view/token，不读取可能已被替换的宿主身份。
    func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        coordinator?.didBegin(livePhotoView, token: token, style: playbackStyle)
    }

    /// 系统结束事件仅提交给创建此relay的播放代际，旧relay不能结束新播放。
    func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        coordinator?.didEnd(livePhotoView, token: token, style: playbackStyle)
    }
}
