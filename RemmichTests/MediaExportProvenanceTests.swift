import Foundation
import Testing
@testable import Remmich

/// 请求模式的冷恢复与兼容性；只读写隔离SQLite/JSON，不验证Photos渲染或触发传输。
@Suite("Media export source provenance")
@MainActor
struct MediaExportProvenanceTests {
    /// 历史缺失字段不能变成已编辑；已知三种模式经过真实SQLite JSON持久化后保持不变。
    @Test func coldPersistencePreservesKnownModesAndLegacyUnknown() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "export-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let scope = MediaAccountScope(session: .fixture)
        try await store.prepare(scope: scope)
        let revision = Date(timeIntervalSince1970: 100)
        var legacyJob = makeJob(id: "legacy", revision: revision)
        legacyJob.sourceMode = nil
        let jobs = [legacyJob] + [MediaExportTier.original, .preview, .playback].map { tier in
            var job = makeJob(id: tier.rawValue, revision: revision, tier: tier)
            job.sourceMode = tier.requestSourceMode
            return job
        }
        let receipts = jobs.map {
            MediaPhotosReceipt(key: $0.key, assetID: $0.assetID, revision: revision, tier: $0.tier,
                               photosID: "synthetic-\($0.assetID)", albumID: "synthetic", savedAt: revision, sourceMode: $0.sourceMode)
        }
        try await store.saveMediaExports(.init(jobs: jobs, receipts: receipts), scope: scope)
        let reopened = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let restored = try await reopened.loadMediaExports(scope: scope)
        #expect(restored.jobs.map(\.sourceMode) == [nil, .original, .editedDisplay, .playback])
        #expect(restored.receipts.map(\.sourceMode) == [nil, .original, .editedDisplay, .playback])
        let encodedLegacy = try JSONEncoder().encode(receipts[0])
        let keys = try #require(JSONSerialization.jsonObject(with: encodedLegacy) as? [String: Any])
        #expect(keys["sourceMode"] == nil)
        #expect(try JSONDecoder().decode(MediaPhotosReceipt.self, from: encodedLegacy).sourceMode == nil)
        #expect(try JSONDecoder().decode(MediaExportJob.self, from: JSONEncoder().encode(legacyJob)).sourceMode == nil)
    }

    /// 规格到新任务模式是明确边界；只有展示派生图要求已知edited来源，显式原片/视频保持兼容。
    @Test func onlyDisplayDerivativesRequireEditedProvenance() {
        for tier in [MediaExportTier.thumbnail, .preview, .full] {
            #expect(tier.requestSourceMode == .editedDisplay && tier.requiredDisplaySourceMode == .editedDisplay)
        }
        #expect(MediaExportTier.original.requestSourceMode == .original && MediaExportTier.original.requiredDisplaySourceMode == nil)
        #expect(MediaExportTier.playback.requestSourceMode == .playback && MediaExportTier.playback.requiredDisplaySourceMode == nil)
    }

    /// id/revision为合成资源/版本，tier缺省预览；不会创建任务、Photos资源或真实下载。
    private func makeJob(id: String, revision: Date, tier: MediaExportTier = .preview) -> MediaExportJob {
        .init(id: UUID(), assetID: id, revision: revision, capturedAt: revision, localOffsetHours: 0,
              video: tier == .playback, motionID: nil, tier: tier, metadata: .init(assetID: id, detail: nil))
    }
}
