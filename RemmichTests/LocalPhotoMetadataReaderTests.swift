import Foundation
import Testing
@testable import Remmich

/// 真实reader的有限批次/观察版本/账号取消边界；只替换系统元数据来源，不调用PhotoKit媒体读取或网络。
@Suite("Local photo metadata reader boundaries")
@MainActor struct LocalPhotoMetadataReaderTests {
    /// 系统返回顺序不重要，最终按请求顺序附加各自完整Cloud ID；两次元数据读取之间才允许等待映射。
    @Test func readsOnlyMetadataAndPreservesRequestIdentityOrder() async throws {
        let first = localMediaSnapshot(localIdentifier: "one")
        let second = localMediaSnapshot(localIdentifier: "two")
        let assets = LocalPhotoAssetScript(pages: [[first, second], [second, first]])
        let cloud = LocalPhotoCloudScript(values: ["one": .resolved("synthetic:cloud:first"), "two": .resolved("synthetic:cloud:second")])
        let reader = PhotoKitLocalPhotoMetadataReader(assets: { try assets.read($0) }, cloudIDs: { try await cloud.read($0) })
        let result = try await reader.snapshots(for: ["two", "one"], validateContext: {})
        #expect(result.map(\.identity.localIdentifier) == ["two", "one"])
        #expect(result.map(\.cloudIdentity) == [.resolved("synthetic:cloud:second"), .resolved("synthetic:cloud:first")])
        #expect(assets.requests == [["two", "one"], ["two", "one"]])
        #expect(await cloud.requests == [["two", "one"]])
    }

    /// 64项边界仍只调用一次系统映射，且每项保持独立身份。
    @Test func acceptsFullBoundedBatch() async throws {
        let snapshots = (0 ..< 64).map { localMediaSnapshot(localIdentifier: "synthetic-\($0)") }
        let ids = snapshots.map(\.identity.localIdentifier)
        let assets = LocalPhotoAssetScript(pages: [snapshots, snapshots])
        let values = Dictionary(uniqueKeysWithValues: ids.map { ($0, LocalPhotoCloudIdentity.resolved("synthetic:cloud:\($0)")) })
        let cloud = LocalPhotoCloudScript(values: values)
        let reader = PhotoKitLocalPhotoMetadataReader(assets: { try assets.read($0) }, cloudIDs: { try await cloud.read($0) })
        let result = try await reader.snapshots(for: ids, validateContext: {})
        #expect(result.map(\.identity.localIdentifier) == ids)
        #expect(assets.requests == [ids, ids])
        #expect(await cloud.requests == [ids])
    }

    /// 初始空请求/当前不可见集合不发Cloud ID请求，也不通过伪造快照来制造本地可读性。
    @Test func emptyAndInaccessibleSourcesDoNotLookupCloudIDs() async throws {
        let assets = LocalPhotoAssetScript(pages: [[]])
        let cloud = LocalPhotoCloudScript(values: [:])
        let reader = PhotoKitLocalPhotoMetadataReader(assets: { try assets.read($0) }, cloudIDs: { try await cloud.read($0) })
        #expect(try await reader.snapshots(for: [], validateContext: {}).isEmpty)
        #expect(assets.requests.isEmpty)
        #expect(try await reader.snapshots(for: ["unavailable"], validateContext: {}).isEmpty)
        #expect(await cloud.requests.isEmpty)
    }

    /// 源集合上限64且ID必须非空/不重复；非法批次在任何系统读取前拒绝，不做隐式无限枚举。
    @Test(arguments: ["oversized", "duplicate", "empty-id"])
    func rejectsInvalidBatchesBeforeSystemReads(_ mode: String) async {
        let assets = LocalPhotoAssetScript(pages: [[]])
        let cloud = LocalPhotoCloudScript(values: [:])
        let ids = mode == "oversized" ? (0 ..< 65).map { "synthetic-\($0)" } : mode == "duplicate" ? ["same", "same"] : [""]
        let reader = PhotoKitLocalPhotoMetadataReader(assets: { try assets.read($0) }, cloudIDs: { try await cloud.read($0) })
        await #expect(throws: LocalMediaMetadataError.invalidBatch) { try await reader.snapshots(for: ids, validateContext: {}) }
        #expect(assets.requests.isEmpty)
        #expect(await cloud.requests.isEmpty)
    }

