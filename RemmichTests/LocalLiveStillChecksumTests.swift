import Foundation
import Photos
import Testing
@testable import Remmich

/// 严格Live still政策和真实reader→分块SHA1；仅Photos来源替换为合成值，不伪造motion/远端配对或备份成功。
@Suite("Live Photo still checksums")
@MainActor struct LocalLiveStillChecksumTests {
    /// reverse打乱两个完整描述的顺序；选择必须按photo角色，不拿第一个资源或pairedVideo当still。
    @Test(arguments: [false, true])
    func policySelectsOnlyUnadjustedPhoto(_ reverse: Bool) throws {
        let asset = liveStillAsset(reverse: reverse)
        let selection = try asset.selection().get()
        let motion = try #require(asset.resources.first { $0.descriptor.role == .pairedVideo })
        #expect(selection.descriptor.role == .originalPhoto && selection.format == .image)
        #expect(selection != motion)
        let digest = try LocalPhotoByteDigest(sha1Hex: "c4502db68c24556654ccd8993abc2d2e578ad286", byteCount: 37)
        let proof = try LocalPhotoChecksumProof(asset: asset, resource: selection, digest: digest)
        #expect(proof.source.identity.mediaKind == .livePhoto && proof.source.resources.count == 2)
        #expect(proof.resource.descriptor.role == .originalPhoto && proof.digest == digest)
    }

    /// 单独拿pairedVideo的摘要不能用通用proof构造器冒充still；动态部分始终需要专用motion证明。
    @Test func proofRejectsMotionAsStill() throws {
        let asset = liveStillAsset()
        let motion = try #require(asset.resources.first { $0.descriptor.role == .pairedVideo })
        let digest = try LocalPhotoByteDigest(sha1Hex: "58be777b9bf5f3971870cc8725c828fcfc089cf2", byteCount: 34)
        #expect(throws: LocalPhotoChecksumError.invalidInput) { try LocalPhotoChecksumProof(asset: asset, resource: motion, digest: digest) }
    }

    /// 唯一原始photo经过真实reader和真实SHA1流；Cloud ID缺失也能构造still候选，但不读取motion或服务媒体。
    @Test(arguments: [false, true])
    func realReaderHashesPhotoOnlyWithNetworkDisabled(_ reverse: Bool) async throws {
        let source = liveStillAsset(reverse: reverse)
        let script = LiveStillChecksumScript(sources: [source, source])
        let reader = script.reader()
        let expected = source.snapshot.withCloudIdentity(.resolved("synthetic-cloud-not-required"))
        let result = try await reader.checksum(for: expected, validateContext: script.validate)
        guard case let .verified(proof) = result else { Issue.record("Expected a Live Photo still proof"); return }
        #expect(proof.source == source.snapshot && proof.source.identity.mediaKind == .livePhoto)
        #expect(proof.resource.descriptor.role == .originalPhoto && proof.source.resources.contains { $0.role == .pairedVideo })
        #expect(proof.digest.sha1Hex == "c4502db68c24556654ccd8993abc2d2e578ad286" && proof.digest.byteCount == 37)
        #expect(proof.digest.sha1Base64 == "xFAttowkVWZUzNiZOrwtLleK0oY=")
        #expect(script.reads == 2 && script.byteResources == [proof.resource] && script.networkOptions == [false])
    }

    /// mode覆盖不完整/重复/额外/RAW/调整/未知资源；拒绝必须发生在任何字节读取之前，不退回另一成员。
    @Test(arguments: ["photo-only", "motion-only", "duplicate-photo", "duplicate-motion", "extra", "photo-format", "motion-format", "raw", "alternate",
                      "adjusted", "adjustment-data", "edited", "timestamp", "unknown-version", "descriptor-mismatch"])
    func unsafeLiveShapesNeverReadBytes(_ mode: String) async throws {
        let source = liveStillAsset(mode)
        let script = LiveStillChecksumScript(sources: [source])
        let result = try await script.reader().checksum(for: source.snapshot, validateContext: script.validate)
        if case .verified = result {
            Issue.record("Unsafe Live Photo shape must not produce a proof")
        }
        #expect(script.byteResources.isEmpty && script.networkOptions.isEmpty && script.reads == 1)
        if mode == "photo-only" || mode == "motion-only" {
            #expect(result == .insufficient(.unsupportedMedia))
        }
    }

    /// 只哈希photo也必须比较完整paired描述；版本/调整/权限/账号在读取后变化都不能发布旧still证明。
    @Test(arguments: ["paired-resource", "photo-resource", "edited", "timestamp", "version", "permission", "context"])
    func changedSourceOrAuthorityRejectsRead(_ mode: String) async throws {
        let before = liveStillAsset()
        let after = ["permission", "context"].contains(mode) ? before : liveStillAsset(mode)
        let script = LiveStillChecksumScript(sources: [before, after])
        script.afterRead = {
            if mode == "permission" {
                script.permission = .limited
            }
            if mode == "context" {
                script.active = false
            }
        }
        do {
            _ = try await script.reader().checksum(for: before.snapshot, validateContext: script.validate)
            Issue.record("Changed Live Photo source or authority must reject proof")
        } catch {
            #expect(error as? LocalPhotoChecksumError == (mode == "permission" ? .permission : .sourceChanged))
        }
        #expect(script.byteResources.count == 1 && script.byteResources.first?.descriptor.role == .originalPhoto)
        #expect(script.networkOptions == [false])
    }

