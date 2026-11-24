import AVFAudio
import AVKit
import Dispatch
import OSLog
import Photos
import SwiftUI

struct LivePhotoPlaybackState: Equatable {
    enum Phase: Equatable {
        case idle
        case preparing(Int)
        case ready
        case playing
        case finishedWhileHeld
        case failed(Int)
        case released
    }

    enum Command: Equatable {
        case none
        case play
        case pauseAndReset
        case retryPreparation
        case release
    }

    private(set) var phase: Phase = .idle
    private(set) var isHeld = false
    private(set) var playbackCount = 0
    private var generation = 0

    var showsMotion: Bool {
        phase == .playing
    }

    var accessibilityValue: String {
        switch phase {
        case .idle:
            "Waiting"
        case .preparing:
            "Preparing"
        case .ready:
            playbackCount == 0 ? "Ready" : "Ready, played once"
        case .playing:
            "Playing"
        case .finishedWhileHeld:
            "Played once"
        case .failed:
            "Unavailable"
        case .released:
            "Released"
        }
    }

    mutating func preparationStarted() -> Int {
        generation += 1
        phase = .preparing(generation)
        return generation
    }

    mutating func preparationSucceeded(generation: Int) -> Command {
        guard phase == .preparing(generation) else { return .none }
        if isHeld {
            phase = .playing
            playbackCount += 1
            return .play
        }
        phase = .ready
        return .none
    }

    mutating func preparationFailed(generation: Int) -> Command {
        guard phase == .preparing(generation) else { return .none }
        phase = .failed(generation)
        return .none
    }

    mutating func setHeld(_ held: Bool) -> Command {
        guard held != isHeld else { return .none }
        isHeld = held

        if held {
            switch phase {
            case .ready:
                phase = .playing
                playbackCount += 1
                return .play
            case .idle, .failed, .released:
                return .retryPreparation
            case .preparing, .playing, .finishedWhileHeld:
                return .none
            }
        }

        switch phase {
        case .playing, .finishedWhileHeld:
            phase = .ready
            return .pauseAndReset
        case .idle, .preparing, .ready, .failed, .released:
            return .none
        }
    }

    mutating func playbackFinished() -> Command {
        guard phase == .playing else { return .none }
        phase = isHeld ? .finishedWhileHeld : .ready
        return .pauseAndReset
    }

    mutating func playbackFailed() -> Command {
        guard phase == .playing || phase == .finishedWhileHeld else { return .none }
        generation += 1
        phase = .failed(generation)
        return .pauseAndReset
    }

    mutating func release() -> Command {
        isHeld = false
        phase = .released
        return .release
    }
}

