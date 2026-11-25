import CryptoKit
import Foundation
import Photos
import Testing
@testable import Remmich

/// 运行真正的ImageIO/AVFoundation/PhotoKit合成实验；nil/编码错误均失败，不伪造或跳过native正例。
@Suite("Synthetic genuine Live Photo")
@MainActor struct SyntheticLivePhotoFixtureTests {
    /// 独立文件回读及真实非degraded重建后才得到lease；核同UUID/时间/像素/真实输入摘要，并显式回收本例目录。
    @Test(.timeLimit(.minutes(2)))
    func publicFileRequestBuildsGenuineNativePhoto() async throws {
        let fixture = try await SyntheticLivePhotoFixture.make()
        // make失败会保留自己的文件与阶段；成功返回后，本测试持有lease直至所有native/字节断言完成。
        defer { try? fixture.close() }
        let directory = fixture.directory
        #expect(fixture.stillURL.isFileURL && fixture.motionURL.isFileURL)
        #expect(fixture.stillURL.deletingLastPathComponent() == directory && fixture.motionURL.deletingLastPathComponent() == directory)
        #expect(UUID(uuidString: fixture.identifier) != nil)
        #expect(fixture.receipt.jpegIdentifier == fixture.identifier && fixture.receipt.movieIdentifier == fixture.identifier)
        #expect(fixture.receipt.contentIdentifier == fixture.identifier)
        #expect(fixture.receipt.markerValue == -1 && abs(fixture.receipt.markerTime - 1.5) < 0.001)
        #expect(abs(fixture.receipt.movieDuration - 3) < 0.01 && fixture.receipt.videoFrameDecoded)
        #expect(fixture.pixels == MediaPixelSize(width: 320, height: 240))
        #expect(fixture.receipt.pixelWidth == 320 && fixture.receipt.pixelHeight == 240)
        #expect(fixture.native.size.width == 320 && fixture.native.size.height == 240)

        // 只核真正重建对象的公开资源类型，不假设未入库对象支持ResourceManager字节取回。
        let resources = PHAssetResource.assetResources(for: fixture.native)
        #expect(resources.count == 2)
        #expect(resources.filter { $0.type == .photo || $0.type == .fullSizePhoto }.count == 1)
        #expect(resources.filter { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }.count == 1)
        #expect(resources.map(\.type.rawValue).sorted() == fixture.receipt.resourceTypes)

        // 用测试侧独立回读文件重新计算两种摘要；工厂内存值不能单独证明字节存在或Native request未改变输入。
        let still = try Data(contentsOf: fixture.stillURL)
        let motion = try Data(contentsOf: fixture.motionURL)
        #expect(!still.isEmpty && !motion.isEmpty && still != motion)
        #expect(fixture.stillDigest.byteCount == Int64(still.count) && fixture.motionDigest.byteCount == Int64(motion.count))
        #expect(fixture.receipt.stillByteCount == Int64(still.count) && fixture.receipt.motionByteCount == Int64(motion.count))
        let stillSHA1 = Insecure.SHA1.hash(data: still)
        let motionSHA1 = Insecure.SHA1.hash(data: motion)
        #expect(Data(stillSHA1).base64EncodedString() == fixture.stillDigest.sha1Base64)
        #expect(Data(motionSHA1).base64EncodedString() == fixture.motionDigest.sha1Base64)
        #expect(stillSHA1.map { String(format: "%02x", $0) }.joined() == fixture.stillDigest.sha1Hex)
        #expect(motionSHA1.map { String(format: "%02x", $0) }.joined() == fixture.motionDigest.sha1Hex)
        #expect(fixture.receipt.stillSHA1Hex == fixture.stillDigest.sha1Hex && fixture.receipt.motionSHA1Hex == fixture.motionDigest.sha1Hex)
        #expect(SHA256.hash(data: still).map { String(format: "%02x", $0) }.joined() == fixture.receipt.stillSHA256)
        #expect(SHA256.hash(data: motion).map { String(format: "%02x", $0) }.joined() == fixture.receipt.motionSHA256)
        let receiptBytes = try Data(contentsOf: directory.appendingPathComponent("receipt.json"))
        let recorded = try JSONDecoder().decode(LocalLivePhotoFixtureReceipt.self, from: receiptBytes)
        #expect(recorded.contentIdentifier == fixture.identifier && recorded.resourceTypes == fixture.receipt.resourceTypes)

        // 仅合成UUID和摘要的收据可进CI日志；没有用户媒体、图库标识、凭据或外部URL。
        print("NativeLivePhotoFixture success receipt=\(String(decoding: receiptBytes, as: UTF8.self))")
        try fixture.close()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try fixture.close()
    }
}
