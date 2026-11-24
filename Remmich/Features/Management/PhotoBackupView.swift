import Observation
import Photos
import SwiftUI

@MainActor
@Observable
final class PhotoBackupController {
    struct Album: Identifiable {
        let id: String
        let title: String
        let collection: PHAssetCollection
    }

    var albums: [Album] = []
    var selected: Set<String> = []
    var allowCloud = false
    private(set) var running = false
    private(set) var completed = 0
    private(set) var duplicates = 0
    private(set) var total = 0
    private(set) var failures: [String] = []
    private(set) var status = "仅在点击开始后上传所选相簿，默认不下载 iCloud 原片。"
    @ObservationIgnored private var task: Task<Void, Never>?

    func loadAlbums() async {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            status = "需要照片访问权限；可以在系统设置中仅授权选定照片。"; return
        }
        var choices: [Album] = []
        for result in [PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil),
                       PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)]
        {
            result.enumerateObjects { collection, _, _ in
                choices.append(Album(id: collection.localIdentifier, title: collection.localizedTitle ?? "相簿", collection: collection))
            }
        }
        albums = choices
        status = authorization == .limited ? "当前仅可备份系统已授权的照片。选择相簿后开始。" : "选择要备份的相簿。不会删除或修改手机上的照片。"
    }

    func cancel() {
        task?.cancel()
        if running {
            status = "正在停止；已发送的文件可能已被服务器保存，再次开始会重新查重。"
        }
    }

    func start(using controller: LibraryManagementController) {
        guard !running, controller.client != nil else { return }
        var unique: [String: PHAsset] = [:]
        for album in albums where selected.contains(album.id) {
            PHAsset.fetchAssets(in: album.collection, options: nil).enumerateObjects { asset, _, _ in
                if asset.mediaType == .image || asset.mediaType == .video {
                    unique[asset.localIdentifier] = asset
                }
            }
        }
        let assets = unique.values.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        total = assets.count
        completed = 0; duplicates = 0; failures = []
        running = true
        let owner = controller.generation
        let cloud = allowCloud
        task = Task {
            defer {
                running = false; task = nil
                controller.publishChanges(ifGeneration: owner)
            }
            for (index, asset) in assets.enumerated() {
                do {
                    try Task.checkCancellation()
                    guard owner == controller.generation else { throw LibraryWriteError.changedAccount }
                    status = "正在备份 \(index + 1)/\(total)…"
                    let resource = try await Self.export(asset, allowCloud: cloud)
                    defer { try? FileManager.default.removeItem(at: resource.directory) }
                    try Task.checkCancellation()
                    guard owner == controller.generation else { throw LibraryWriteError.changedAccount }
                    let result = try await controller.perform(publishChange: false) { client in
                        var motionID: String?
                        if let motion = resource.motion {
                            let result = try await client.upload(file: motion.file, filename: motion.name, created: resource.created,
                                                                 modified: resource.modified, favorite: false, hidden: true)
                            motionID = result.id
                        }
                        let result = try await client.upload(file: resource.primary.file, filename: resource.primary.name,
                                                             created: resource.created, modified: resource.modified,
                                                             favorite: resource.favorite, livePhotoVideoID: motionID)
                        if let motionID, result.status == "duplicate" {
                            let existing = try await client.asset(result.id)
                            guard existing.livePhotoVideoId?.lowercased() == motionID.lowercased() else {
                                // 不能仅因静态帧重复就宣称 Live Photo 已完整备份。
                                throw BackupError.incompleteLivePhoto
                            }
                        }
                        return result
                    }
                    completed += 1
                    if result.status == "duplicate" {
                        duplicates += 1
                    }
                } catch {
                    if Task.isCancelled || owner != controller.generation {
                        break
                    }
                    failures.append("第 \(index + 1) 项：\(error.localizedDescription)")
                }
            }
            status = Task.isCancelled || owner != controller.generation
                ? "已停止。成功 \(completed)，失败 \(failures.count)。重新开始会按校验和查重。"
                : "备份结束：成功 \(completed)（其中重复 \(duplicates)），失败 \(failures.count)。"
        }
    }

    nonisolated struct Resource: Sendable {
        struct File: Sendable { let file: URL; let name: String }
        let directory: URL
        let primary: File
        let motion: File?
        let created: Date
        let modified: Date
        let favorite: Bool
    }

    nonisolated enum BackupError: LocalizedError {
        case unsupportedResource, incompleteLivePhoto
        var errorDescription: String? {
            switch self {
            case .unsupportedResource: "此资源包含不支持的原片组合（例如 RAW+JPEG），未按完整备份处理。"
            case .incompleteLivePhoto: "静态帧已存在，但 Live Photo 视频配对不一致，请在服务器检查；未计为成功。"
            }
        }
    }

    private static func export(_ asset: PHAsset, allowCloud: Bool) async throws -> Resource {
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.contains(where: { $0.type == .alternatePhoto }),
              let primary = resources.first(where: { $0.type == (asset.mediaType == .video ? .video : .photo) })
        else {
            throw BackupError.unsupportedResource
        }
        let motion = resources.first { $0.type == .pairedVideo }
        if asset.mediaSubtypes.contains(.photoLive), motion == nil {
            throw BackupError.incompleteLivePhoto
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemmichBackup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let file = try await exportResource(primary, directory: directory, allowCloud: allowCloud)
            let video: Resource.File? = if let motion {
                try await exportResource(motion, directory: directory, allowCloud: allowCloud)
            } else {
                nil
            }
            return Resource(directory: directory, primary: file, motion: video, created: asset.creationDate ?? Date(),
                            modified: asset.modificationDate ?? asset.creationDate ?? Date(), favorite: asset.isFavorite)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func exportResource(_ resource: PHAssetResource, directory: URL, allowCloud: Bool) async throws -> Resource.File {
        try Task.checkCancellation()
        let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension((resource.originalFilename as NSString).pathExtension)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowCloud
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        try Task.checkCancellation()
        return .init(file: file, name: resource.originalFilename)
    }
}

struct PhotoBackupView: View {
    let controller: LibraryManagementController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var backup = PhotoBackupController()
    @State private var confirmsStart = false

    var body: some View {
        NavigationStack {
            Form {
                Section("手动备份") {
                    Text(backup.status)
                    Text("当前为前台备份：离开此页面、锁屏、切换账户或进入后台会停止。支持照片、视频和原始 Live Photo 配对；不删除手机原片。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if backup.running {
                        ProgressView(value: Double(backup.completed + backup.failures.count), total: Double(max(1, backup.total)))
                        Button("停止", role: .destructive) { backup.cancel() }
                    } else {
                        Button("读取可备份相簿…") { Task { await backup.loadAlbums() } }
                        Toggle("允许下载 iCloud 原片（可能使用移动数据）", isOn: $backup.allowCloud)
                        ForEach(backup.albums) { album in
                            Toggle(album.title, isOn: Binding(
                                get: { backup.selected.contains(album.id) },
                                set: {
                                    if $0 {
                                        backup.selected.insert(album.id)
                                    } else {
                                        backup.selected.remove(album.id)
                                    }
                                }
                            ))
                        }
                        Button("开始备份所选相簿") { confirmsStart = true }
                            .disabled(backup.selected.isEmpty || controller.client == nil || controller.busy)
                    }
                }
                if !backup.failures.isEmpty {
                    Section("失败项目（重新开始可重试，已成功文件会查重）") {
                        ForEach(Array(backup.failures.enumerated()), id: \.offset) { _, failure in Text(failure).font(.footnote) }
                    }
                }
            }
            .navigationTitle("照片备份")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { backup.cancel(); dismiss() } } }
            .confirmationDialog("上传所选相簿到当前账户？", isPresented: $confirmsStart, titleVisibility: .visible) {
                Button("开始上传") { backup.start(using: controller) }
            } message: { Text("将原始照片、视频和 Live Photo 上传到当前 Immich 服务器。重复文件会查重；手机照片保持完整。") }
            .onChange(of: controller.generation) { _, _ in backup.cancel(); dismiss() }
            .onChange(of: scenePhase) {
                _, phase in if phase == .background {
                    backup.cancel()
                }
            }
            .onDisappear { backup.cancel() }
        }
        .interactiveDismissDisabled(backup.running)
    }
}