    /// 读取权限失败、重复/额外身份都不能被当作“找到了另一张照片”；不进入Cloud映射。
    @Test(arguments: ["permission", "duplicate", "foreign"])
    func rejectsInvalidAssetResults(_ mode: String) async {
        let snapshot = localMediaSnapshot()
        let pages = mode == "foreign" ? [[localMediaSnapshot(localIdentifier: "foreign")]] : [[snapshot, snapshot]]
        let assets = LocalPhotoAssetScript(pages: pages, failure: mode == "permission" ? .permission : nil)
        let cloud = LocalPhotoCloudScript(values: [:])
        let reader = PhotoKitLocalPhotoMetadataReader(assets: { try assets.read($0) }, cloudIDs: { try await cloud.read($0) })
        await #expect(throws: mode == "permission" ? LocalMediaMetadataError.permission : .invalidBatch) {
            try await reader.snapshots(for: [snapshot.identity.localIdentifier], validateContext: {})
        }
        #expect(await cloud.requests.isEmpty)
    }

    /// 映射缺失/失败/不完整均保留未知；已知尾冒号不完整值不能作为成功关联ID。
    @Test(arguments: ["missing", "failed", "incomplete", "invalid"])
    func doesNotPromoteUnknownCloudMappings(_ mode: String) async throws {
        let snapshot = localMediaSnapshot()
        let id = snapshot.identity.localIdentifier
        let resolution: LocalPhotoCloudIdentity = switch mode {
        case "failed": .failed
        case "invalid": .resolved("synthetic:cloud:")
        default: .incomplete
        }
        let assets = LocalPhotoAssetScript(pages: [[snapshot], [snapshot]])
        let cloud = LocalPhotoCloudScript(values: mode == "missing" ? [:] : [id: resolution])
        let reader = PhotoKitLocalPhotoMetadataReader(assets: { try assets.read($0) }, cloudIDs: { try await cloud.read($0) })
        let values = try await reader.snapshots(for: [id], validateContext: {})
        let value = try #require(values.first)
        let expected: LocalPhotoCloudIdentity = switch mode {
        case "missing": .unavailable
        case "failed": .failed
        default: .incomplete
        }
        #expect(value.cloudIdentity == expected)
        #expect(try LocalMediaMatch.resolve(expected: snapshot.identity, snapshot: value, candidates: []) == .insufficientMetadata)
    }

    /// 映射期间修改/编辑/删除或资源形态变更均拒绝旧观察；不能只看Cloud ID相同就发布本地关联。
    @Test(arguments: ["modification", "adjustment", "removed", "resource"])
    func rejectsSourceChangesAcrossCloudLookup(_ mode: String) async {
        let initial = localMediaSnapshot()
        let after: [LocalPhotoSnapshot] = switch mode {
        case "modification": [localMediaSnapshot(modificationDate: Date(timeIntervalSince1970: 16))]
        case "adjustment": [localMediaSnapshot(adjustmentTime: Date(timeIntervalSince1970: 20), hasAdjustments: true)]
        case "removed": []
        default: [localMediaSnapshot(resources: [.init(type: 1, role: .originalPhoto, originalFilename: "changed.heic", uniformTypeIdentifier: "public.heic", pixelWidth: 64, pixelHeight: 48)])]
        }
        let assets = LocalPhotoAssetScript(pages: [[initial], after])
        let cloud = LocalPhotoCloudScript(values: [initial.identity.localIdentifier: .resolved("synthetic:cloud:content")])
        let reader = PhotoKitLocalPhotoMetadataReader(assets: { try assets.read($0) }, cloudIDs: { try await cloud.read($0) })
        await #expect(throws: LocalMediaMetadataError.sourceChanged) {
            try await reader.snapshots(for: [initial.identity.localIdentifier], validateContext: {})
        }
        #expect(assets.requests.count == 2)
    }

    /// 取消和账户代际撤销在真实await挂起期间发生；迟到映射不再读取下一份Photos快照或发布任何关联。
    @Test(arguments: [false, true])
    func rejectsCancelledOrRevokedLateMapping(_ cancel: Bool) async throws {
        let snapshot = localMediaSnapshot()
        let assets = LocalPhotoAssetScript(pages: [[snapshot], [snapshot]])
        let cloud = LocalPhotoCloudScript(values: [snapshot.identity.localIdentifier: .resolved("synthetic:cloud:content")], held: true)
        let context = LocalPhotoReadContext()
        let reader = PhotoKitLocalPhotoMetadataReader(assets: { try assets.read($0) }, cloudIDs: { try await cloud.read($0) })
        let operation = Task { try await reader.snapshots(for: [snapshot.identity.localIdentifier], validateContext: context.validate) }
        do {
            try await waitForMapping(cloud)
            if cancel {
                operation.cancel()
            } else {
                context.active = false
            }
            await cloud.release()
            if cancel {
                await #expect(throws: CancellationError.self) { try await operation.value }
            } else {
                await #expect(throws: LocalMediaMetadataError.sourceChanged) { try await operation.value }
            }
            #expect(assets.requests.count == 1)
        } catch {
            operation.cancel()
            await cloud.release()
            _ = await operation.result
            throw error
        }
    }

    /// cloud返回的ID也必须属于请求；禁止元数据响应偷偷带入另一个本地资源。
    @Test func rejectsForeignCloudMappingIdentity() async {
        let snapshot = localMediaSnapshot()
        let assets = LocalPhotoAssetScript(pages: [[snapshot], [snapshot]])
        let cloud = LocalPhotoCloudScript(values: ["foreign": .resolved("synthetic:cloud:content")])
        let reader = PhotoKitLocalPhotoMetadataReader(assets: { try assets.read($0) }, cloudIDs: { try await cloud.read($0) })
        await #expect(throws: LocalMediaMetadataError.invalidBatch) {
            try await reader.snapshots(for: [snapshot.identity.localIdentifier], validateContext: {})
        }
        #expect(assets.requests.count == 1)
    }

    /// script的公开状态表明真实reader已经进入await；有界轮询仅防测试挂死，不靠固定延迟猜测时序。
    private func waitForMapping(_ script: LocalPhotoCloudScript) async throws {
        for _ in 0 ..< 150 {
            if await script.isHeld {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await script.isHeld, "Local metadata lookup did not enter its held await")
    }
}

