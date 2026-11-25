import Foundation
import Testing
@testable import Remmich

/// 双原图公开资源政策与格式3持久边界；不访问Photos、文件字节或真实服务器。
@Suite("RAW JPEG backup policy and persistence")
struct PhotoBackupRawJPEGPolicyTests {
    /// photo/alternate与RAW/JPEG没有固定对应；两种角色及输入顺序交换都得到同一完整组合。
    @Test(arguments: [false, true])
    func classifiesBothOriginalsWithoutArrayOrder(_ rawIsPhoto: Bool) throws {
        let raw = original(kind: rawIsPhoto ? .photo : .alternatePhoto, uti: "com.adobe.raw-image", filename: "synthetic.dng")
        let jpeg = original(kind: rawIsPhoto ? .alternatePhoto : .photo, uti: "public.jpeg", filename: "synthetic.jpg")
        let forward = try PhotoBackupRawJPEGSource(originals: [raw, jpeg], hasAdjustments: false, adjustmentTime: nil)
        let reverse = try PhotoBackupRawJPEGSource(originals: [jpeg, raw], hasAdjustments: false, adjustmentTime: nil)
        #expect(forward == reverse && forward.raw == raw && forward.jpeg == jpeg)
        try forward.validate()
    }

    /// 资源缺失、额外资源、同种双图、未知UTI及调整都不能降级成只备份一张；日期调整即使flag为false仍拒绝。
    @Test(arguments: 0 ..< 7)
    func rejectsAmbiguousOrAdjustedOriginals(_ scenario: Int) {
        let raw = original(kind: .photo, uti: "com.adobe.raw-image", filename: "synthetic.dng")
        let jpeg = original(kind: .alternatePhoto, uti: "public.jpeg", filename: "synthetic.jpg")
        var values = [raw, jpeg]
        switch scenario {
        case 0: values = [raw]
        case 1: values.append(jpeg)
        case 2: values = [raw, original(kind: .alternatePhoto, uti: "com.adobe.raw-image", filename: "other.dng")]
        case 3: values = [raw, original(kind: .alternatePhoto, uti: "public.data", filename: "unknown.jpg")]
        case 4: values = [raw, original(kind: .unsupported, uti: "public.jpeg", filename: "adjusted.jpg")]
        default: break
        }
        #expect(throws: PhotoBackupStateError.self) {
            try PhotoBackupRawJPEGSource(originals: values, hasAdjustments: scenario == 5,
                                         adjustmentTime: scenario == 6 ? Date(timeIntervalSince1970: 1) : nil)
        }
    }

    /// 真实扫描一次升级到v3并原子保存两份角色；新连接读取后不能用旧格式整表覆盖，清空相簿规则不降级。
    @Test func preservesFormatThreeAcrossColdReadAndLaterScans() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RawJPEGPolicy-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try MediaAccountScope(session: .init(apiURL: #require(URL(string: "https://raw-jpeg.invalid/api")), accessToken: "synthetic", userID: "synthetic",
                                                         userEmail: "synthetic@example.invalid", name: "Synthetic", isAdmin: false,
                                                         serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil)))
        let database = root.appending(path: "index.sqlite")
        let store = SQLiteLibraryIndexStore(databaseURL: database)
        try await store.prepare(scope: scope)
        let pair = try PhotoBackupRawJPEGSource(originals: [original(kind: .alternatePhoto, uti: "public.jpeg", filename: "synthetic.jpg"),
                                                            original(kind: .photo, uti: "com.adobe.raw-image", filename: "synthetic.dng")], hasAdjustments: false, adjustmentTime: nil)
        let source = PhotoBackupSource(localID: "synthetic-pair", modifiedAt: Date(timeIntervalSince1970: 100), kind: .rawJPEG, rawJPEG: pair)
        let selection = try PhotoBackupAlbumSelection(included: ["all"], excluded: [])
        let scan = try selection.scan([.init(id: "all", assets: [.init(source: source, capturedAt: nil)])])
        var journal = PhotoBackupJournal(namespace: scope.cacheNamespace)
        try journal.applyAlbumScan(scan, allowCloud: false)
        try await store.savePhotoBackups(journal, scope: scope)
        let cold = SQLiteLibraryIndexStore(databaseURL: database)
        var restored = try await cold.loadPhotoBackups(scope: scope)
        #expect(restored.version == 3 && restored.header.rawJPEGVersion == 1 && restored.excludedAlbumIDs == [])
        #expect(restored.jobs.first?.source == source)
        await #expect(throws: PhotoBackupStateError.self) {
            try await cold.savePhotoBackups(.init(namespace: scope.cacheNamespace), scope: scope)
        }
        let empty = try selection.scan([.init(id: "all", assets: [])])
        try restored.applyAlbumScan(empty, allowCloud: false)
        #expect(restored.version == 3 && restored.jobs.first?.stage == .cancelled)
        try await cold.savePhotoBackups(restored, scope: scope)
        let reread = try await store.loadPhotoBackups(scope: scope)
        #expect(reread.version == 3 && reread.jobs.first?.source.rawJPEG == pair)
    }

    /// 旧v1/v2头部继续有效；v3必须声明双图格式，未来版本/未知子格式不能假装成功读取。
    @Test func validatesOldAndNewHeaderContracts() throws {
        try PhotoBackupJournal.Header(version: 1, namespace: "synthetic", selectedAlbumIDs: [], allowCloud: false).validate(namespace: "synthetic")
        try PhotoBackupJournal.Header(version: 2, namespace: "synthetic", selectedAlbumIDs: ["all"], allowCloud: false, excludedAlbumIDs: []).validate(namespace: "synthetic")
        for version in [3, 4] {
            #expect(throws: PhotoBackupStateError.self) {
                try PhotoBackupJournal.Header(version: version, namespace: "synthetic", selectedAlbumIDs: ["all"], allowCloud: false,
                                              excludedAlbumIDs: [], rawJPEGVersion: version == 4 ? 1 : nil).validate(namespace: "synthetic")
            }
        }
    }

    /// 参数构成纯合成公开资源描述；像素固定正值，filename不指向实际文件。
    private func original(kind: PhotoBackupOriginalImage.Kind, uti: String, filename: String) -> PhotoBackupOriginalImage {
        .init(kind: kind, uniformTypeIdentifier: uti, originalFilename: filename, pixelWidth: 3, pixelHeight: 2)
    }
}
