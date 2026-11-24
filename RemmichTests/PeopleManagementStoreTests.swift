import Foundation
import Testing
@testable import Remmich

/// 验证写入不明/部分成功、成功后读取失败及旧账户迟到结果，HTTP字节由独立契约测试覆盖。
@Suite("People management state")
@MainActor struct PeopleManagementStoreTests {
    /// 合并失败后不会自动重放，其他写操作也被锁住；显式fresh Reload成功后才可重新确认。
    @Test func partialMergeRequiresExplicitReload() async throws {
        let source = PeopleStoreSource(reads: [[storePerson("first"), storePerson("second")], [storePerson("fresh")]], mergeFails: true)
        let store = PeopleManagementStore()
        await store.reload(source: source)
        let target = try #require(store.people.first)
        let sourcePerson = try #require(store.people.dropFirst().first)
        await store.merge(target: target, sourcePerson: sourcePerson, source: source)
        #expect(store.needsReload && store.error == PeopleManagementError.incompleteMerge.errorDescription)
        await store.rename(storePerson("first"), name: "No replay", source: source)
        #expect(await source.writes == ["merge"])
        #expect(await source.readCount == 1)
        await store.reload(source: source)
        #expect(!store.needsReload && store.people.map(\.name) == ["fresh"])
        #expect(await source.writes == ["merge"])
    }

    /// 真实写入已确认但后续GET失败时保留旧列表并明确区分；Reload只读取，不再次发原写入。
    @Test func acceptedWriteWithFailedRefreshRemainsLocked() async throws {
        let source = PeopleStoreSource(reads: [[storePerson("before")], [storePerson("after")]], failSecondRead: true)
        let store = PeopleManagementStore()
        await store.reload(source: source)
        let expected = try #require(store.people.first)
        await store.rename(expected, name: "after", source: source)
        #expect(store.needsReload && store.people.map(\.name) == ["before"])
        #expect(store.error?.contains("server accepted") == true)
        #expect(await source.writes == ["rename"])
        await store.reload(source: source)
        #expect(!store.needsReload && store.people.map(\.name) == ["after"])
        #expect(await source.writes == ["rename"])
    }

    /// 原始读取挂起后切账号，新账号先成功；旧完整列表最后返回也不能覆盖新人物或解除新状态锁。
    @Test func rejectsLateListFromInvalidatedContext() async {
        let source = PeopleStoreSource(reads: [[storePerson("old")], [storePerson("new")]], holdFirstRead: true)
        let store = PeopleManagementStore()
        let pending = Task { await store.reload(source: source) }
        await source.waitForGate()
        store.invalidate()
        await store.reload(source: source)
        await source.release()
        await pending.value
        #expect(store.people.map(\.name) == ["new"] && !store.needsReload)
    }

    /// 写入成功回执已经等待发布时撤销页面，新账号结果保持；旧回执不再启动后续刷新或显示成功。
    @Test func rejectsLateWriteAndDoesNotStartItsRefresh() async throws {
        let source = PeopleStoreSource(reads: [[storePerson("old")], [storePerson("new")]], holdWrite: true)
        let store = PeopleManagementStore()
        await store.reload(source: source)
        let expected = try #require(store.people.first)
        let pending = Task { await store.setHidden(expected, hidden: true, source: source) }
        await source.waitForGate()
        store.invalidate()
        await store.reload(source: source)
        await source.release()
        await pending.value
        #expect(store.people.map(\.name) == ["new"] && store.notice == nil)
        #expect(await source.readCount == 2)
    }
}

/// name仅为合成状态标识；ID随值生成，不识别真实人物。
private nonisolated func storePerson(_ name: String) -> ManagedPerson {
    .init(id: UUID().uuidString, name: name, isHidden: false)
}

/// 有限状态来源只测Store发布边界；明确gate代替sleep，写成功并不假装服务器媒体验收。
private actor PeopleStoreSource: PeopleManaging {
    private var reads: [[ManagedPerson]]
    private let mergeFails: Bool
    private let failSecondRead: Bool
    private let holdFirstRead: Bool
    private let holdWrite: Bool
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var writes: [String] = []
    private(set) var readCount = 0

    /// reads按调用提供完整列表；开关只控制明确错误或在途阶段，不伪造业务实现。
    init(reads: [[ManagedPerson]], mergeFails: Bool = false, failSecondRead: Bool = false, holdFirstRead: Bool = false, holdWrite: Bool = false) {
        self.reads = reads
        self.mergeFails = mergeFails
        self.failSecondRead = failSecondRead
        self.holdFirstRead = holdFirstRead
        self.holdWrite = holdWrite
    }

    /// 每次真实Store读取消费一个完整批次；第二次故障不消费后续明确Reload应读取的数据。
    func managementPeople() async throws -> [ManagedPerson] {
        readCount += 1
        if failSecondRead, readCount == 2 {
            throw URLError(.notConnectedToInternet)
        }
        guard !reads.isEmpty else { throw URLError(.badServerResponse) }
        let result = reads.removeFirst()
        if holdFirstRead, readCount == 1 {
            await hold()
        }
        return result
    }

    /// 记录显式改名次数，字段/权限/HTTP由真实网络测试独立验证。
    func renamePerson(_: ManagedPerson, name _: String) async throws {
        writes.append("rename")
    }

    /// 隐藏回执可在已接受后挂起，以验证Store不依赖传输取消阻止旧账户发布。
    func setPersonHidden(_: ManagedPerson, hidden _: Bool) async throws {
        writes.append("visibility"); if holdWrite {
            await hold()
        }
    }

    /// 部分合并按明确错误返回，不能偷偷重发。
    func mergePeople(target _: ManagedPerson, source _: ManagedPerson) async throws {
        writes.append("merge"); if mergeFails {
            throw PeopleManagementError.incompleteMerge
        }
    }

    /// 安装在途gate并通知已等待的测试，保证新上下文发生在旧响应之前。
    private func hold() async {
        await withCheckedContinuation { pending = $0; waiter?.resume(); waiter = nil }
    }

    /// 等到旧操作实际进入gate，避免仅凭任务创建推测时序。
    func waitForGate() async {
        if pending == nil {
            await withCheckedContinuation { waiter = $0 }
        }
    }

    /// 在新账号成功后释放旧结果，由Store自身代际守卫拒绝它。
    func release() {
        pending?.resume(); pending = nil
    }
}