    /// 本机只有部分块而最终需要网络，真实流失败后没有部分proof，也不再读取motion/iCloud或重试。
    @Test func cloudOnlyStillReturnsInsufficientWithoutMotionRead() async throws {
        let source = liveStillAsset()
        let script = LiveStillChecksumScript(sources: [source]); script.cloudOnly = true
        let result = try await script.reader().checksum(for: source.snapshot, validateContext: script.validate)
        #expect(result == .insufficient(.notLocallyAvailable))
        #expect(script.byteResources.count == 1 && script.byteResources.first?.descriptor.role == .originalPhoto)
        #expect(script.networkOptions == [false] && script.reads == 1)
    }
}

/// mode生成独立完整公开观察，reverse只改变成对一致的排列；真实Photos/字段/文件均不被访问。
private nonisolated func liveStillAsset(_ mode: String = "valid", reverse: Bool = false) -> LocalPhotoChecksumAsset {
    let photo = LocalPhotoChecksumResource(descriptor: .init(type: PHAssetResourceType.photo.rawValue,
                                                             role: mode == "alternate" ? .alternatePhoto : mode == "adjusted" ? .adjusted : .originalPhoto,
                                                             originalFilename: mode == "photo-resource" ? "changed.heic" : "synthetic.heic",
                                                             uniformTypeIdentifier: "public.heic", pixelWidth: 64, pixelHeight: 48),
                                           format: mode == "raw" ? .raw : mode == "photo-format" ? .unsupported : .image)
    let motion = LocalPhotoChecksumResource(descriptor: .init(type: PHAssetResourceType.pairedVideo.rawValue, role: .pairedVideo,
                                                              originalFilename: mode == "paired-resource" ? "changed.mov" : "synthetic.mov",
                                                              uniformTypeIdentifier: "com.apple.quicktime-movie", pixelWidth: 64, pixelHeight: 48),
                                            format: mode == "motion-format" ? .unsupported : .video)
    var resources = reverse ? [motion, photo] : [photo, motion]
    switch mode {
    case "photo-only": resources = [photo]
    case "motion-only": resources = [motion]
    case "duplicate-photo": resources = [photo, photo]
    case "duplicate-motion": resources = [motion, motion]
    case "extra", "adjustment-data":
        resources.append(.init(descriptor: .init(type: PHAssetResourceType.adjustmentData.rawValue, role: mode == "extra" ? .other : .adjustmentData,
                                                 originalFilename: "synthetic-extra", uniformTypeIdentifier: "public.data", pixelWidth: 0, pixelHeight: 0), format: .unsupported))
    default: break
    }
    let snapshot = LocalPhotoSnapshot(identity: .init(localIdentifier: "synthetic-live-still", modificationDate: mode == "unknown-version" ? nil : Date(timeIntervalSince1970: mode == "version" ? 16 : 15), mediaKind: .livePhoto),
                                      creationDate: Date(timeIntervalSince1970: 10), adjustmentTime: mode == "timestamp" ? Date(timeIntervalSince1970: 14) : nil,
                                      hasAdjustments: mode == "edited", latitude: nil, longitude: nil, pixelWidth: 64, pixelHeight: 48, duration: 0,
                                      mediaSubtypes: PHAssetMediaSubtype.photoLive.rawValue, resources: mode == "descriptor-mismatch" ? [] : resources.map(\.descriptor), cloudIdentity: .unavailable)
    return .init(snapshot: snapshot, resources: resources)
}

/// 合成Photos系统边界；保留实际source/所选资源/网络选项，摘要/完整流/权限与版本检查仍走产品实现。
@MainActor private final class LiveStillChecksumScript {
    private var sources: [LocalPhotoChecksumAsset]
    var permission = PHAuthorizationStatus.authorized
    var active = true
    var cloudOnly = false
    var afterRead: (@MainActor () -> Void)?
    private(set) var reads = 0
    private(set) var byteResources: [LocalPhotoChecksumResource] = []
    private(set) var networkOptions: [Bool] = []

    /// sources是调用前后独立观察，消耗完毕就失败，不能复用旧来源掩盖多余读取。
    init(sources: [LocalPhotoChecksumAsset]) {
        self.sources = sources
    }

    /// 返回真实reader，三个可替换点全部显式注入，测试绝不落到真实Photos授权或资源API。
    func reader() -> PhotoKitCurrentResourceChecksumReader {
        .init(source: source, bytes: bytes, authorization: { self.permission })
    }

    /// identifier必须对应合成照片；返回下一次公开观察，权限与policy由真实reader决定。
    private func source(_ identifier: String) throws -> LocalPhotoChecksumAsset? {
        reads += 1
        guard identifier == "synthetic-live-still", !sources.isEmpty else { throw LocalPhotoChecksumError.sourceChanged }
        return sources.removeFirst()
    }

    /// identity/resource是产品实际选择；只有photo字节被分块送进真实CryptoKit SHA1，不模拟服务端匹配或paired媒体。
    private func bytes(_ identity: LocalPhotoIdentity, _ resource: LocalPhotoChecksumResource) async throws -> LocalPhotoByteDigest {
        defer { afterRead = nil }
        byteResources.append(resource)
        #expect(identity.mediaKind == .livePhoto && resource.descriptor.role == .originalPhoto)
        let value = try await LocalPhotoResourceSHA1Stream().read(start: { network, receive, complete in
            self.networkOptions.append(network)
            let photo = Data("synthetic local Photos current bytes\n".utf8)
            receive(Data(photo.prefix(9)))
            if self.cloudOnly {
                complete(LocalPhotoChecksumError.networkRequired)
            } else {
                receive(Data(photo.dropFirst(9))); complete(nil)
            }
            return 71
        }, cancel: { _ in })
        afterRead?()
        return value
    }

    /// active模拟调用方账号/页面代际；错误必须抛出，不能降级成未匹配或继续媒体读取。
    func validate() throws {
        if !active {
            throw LocalPhotoChecksumError.sourceChanged
        }
    }
}
