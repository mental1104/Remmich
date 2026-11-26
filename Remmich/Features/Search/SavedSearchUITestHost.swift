#if DEBUG
    import Foundation
    import Observation
    import SwiftUI

    /// 三个显式测试参数才可到达的真实SearchView；没有按钮直接调用Store或fixture的CRUD。
    struct SavedSearchUITestHost: View {
        @State private var fixture = SavedSearchUIFixture()

        var body: some View {
            NavigationStack {
                VStack(spacing: 4) {
                    Text(fixture.evidence.ready ? "ready" : "preparing")
                        .accessibilityIdentifier("saved-search-test-ready")
                    SearchView(source: fixture.repository, media: fixture.media,
                               assetDetails: fixture.details, showAccount: {}, presetManager: fixture.manager)
                    evidence
                }
                .navigationTitle("Search")
            }
            .task { await fixture.prepare() }
            .onDisappear { fixture.stop() }
        }

        /// AX完整发布实际HTTP字节供测试独立解码；一行显示避免合成证据挤走真实操作控件。
        private var evidence: some View {
            VStack(spacing: 1) {
                Text(fixture.evidence.http.counts).accessibilityIdentifier("saved-search-test-request-counts")
                Text(fixture.evidence.http.presetBody).accessibilityIdentifier("saved-search-test-last-preset-body")
                Text(fixture.evidence.http.searchBody).accessibilityIdentifier("saved-search-test-last-search-body")
                Text(fixture.evidence.http.violation).accessibilityIdentifier("saved-search-test-violations")
            }
            .font(.caption2).lineLimit(1)
        }
    }

    /// 主线程仅观察实际HTTP回执；不持有或改写SearchView查询、Store列表或草稿。
    @MainActor @Observable
    final class SavedSearchUIEvidence {
        var ready = false
        var http = SavedSearchUIHTTPObservation()
    }

    /// 为真实管理客户端和真实搜索Repository配置同一隔离响应源；普通网络、持久账号和照片均不参与。
    @MainActor
    final class SavedSearchUIFixture {
        let repository = ImmichTimelineRepository()
        let manager: LibraryManagementController
        let evidence: SavedSearchUIEvidence
        let media: MediaLibraryController
        let details: SearchUIFixtureDetails
        private let account: AccountSession
        private let readSession: URLSession
        private let host: String
        private var stopped = false

        /// 每次启动使用独占.invalid地址；只复用既有无网络媒体容器，不复用正常账号或测试搜索读取器。
        init() {
            let mediaContainer = SearchUIFixtureHarness()
            media = mediaContainer.media; details = mediaContainer.details
            let evidence = SavedSearchUIEvidence()
            self.evidence = evidence
            host = "saved-search-ui-\(UUID().uuidString.lowercased()).example.invalid"
            let endpoint = URL(string: "https://\(host)/api")!
            account = AccountSession(apiURL: endpoint, accessToken: "synthetic-presets",
                                     userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", userEmail: "synthetic@example.invalid",
                                     name: "Synthetic", isAdmin: false,
                                     serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
            let backend = SavedSearchUIHTTPBackend(host: host) { [weak evidence] observation in
                evidence?.http = observation
            }
            SavedSearchUIHTTPProtocol.install(backend, host: host)
            manager = LibraryManagementController(configurationFactory: Self.configuration)
            manager.configure(session: account, endpoint: endpoint)
            media.management.configure(session: account, endpoint: nil)
            readSession = URLSession(configuration: Self.configuration(), delegate: LibraryMutationClient.NoRedirect(), delegateQueue: nil)
        }

        /// 返回仅含本地URLProtocol的独立会话配置；所有host均被拦截，不允许意外请求回落网络。
        private static func configuration() -> URLSessionConfiguration {
            let value = URLSessionConfiguration.ephemeral
            value.protocolClasses = [SavedSearchUIHTTPProtocol.self]
            value.httpShouldSetCookies = false; value.urlCache = nil
            value.requestCachePolicy = .reloadIgnoringLocalCacheData
            value.timeoutIntervalForRequest = 10
            return value
        }

        /// 等真实repo/SDK装配完成才开放测试屏障；不预设查询、保存项或客户端成功状态。
        func prepare() async {
            guard !stopped else { return }
            await repository.configureSearchUITest(session: account, networkSession: readSession)
            guard !Task.isCancelled, !stopped else { return }
            evidence.ready = true
        }

        /// 页面退休同步停止两种会话并移除专属协议来源；不触碰共享会话、默认导出或后台队列。
        func stop() {
            guard !stopped else { return }
            stopped = true; evidence.ready = false
            manager.configure(session: nil, endpoint: nil)
            media.management.configure(session: nil, endpoint: nil)
            readSession.invalidateAndCancel()
            SavedSearchUIHTTPProtocol.remove(host: host)
        }
    }
#endif
