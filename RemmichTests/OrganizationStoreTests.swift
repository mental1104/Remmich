import Foundation
import Testing
@testable import Remmich

/// 原生组织入口按实际业务定义筛选相簿，并严格区分空列表、缺扩展和错误。
@Suite("Organization browsing state")
struct OrganizationStoreTests {
    /// 只有本人+trim后精确分组匹配；共享、无owner、相似名称和重复ID均不能改变待整理含义。
    @Test func pendingAlbumsMatchTheOwningWebRule() {
        let owned = organizationAlbum("owned", owner: "me")
        let foreign = organizationAlbum("foreign", owner: "other")
        let unknown = organizationAlbum("unknown", owner: nil)
        let similar = organizationAlbum("similar", owner: "me")
        let ungrouped = organizationAlbum("ungrouped", owner: "me")
        let directory = ForkAlbumDirectory(state: .init(categories: [], groups: []), albums: [
            .init(id: owned.id, customGroupName: " \n待整理 \n"),
            .init(id: foreign.id, customGroupName: "待整理"),
            .init(id: unknown.id, customGroupName: "待整理"),
            .init(id: similar.id, customGroupName: "待整理-2026"),
            .init(id: ungrouped.id, customGroupName: nil),
        ])
        let result = PendingAlbumSelection.select([owned, foreign, unknown, similar, ungrouped, owned], directory: directory, ownerID: "me")
        #expect(result.map(\.id) == ["owned"])
        let query = PendingAlbumSelection.timelineQuery(for: owned)
        #expect(query.albumID == owned.id && query.visibility == nil)
        #expect(query.includesStacks && !query.includesPartners && !query.includesTrashed)
    }

    /// 刷新替换而非累积随机批次，去重保留服务器次序；失败保留上一批并明确展示错误。
    @Test @MainActor func randomRefreshReplacesBatchAndKeepsItOnFailure() async {
        let source = OrganizationSequenceSource(random: [
            .success([organizationAsset("a"), organizationAsset("a"), organizationAsset("b")]),
            .success([organizationAsset("c")]), .failure(.forbidden),
        ])
        let store = RandomPhotosStore()
        await store.refresh(source: source)
        #expect(store.assets.map(\.id) == ["a", "b"])
        await store.refresh(source: source)
        #expect(store.assets.map(\.id) == ["c"])
        await store.refresh(source: source)
        #expect(store.assets.map(\.id) == ["c"])
        #expect(store.error == NativeSearchError.forbidden.errorDescription)
        #expect(store.hasLoaded && !store.isLoading)
    }

    /// nil/空列表/403是三种不同结果，不能把不支持或拒绝访问包装成没有待整理相簿。
    @Test @MainActor func distinguishesPendingCapabilityEmptyAndFailure() async {
        let source = OrganizationSequenceSource(pending: [.success(nil), .success([]), .failure(.forbidden)])
        let store = PendingAlbumsStore()
        await store.load(source: source, ownerID: "me")
        #expect(store.supported == false && store.hasLoaded && store.error == nil)
        store.invalidate()
        await store.load(source: source, ownerID: "me")
        #expect(store.supported == true && store.albums.isEmpty && store.error == nil)
        store.invalidate()
        await store.load(source: source, ownerID: "me")
        #expect(store.supported == nil && !store.hasLoaded)
        #expect(store.error == NativeSearchError.forbidden.errorDescription)
        #expect(await source.owners == ["me", "me", "me"])
    }

    /// kind分别覆盖随机和待整理：旧读取已经在途，新账号结果先成功，旧有效结果最后返回不能覆盖。
    @Test(arguments: ["random", "pending"])
    @MainActor func rejectsLateOrganizationResultsAfterInvalidation(_ kind: String) async {
        let source = HeldOrganizationSource()
        let random = RandomPhotosStore()
        let pending = PendingAlbumsStore()
        let old = Task {
            if kind == "random" {
                await random.refresh(source: source)
            } else {
                await pending.load(source: source, ownerID: "old")
            }
        }
        await source.waitForRequest()
        random.invalidate()
        pending.invalidate()
        if kind == "random" {
            await random.refresh(source: source)
        } else {
            await pending.load(source: source, ownerID: "new")
        }
        await source.release()
        await old.value
        if kind == "random" {
            #expect(random.assets.map(\.id) == ["new"])
            #expect(random.error == nil && random.hasLoaded && !random.isLoading)
        } else {
            #expect(pending.albums.map(\.id) == ["new"])
            #expect(pending.error == nil && pending.hasLoaded && !pending.isLoading)
        }
    }