/// assetID/assetRevision/motionAssetID绑定查看器当前配对；media提供账号隔离读取，isHeld/playsWithSound沿用现有手势与静音选择。
/// 三个回调只报告当前播放/声音/缓存字节状态，不代表原片备份；本机证明成立时优先native，当前合法miss才使用既有motion路径。
struct LivePhotoPlaybackView: View {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "LivePhotoPlayback"
    )

    @Environment(\.scenePhase) private var scenePhase

    let assetID: String
    let assetRevision: Date
    let motionAssetID: String
    let media: MediaLibraryController
    let isHeld: Bool
    let playsWithSound: Bool
    let playbackEnded: () -> Void
    let soundPlaybackFailed: () -> Void
    let motionFileSizeChanged: (Int?) -> Void

    @State private var playbackState = LivePhotoPlaybackState()
    @State private var player: AVPlayer?
    @State private var preparedItem: AVPlayerItem?
    @State private var localLivePhoto: PHLivePhoto?
    @State private var localContextGeneration: UUID?
    @State private var playbackToken = UUID()
    @State private var localPlaybackReady = false
    @State private var retryGeneration = 0
    @State private var playTask: Task<Void, Never>?
    @State private var audioSession = LivePhotoPlaybackAudioController()

    var body: some View {
        ZStack {
            Color.clear

            if let photo = localLivePhoto, let contextGeneration = localContextGeneration {
                LocalLivePhotoPlaybackView(livePhoto: photo, assetID: assetID, contextGeneration: playbackToken,
                                           isHeld: localPlaybackReady && playbackState.isHeld && playbackState.phase == .playing,
                                           soundEnabled: playsWithSound && audioSession.ready,
                                           playbackEnded: { finishedID, finishedContext in
                                               // 原生delegate可能迟到；只允许当前payload/账号/页面状态报告自然结束。
                                               guard finishedID == assetID, finishedContext == playbackToken,
                                                     contextGeneration == media.management.generation, localContextGeneration == contextGeneration,
                                                     localLivePhoto === photo, localPlaybackReady, playbackState.phase == .playing,
                                                     playbackState.isHeld else { return }
                                               handle(playbackState.playbackFinished())
                                               playbackEnded()
                                           })
                                           .opacity(playbackState.showsMotion ? 1 : 0)
            } else if let player {
                LivePhotoPlayerSurface(player: player)
                    .opacity(playbackState.showsMotion ? 1 : 0)
            }
        }
        .task(id: preparationID) {
            await preparePlayer()
        }
        .onChange(of: isHeld, initial: true) { _, held in
            handle(playbackState.setHeld(held))
        }
        .onChange(of: playsWithSound) { _, enabled in
            player?.isMuted = true
            audioSession.deactivate()
            guard enabled, playbackState.phase == .playing else { return }
            Task { @MainActor in
                await activateSoundIfPossible()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard notification.object as AnyObject? === preparedItem, playbackState.phase == .playing, playbackState.isHeld else { return }
            Self.logger.info("Live Photo playback finished asset=\(motionAssetID.prefix(8), privacy: .private)")
            handle(playbackState.playbackFinished())
            playbackEnded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard notification.object as AnyObject? === preparedItem else { return }
            Self.logger.error("Live Photo playback failed asset=\(motionAssetID.prefix(8), privacy: .private)")
            failPlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled)) { notification in
            guard notification.object as AnyObject? === preparedItem else { return }
            Self.logger.error("Live Photo playback stalled asset=\(motionAssetID.prefix(8), privacy: .private)")
            failPlayback()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            handle(playbackState.setHeld(false))
            playbackEnded()
        }
        .onDisappear {
            handle(playbackState.release())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live Photo motion")
        .accessibilityValue(playbackState.accessibilityValue)
        .accessibilityIdentifier("asset-viewer-live-photo-player-\(assetID)")
    }

    /// 精确远端版本、本资产关联及账号/活动代际共同限定准备任务，不受其他照片的扫描进度驱动。
    private var preparationID: String {
        let association = media.localMediaMatches.association(assetID: assetID, revision: assetRevision)
        let localVersion = association.map { "\($0.localIdentity.localIdentifier)|\($0.localIdentity.modificationDate?.timeIntervalSinceReferenceDate ?? 0)" } ?? "unmatched"
        let activity = scenePhase == .active ? "active" : "inactive"
        // 只追踪本资产关联值；其他照片扫描进度不会重启当前播放，换号/换路由/版本失效则必须重建。
        return "\(assetID)|\(assetRevision.timeIntervalSinceReferenceDate)|\(motionAssetID)|\(media.management.generation)|\(localVersion)|\(activity)|\(retryGeneration)"
    }

    /// 先尝试已验证本机native，再处理当前上下文的远端miss；退出后不发布旧账号或旧页面的播放器。
    @MainActor
    private func preparePlayer() async {
        releaseCurrentPlayer()
        // 退后台取消当前task，前台由preparationID重启；不可在不可见时从本机miss继续预下载远端motion。
        guard scenePhase == .active else { return }
        let generation = playbackState.preparationStarted()
        let startedAt = Date()
        Self.logger.info(
            "Live Photo motion preparation started asset=\(motionAssetID.prefix(8), privacy: .private)"
        )

        let contextGeneration = media.management.generation
        do {
            if let photo = try await media.localLivePhoto(stillAssetID: assetID, revision: assetRevision, motionAssetID: motionAssetID,
                                                          targetPixels: .init(width: 2048, height: 2048))
            {
                try Task.checkCancellation()
                guard scenePhase == .active, media.management.generation == contextGeneration, playbackState.phase == .preparing(generation) else { return }
                localLivePhoto = photo
                localContextGeneration = contextGeneration
                handle(playbackState.preparationSucceeded(generation: generation))
                return
            }
            // 仅当前合法上下文的本机miss才能开始原有motion下载；取消/换号不得从nil继续回源。
            try Task.checkCancellation()
            guard scenePhase == .active, media.management.generation == contextGeneration else { throw CancellationError() }
            let item = try await media.livePhotoPlayerItem(assetID: motionAssetID)
            guard !Task.isCancelled, scenePhase == .active, media.management.generation == contextGeneration else { throw CancellationError() }
            guard try await item.asset.load(.isPlayable) else {
                throw LivePhotoPlaybackError.unplayable
            }
            guard !Task.isCancelled, scenePhase == .active, media.management.generation == contextGeneration else { throw CancellationError() }
            guard playbackState.phase == .preparing(generation) else {
                return
            }

            let preparedPlayer = AVPlayer(playerItem: item)
            preparedPlayer.actionAtItemEnd = .pause
            preparedPlayer.isMuted = true
            preparedItem = item
            player = preparedPlayer
            media.recordVideoMediaOrigin(media.savedPhotosLibrary == nil ? .immichResource : .devicePhotos, assetID: assetID, revision: assetRevision)
            motionFileSizeChanged(media.playerItemByteCount(item))
            Self.logger.info(
                "Live Photo motion ready asset=\(motionAssetID.prefix(8), privacy: .private) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            )
            handle(playbackState.preparationSucceeded(generation: generation))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, scenePhase == .active, media.management.generation == contextGeneration, playbackState.phase == .preparing(generation) else { return }
            await media.discardViewerLivePhotoMotion(assetID: motionAssetID)
            guard !Task.isCancelled, scenePhase == .active, media.management.generation == contextGeneration, playbackState.phase == .preparing(generation) else { return }
            Self.logger.error(
                "Live Photo motion preparation failed asset=\(motionAssetID.prefix(8), privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
            handle(playbackState.preparationFailed(generation: generation))
            playbackEnded()
        }
    }

    @MainActor
    private func handle(_ command: LivePhotoPlaybackState.Command) {
        switch command {
        case .none:
            break
        case .play:
            startPlayback()
        case .pauseAndReset:
            pauseAndReset()
        case .retryPreparation:
            retryGeneration += 1
        case .release:
            releaseCurrentPlayer()
        }
    }

    /// 为当前长按建立新播放身份，复用已准备的native或AVPlayer，并使异步音频只归属本轮。
    @MainActor
    private func startPlayback() {
        guard scenePhase == .active else {
            handle(playbackState.setHeld(false))
            return
        }
        // 每次长按轮换身份，native child也随之换view；旧结束/音频回调不能冒充本轮。
        playbackToken = UUID()
        audioSession.deactivate()
        if let photo = localLivePhoto {
            startLocalPlayback(photo)
            return
        }
        guard let player, player.currentItem === preparedItem else {
            failPlayback()
            return
        }
        let token = playbackToken
        let contextGeneration = media.management.generation
        playTask?.cancel()
        playTask = Task { @MainActor in
            await player.seek(to: .zero)
            guard !Task.isCancelled,
                  playbackToken == token, media.management.generation == contextGeneration,
                  playbackState.phase == .playing,
                  playbackState.isHeld,
                  self.player === player,
                  player.currentItem === preparedItem
            else { return }
            guard preparedItem?.status != .failed else {
                failPlayback()
                return
            }
            Self.logger.info(
                "Live Photo playback started asset=\(motionAssetID.prefix(8), privacy: .private)"
            )
            if playsWithSound {
                await activateSoundIfPossible()
            }
            guard !Task.isCancelled,
                  playbackToken == token, media.management.generation == contextGeneration,
                  playbackState.phase == .playing,
                  playbackState.isHeld,
                  self.player === player,
                  player.currentItem === preparedItem
            else {
                return
            }
            player.play()
        }
    }

    /// photo是已经完成双端配对验证的当前payload；等待现有音频会话后才允许native view响应本轮长按。
    @MainActor
    private func startLocalPlayback(_ photo: PHLivePhoto) {
        playTask?.cancel()
        localPlaybackReady = false
        let token = playbackToken
        let contextGeneration = media.management.generation
        playTask = Task { @MainActor in
            guard !Task.isCancelled, playbackState.phase == .playing, playbackState.isHeld, localLivePhoto === photo,
                  playbackToken == token, media.management.generation == contextGeneration, localContextGeneration == contextGeneration else { return }
            if playsWithSound {
                await activateSoundIfPossible()
            }
            guard !Task.isCancelled, playbackState.phase == .playing, playbackState.isHeld, localLivePhoto === photo,
                  playbackToken == token, media.management.generation == contextGeneration, localContextGeneration == contextGeneration else { return }
            localPlaybackReady = true
        }
    }

    /// 松手/自然结束退休本轮任务与声音；保留已验证媒体，下一次长按仍必须使用新身份。
    @MainActor
    private func pauseAndReset() {
        playTask?.cancel()
        playTask = nil
        playbackToken = UUID()
        localPlaybackReady = false
        player?.pause()
        player?.seek(to: .zero)
        audioSession.deactivate()
    }

    @MainActor
    private func failPlayback() {
        let command = playbackState.playbackFailed()
        guard command != .none else { return }
        handle(command)
        releaseCurrentPlayer()
        playbackEnded()
    }

    /// 准备重启或页面退出时清空两种播放器及回调发布权；既有远端motion文件仍归查看器缓存管理。
    @MainActor
    private func releaseCurrentPlayer() {
        playTask?.cancel()
        playTask = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        localLivePhoto = nil
        localContextGeneration = nil
        playbackToken = UUID()
        localPlaybackReady = false
        audioSession.deactivate()
        motionFileSizeChanged(nil)
        preparedItem = nil
        // The paired-motion file is owned by the viewer session so paging back
        // can prepare a new player item without another Immich request.
    }

    /// 捕获当前播放和账号身份，等待独立音频controller；只有仍有效的成功请求才unmute当前AVPlayer。
    @MainActor
    private func activateSoundIfPossible() async {
        let token = playbackToken
        let contextGeneration = media.management.generation
        let activation = audioSession.activate(validateContext: {
            playbackToken == token && media.management.generation == contextGeneration
                && scenePhase == .active && playbackState.phase == .playing && playbackState.isHeld && playsWithSound
        }, failure: {
            // controller仅允许当前音频请求报告失败，迟到失败不能关闭新一轮的声音设置。
            Self.logger.error("Live Photo audio session activation failed")
            soundPlaybackFailed()
        })
        let activated = await activation.value
        guard activated, !Task.isCancelled, scenePhase == .active, playbackToken == token, media.management.generation == contextGeneration,
              playbackState.phase == .playing, playbackState.isHeld, playsWithSound else { return }
        player?.isMuted = false
        Self.logger.info("Live Photo audio session activated asset=\(motionAssetID.prefix(8), privacy: .private)")
    }
}

private enum LivePhotoPlaybackError: LocalizedError {
    case unplayable

    var errorDescription: String? {
        "The paired Live Photo motion is not playable."
    }
}

private struct LivePhotoPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context _: Context) -> LivePhotoPlayerView {
        let view = LivePhotoPlayerView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LivePhotoPlayerView, context _: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleUIView(_ view: LivePhotoPlayerView, coordinator _: Void) {
        view.playerLayer.player = nil
    }
}

private final class LivePhotoPlayerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.backgroundColor = UIColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