/// 合成系统元数据按实际调用顺序消费；只记录请求身份，不替换reader的版本/取消/代际检查。
@MainActor private final class LocalPhotoAssetScript {
    private var pages: [[LocalPhotoSnapshot]]
    private let failure: LocalMediaMetadataError?
    private(set) var requests: [[String]] = []

    /// pages是有限Photos快照，failure可在系统读取点明确失败。
    init(pages: [[LocalPhotoSnapshot]], failure: LocalMediaMetadataError? = nil) {
        self.pages = pages; self.failure = failure
    }

    /// ids为实际传给本机来源的标识；没有脚本或明确失败时抛错，不伪造空列表。
    func read(_ ids: [String]) throws -> [LocalPhotoSnapshot] {
        requests.append(ids)
        if let failure {
            throw failure
        }
        guard !pages.isEmpty else { throw LocalMediaMetadataError.invalidBatch }
        return pages.removeFirst()
    }
}

/// 有限Cloud ID响应与可控await；只返回Sendable字段，不含Photos对象、媒体字节或真实iCloud账号。
private actor LocalPhotoCloudScript {
    private let values: [String: LocalPhotoCloudIdentity]
    private let held: Bool
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var requests: [[String]] = []
    var isHeld: Bool {
        pending != nil
    }

    /// values为当前请求的合成映射，held控制回执延迟以验证取消和上下文撤销。
    init(values: [String: LocalPhotoCloudIdentity], held: Bool = false) {
        self.values = values; self.held = held
    }

    /// ids来自真实reader；挂起后测试可撤销owner，再释放原结果以核对迟到值被丢弃。
    func read(_ ids: [String]) async throws -> [String: LocalPhotoCloudIdentity] {
        requests.append(ids)
        if held {
            await withCheckedContinuation { pending = $0 }
        }
        return values
    }

    /// 释放同步系统API不能真正取消的旧映射；reader自身负责Task/代际守卫，不让fixture代替它拒绝旧值。
    func release() {
        pending?.resume(); pending = nil
    }
}

/// 仅模拟调用方已有的账号/页面发布代际；不引入第二套账号生命周期。
@MainActor private final class LocalPhotoReadContext {
    var active = true

    /// 撤销后抛错让真实reader中止，不能用旧请求发布新页面的关联。
    func validate() throws {
        guard active else { throw LocalMediaMetadataError.sourceChanged }
    }
}