    /// 取消后旧成功不能发布，也不能显示普通网络失败；无固定sleep或真实请求。
    @Test @MainActor func cancelledRandomReadDoesNotPublish() async {
        let source = HeldOrganizationSource()
        let store = RandomPhotosStore()
        let pending = Task { await store.refresh(source: source) }
        await source.waitForRequest()
        pending.cancel()
        await source.release()
        await pending.value
        #expect(store.assets.isEmpty && store.error == nil && !store.hasLoaded && !store.isLoading)
    }
}

/// id/owner是合成相簿身份；不携带照片或真实目录信息。
private nonisolated func organizationAlbum(_ id: String, owner: String?) -> AlbumSummary {
    .init(id: id, name: id, description: "", thumbnailAssetID: nil, assetCount: 1,
          updatedAt: Date(timeIntervalSince1970: 1), createdAt: Date(timeIntervalSince1970: 0),
          startDate: nil, endDate: nil, isShared: false, ownerName: owner, ownerID: owner)
}

/// id是合成结果身份，返回原生状态机需要的最小完整媒体资料。
private nonisolated func organizationAsset(_ id: String) -> TimelineAssetSummary {
    let date = Date(timeIntervalSince1970: 0)
    return .init(id: id, ownerID: "synthetic", capturedAt: date, uploadedAt: date, localOffsetHours: 0,
                 mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1, isFavorite: false,
                 visibility: .timeline, livePhotoVideoID: nil, stack: nil, projectionType: nil,
                 thumbhash: nil, thumbnailRevision: date)
}

/// 固定业务响应序列，不替状态机做任何筛选或错误处理。
private actor OrganizationSequenceSource: OrganizationReading {
    private var random: [Result<[TimelineAssetSummary], NativeSearchError>]
    private var pending: [Result<[AlbumSummary]?, NativeSearchError>]
    private(set) var owners: [String] = []

    /// random/pending分别是顺序响应；未配置的调用明确失败，不能偷偷返回成功空列表。
    init(random: [Result<[TimelineAssetSummary], NativeSearchError>] = [], pending: [Result<[AlbumSummary]?, NativeSearchError>] = []) {
        self.random = random
        self.pending = pending
    }

    /// 返回下一个真实业务输入，调用完毕后额外请求失败。
    func randomPhotos() async throws -> [TimelineAssetSummary] {
        guard !random.isEmpty else { throw NativeSearchError.invalidResponse }
        return try random.removeFirst().get()
    }

    /// ownerID记录调用方当前身份，不从相簿内容猜测账号。
    func pendingAlbums(ownerID: String) async throws -> [AlbumSummary]? {
        owners.append(ownerID)
        guard !pending.isEmpty else { throw NativeSearchError.invalidResponse }
        return try pending.removeFirst().get()
    }
}

/// 第一请求安装gate后暂停，第二请求直接返回新身份结果，旧请求始终在最后释放。
private actor HeldOrganizationSource: OrganizationReading {
    private var requests = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    /// 返回旧或新批次；gate不检查取消，由被测状态机执行发布权检查。
    func randomPhotos() async throws -> [TimelineAssetSummary] {
        await [organizationAsset(identity())]
    }

    /// ownerID来自被测Store，响应身份由明确的请求顺序决定，不访问任何账号存储。
    func pendingAlbums(ownerID _: String) async throws -> [AlbumSummary]? {
        await [organizationAlbum(identity(), owner: "synthetic")]
    }

    /// 首次调用暂停后返回old，后续返回new；只安装一次gate，避免覆盖等待者。
    private func identity() async -> String {
        requests += 1
        guard requests == 1 else { return "new" }
        await withCheckedContinuation { continuation in gate = continuation; waiter?.resume(); waiter = nil }
        return "old"
    }

    /// 等待首个请求真正进入fixture，排除尚未发送请求的伪竞态。
    func waitForRequest() async {
        guard gate == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    /// 显式释放旧响应，随后测试必须等待旧Task结束再检查新状态。
    func release() {
        gate?.resume(); gate = nil
    }
}
