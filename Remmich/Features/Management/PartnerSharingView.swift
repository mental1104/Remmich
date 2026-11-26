import SwiftUI

/// 账户伙伴共享的独立设置页；清楚区分两个方向，incoming只允许本人时间线偏好，绝不替别人撤销授权。
struct PartnerSharingView: View {
    let controller: LibraryManagementController
    let libraryIndex: LibraryIndexController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = PartnerSharingStore()
    @State private var candidateID = ""
    @State private var pending: PartnerSharingPlan?

    private var ready: Bool {
        store.hasFreshData && !store.isLoading && !store.isWorking && !controller.busy
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if let snapshot = store.snapshot {
                    incomingSection(snapshot)
                    outgoingSection(snapshot)
                    addSection(snapshot)
                    timelineStatus(snapshot)
                }
            }
            .navigationTitle("伙伴共享")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(store.isWorking) } }
            .task(id: controller.generation) {
                await store.reload(manager: controller)?.value
                await libraryIndex.refreshPartnerTimelinePolicyStatus()
            }
            .onChange(of: controller.generation) { _, _ in retire(); dismiss() }
            .onChange(of: scenePhase) {
                _, phase in if phase != .active {
                    retire()
                }
            }
            .onDisappear { retire() }
            .confirmationDialog("确认伙伴共享变更？", isPresented: Binding(get: { pending != nil }, set: {
                if !$0 {
                    pending = nil
                }
            }), titleVisibility: .visible) {
                if let plan = pending {
                    Button("确认此操作", role: isRemoval(plan) ? .destructive : nil) { pending = nil; candidateID = ""; store.start(plan, manager: controller) }
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: {
                if let plan = pending {
                    Text(confirmationMessage(plan))
                }
            }
        }.interactiveDismissDisabled(store.isWorking)
    }

    /// 操作状态只展示安全说明；重读不会自动POST/PUT/DELETE，未知结果不靠重发纠正。
    private var statusSection: some View {
        Section {
            Text("伙伴共享按方向独立。把照片分享给对方，不代表对方也分享给你；不会发送邮件或邀请消息。")
                .font(.footnote).foregroundStyle(.secondary)
            if let error = store.error {
                Text(L10n.string(error)).foregroundStyle(.red)
            }
            if let notice = store.notice {
                Text(notice).foregroundStyle(.secondary)
            }
            if store.isLoading {
                ProgressView("读取伙伴关系")
            }
            if store.isWorking {
                ProgressView("更改并核对伙伴关系")
                Button("停止等待") { retire(); store.showError() }
            }
            Button("重新读取伙伴关系") { pending = nil; candidateID = ""; store.reload(manager: controller) }
                .disabled(store.isLoading || store.isWorking || controller.client == nil)
        }
    }

    /// incoming的授权由对方发起，本人只能明确控制是否混入自己的服务端时间线；缺少状态保持未知只读。
    private func incomingSection(_ snapshot: PartnerSharingSnapshot) -> some View {
        Section("分享给我") {
            if snapshot.incoming.isEmpty {
                Text("目前没有账户向你开放伙伴图库。")
            }
            ForEach(snapshot.incoming) { partner in
                VStack(alignment: .leading, spacing: 8) {
                    Text(partner.name).font(.headline)
                    if let enabled = partner.inTimeline {
                        Text(enabled ? "服务端：在我的时间线显示" : "服务端：仅在伙伴图库浏览").font(.caption).foregroundStyle(.secondary)
                        Button(enabled ? "从我的时间线隐藏" : "在我的时间线显示") { prepare(.timeline(partner.id, !enabled)) }.disabled(!ready)
                    } else {
                        Text("服务器未提供时间线状态，暂不可修改。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// outgoing只有本人能撤销；对方的时间线偏好不是本人的开关，不提供误导性双向删除或选项。
    private func outgoingSection(_ snapshot: PartnerSharingSnapshot) -> some View {
        Section("我分享给谁") {
            if snapshot.outgoing.isEmpty {
                Text("你尚未向其他账户开放伙伴图库。")
            }
            ForEach(snapshot.outgoing) { partner in
                LabeledContent(partner.name) { Button("停止向对方共享", role: .destructive) { prepare(.remove(partner.id)) }.disabled(!ready) }
            }
        }
    }

    /// 候选只来自当前GET/users，按官方Web/mobile排除本人和已有outgoing，incoming不阻止独立向对方共享。
    private func addSection(_ snapshot: PartnerSharingSnapshot) -> some View {
        Section("分享给已有账户") {
            Picker("选择账户", selection: $candidateID) {
                Text("选择账户").tag("")
                ForEach(store.users.filter { user in
                    user.id.lowercased() != controller.client?.userID.lowercased()
                        && !snapshot.outgoing.contains(where: { $0.id.lowercased() == user.id.lowercased() })
                }) { user in Text(user.name).tag(user.id) }
            }
            Button("向此账户共享我的图库") { prepare(.add(candidateID)) }.disabled(!ready || candidateID.isEmpty)
        }.disabled(!ready)
    }

    /// 服务端fresh选项和本机accepted作用域是两份证据；仅匹配持久代际凭据后显示本机已核对，重试只读元数据。
    private func timelineStatus(_ snapshot: PartnerSharingSnapshot) -> some View {
        Section("照片时间线核对") {
            let expected = controller.backupScope.flatMap { try? PartnerTimelinePolicy(scope: $0, incoming: snapshot.incoming) }
            if let expected, expected.isKnown, libraryIndex.acceptedPartnerTimelinePolicy == expected {
                Text("本机照片列表已核对此伙伴设置。")
            } else {
                Text("服务端关系已读取，本机照片列表尚未确认应用当前伙伴设置。")
                    .font(.footnote).foregroundStyle(.secondary)
                if libraryIndex.status == .indexing {
                    ProgressView("重新读取照片列表")
                }
                if case .failed = libraryIndex.status {
                    Text("照片列表核对失败，可只重试读取，不会再次修改伙伴共享。").font(.footnote).foregroundStyle(.red)
                }
                Button("只刷新照片列表") { libraryIndex.retryPartnerTimelineRead() }.disabled(!ready || libraryIndex.status == .indexing)
            }
        }
    }

    /// 一次用户动作生成一个确认；被禁止的方向/候选根本不会发送写入。
    private func prepare(_ command: PartnerSharingCommand) {
        do { pending = try store.prepare(command, manager: controller) }
        catch { pending = nil; store.showError() }
    }

    /// 页面生命周期退休，不将停止等待等同服务端回滚。
    private func retire() {
        pending = nil; candidateID = ""; store.invalidate(manager: controller)
    }

    /// 只有停止本人共享使用破坏性样式，照片及原片均保留。
    private func isRemoval(_ plan: PartnerSharingPlan) -> Bool {
        if case .remove = plan.command {
            true
        } else {
            false
        }
    }

    /// 明确目标账户及单向效果；不显示邮箱/UUID，不把时间线隐藏描述为撤销对方的授权。
    private func confirmationMessage(_ plan: PartnerSharingPlan) -> String {
        switch plan.command {
        case .add: "向 \(plan.name) 开放你可共享的照片图库。对方不会因此自动向你共享；不会发送邀请消息。"
        case .remove: "停止向 \(plan.name) 共享你的图库。对方向你的共享关系保留，照片和原片不删除。"
        case let .timeline(_, enabled): "\(enabled ? "显示" : "隐藏") \(plan.name) 的照片在你的服务端时间线中。对方授权仍保留；本机照片列表还需重新核对。"
        }
    }
}
