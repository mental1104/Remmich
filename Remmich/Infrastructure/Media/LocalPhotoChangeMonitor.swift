import Photos

/// 公开Photos变更通知桥；不传递PHChange/PHAsset跨actor，只要求Controller失效并重新关联当前源。
@MainActor final class LocalPhotoChangeMonitor: NSObject, PHPhotoLibraryChangeObserver {
    private let changed: @MainActor @Sendable () -> Void
    private var active = true

    /// changed只在MainActor调用；初始化注册、释放注销，Controller停用/清登录即释放此对象。
    init(changed: @escaping @MainActor @Sendable () -> Void) {
        self.changed = changed
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    /// 不保留系统观察引用，避免已停用账号继续触发后台扫描。
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    /// Controller停用/换namespace时显式注销，即使系统暂时保留observer也不能继续发布通知。
    func stop() {
        guard active else { return }
        active = false; PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    /// 系统私有队列可能回调；只把Sendable闭包调度到主执行器，释放后的迟到通知不再发布。
    nonisolated func photoLibraryDidChange(_: PHChange) {
        Task { @MainActor [weak self] in
            guard let self, active else { return }
            changed()
        }
    }
}
