#if DEBUG
    import Foundation
    import Observation
    import SwiftUI

    /// 仅DEBUG且两个明确参数同时存在才启用；正常/发布版搜索不能读取这些合成资产。
    enum SearchUIFixtureLaunch {
        static var isEnabled: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            return arguments.contains("-ui-testing-search") && arguments.contains("-ui-testing-signed-in")
        }
    }

    /// 使用真实SearchView/状态机的独立无网络宿主，账号按钮只切换合成身份。
    struct SearchUITestHost: View {
        @State private var fixture = SearchUIFixtureHarness()

        var body: some View {
            NavigationStack {
                VStack(spacing: 4) {
                    Text("Synthetic account \(fixture.account)")
                        .accessibilityIdentifier("search-test-account")
                    Text(fixture.requestState)
                        .font(.caption)
                        .accessibilityIdentifier("search-test-request")
                    Text(fixture.retiredState)
                        .font(.caption)
                        .accessibilityIdentifier("search-test-retired")
                    SearchView(source: nil, media: fixture.media, assetDetails: fixture.details,
                               showAccount: { fixture.switchAccount() }, searchReader: fixture.reader,
                               searchCompletion: { fixture.searchFinished($0) })
                }
                .navigationTitle("Search")
            }
        }
    }

    /// 主线程维护合成账号和请求观察状态；generation切换沿用真实management机制。
    @MainActor @Observable
    final class SearchUIFixtureHarness {
        let media: MediaLibraryController
        let details = SearchUIFixtureDetails()
        private var retiredReader: SearchUIFixtureReader?
        private(set) var reader: SearchUIFixtureReader?
        private(set) var account = "alpha"
        private(set) var requestState = "idle"
        private(set) var retiredState = "none"

        /// 只配置management身份；媒体保持无scope/端点，避免正常configure恢复导出或启动后台队列。
        init() {
            // 导出控制器的默认依赖会读取正常传输日志，因此显式注入永不启动的临时空队列。
            let root = FileManager.default.temporaryDirectory.appending(path: "search-ui-\(UUID().uuidString)")
            let transfers = LibraryTransferQueue(rootURL: root.appending(path: "transfers"), nativeTasksProvider: { [] },
                                                 sessionIdentifier: "io.github.espeonblue.Remmich.search-ui-unused")
            let exports = MediaExportController(store: .init(databaseURL: root.appending(path: "unused.sqlite")), transfers: transfers)
            media = MediaLibraryController(exports: exports)
            configure(account: "alpha")
        }

        /// 改变真实管理代际与读取器，旧账号任务仍可能返回，用于验证发布隔离。
        func switchAccount() {
            configure(account: account == "alpha" ? "beta" : "alpha")
        }

        /// query为已完成store发布检查的条件；仅旧late请求结束后开放最终断言屏障。
        func searchFinished(_ query: NativeSearchQuery) {
            if query.text == "late", retiredState == "returned" {
                retiredState = "completed"
            }
        }

        /// next为纯合成身份；本地像素仍沿用现有UI预览路径，不恢复或保存账号凭据。
        private func configure(account next: String) {
            retiredReader = reader
            account = next
            requestState = "idle"
            retiredState = "none"
            let session = AccountSession(apiURL: URL(string: "https://example.invalid/api")!, accessToken: "synthetic",
                                         userID: "search-ui-\(next)", userEmail: "\(next)@example.invalid", name: next,
                                         isAdmin: false, serverVersion: .init(major: 3, minor: 4, patch: 2, prerelease: nil))
            media.management.configure(session: session, endpoint: nil)
            reader = SearchUIFixtureReader(account: next) { [weak self] account, state in
                guard let self else { return }
                if account == self.account {
                    requestState = state
                    if state.hasPrefix("started "), let old = retiredReader {
                        retiredReader = nil
                        // 新账号请求真正开始后才释放旧响应，避免依赖手势速度或固定等待。
                        Task { await old.finishLateRequest() }
                    }
                } else if state == "completed late" {
                    retiredState = "returned"
                }
            }
        }
    }

    /// 合成读取器可控地产生结果/空态/分页失败和迟到响应，不执行HTTP或媒体写入。
    actor SearchUIFixtureReader: NativeSearchReading {
        private let account: String
        private let report: @MainActor @Sendable (String, String) -> Void
        private var failedContinuation = false
        private var pendingLateRequest: CheckedContinuation<Void, Never>?

        /// account为合成命名空间；report只把请求阶段交回主线程观察，不控制业务状态机。
        init(account: String, report: @escaping @MainActor @Sendable (String, String) -> Void) {
            self.account = account
            self.report = report
        }

        /// query选择合成场景，continuation必须沿用首屏令牌；返回原生资产页或可安全展示错误。
        func search(_ query: NativeSearchQuery, continuation: NativeSearchContinuation?) async throws -> NativeSearchPage {
            let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "late" {
                // 故意忽略任务取消；仅新账号请求进入后释放，确定性覆盖迟到响应。
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    pendingLateRequest = continuation
                    // 先安装gate再发布started，测试观察到started即可确定旧读取确实在途。
                    Task { await report(account, "started late") }
                }
                await report(account, "completed late")
                return .init(assets: [Self.asset(account: account, index: 9)], continuation: nil)
            }
            await report(account, "started \(text)")
            if text == "empty" {
                return .init(assets: [], continuation: nil)
            }
            if text == "error" {
                throw NativeSearchError.unavailable
            }
            if text == "retry" {
                if continuation == nil {
                    return .init(assets: [Self.asset(account: account, index: 1)], continuation: .cursor("synthetic-next"))
                }
                guard continuation == .cursor("synthetic-next") else { throw NativeSearchError.invalidResponse }
                if !failedContinuation {
                    failedContinuation = true
                    throw NativeSearchError.unavailable
                }
                return .init(assets: [Self.asset(account: account, index: 1), Self.asset(account: account, index: 2)], continuation: nil)
            }
            let assets = [Self.asset(account: account, index: 1), Self.asset(account: account, index: 2)]
                .filter { !query.favoritesOnly || $0.isFavorite }
            return .init(assets: assets, continuation: nil)
        }

        /// 由新账号的请求阶段触发；恢复一次旧等待，不发布业务结果或访问网络。
        func finishLateRequest() {
            pendingLateRequest?.resume()
            pendingLateRequest = nil
        }

        /// account/index确定稳定合成身份；返回可供现有缩略图和查看器读取的无私人内容资产。
        private nonisolated static func asset(account: String, index: Int) -> TimelineAssetSummary {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            return .init(id: "search-\(account)-\(index)", ownerID: "search-ui-\(account)", capturedAt: date,
                         uploadedAt: date, localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil,
                         aspectRatio: index.isMultiple(of: 2) ? 2 : 0.5, isFavorite: index == 1, visibility: .timeline,
                         livePhotoVideoID: nil, stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: date)
        }
    }

    /// 查看器详情只有合成文件名/尺寸；不提供GPS，避免地图或地名服务路径。
    actor SearchUIFixtureDetails: AssetDetailReading {
        /// id为合成资产ID；返回纯内存详情，无外部读取或真实EXIF。
        func assetDetail(id: String) async throws -> AssetDetail {
            .init(id: id, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                  originalFileName: "\(id).jpg", originalMimeType: "image/jpeg", width: 600, height: 400,
                  description: "Synthetic search acceptance image", cameraMake: nil, cameraModel: nil,
                  lensModel: nil, fileSizeBytes: 1024, iso: nil, focalLength: nil, aperture: nil,
                  exposureTime: nil, latitude: nil, longitude: nil, city: nil, state: nil, country: nil)
        }
    }
#endif
