import SwiftUI

/// 现有账户共享管理；全部入口依据当前有序成员角色，viewer也可进入只读查看/合法退出。
struct AlbumSharingView: View {
    let controller: LibraryManagementController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AlbumSharingStore()
    @State private var userID = ""
    @State private var role = AlbumSharingRole.editor
    @State private var pending: AlbumSharingPlan?

    private var ready: Bool {
        store.hasFreshData && !store.isLoading && !store.isWorking && !controller.busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("选择已有服务器账户共享相簿。成员变更会影响其他客户端；不会删除照片或修改原片。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error = store.error {
                        Text(L10n.string(error)).foregroundStyle(.red)
                    }
                    if let notice = store.notice {
                        Text(notice).foregroundStyle(.secondary)
                    }
                    if store.isLoading {
                        ProgressView("读取共享信息")
                    }
                    if store.isWorking {
                        ProgressView("更改成员并核对")
                        Button("停止等待") { store.invalidate(manager: controller); store.showError("Reload sharing to check the unconfirmed result.") }
                    }
                    Button("重新读取共享信息") { userID = ""; store.reload(manager: controller) }
                        .disabled(store.isLoading || store.isWorking || controller.client == nil)
                }
                if !store.albums.isEmpty {
                    Section("相簿") {
                        Picker("选择相簿", selection: Binding(get: { store.selectedID }, set: { id in
                            pending = nil; userID = ""; store.reload(albumID: id, manager: controller)
                        })) {
                            ForEach(store.albums) { album in Text(album.albumName).tag(Optional(album.id)) }
                        }.disabled(store.isLoading || store.isWorking)
                    }
                }
                if let snapshot = store.snapshot {
                    members(snapshot)
                    if snapshot.canManage(controller.client?.userID ?? "") {
                        addMember(snapshot)
                    }
                } else if store.hasFreshData, store.albums.isEmpty {
                    Section { Text("当前没有可见相簿。") }
                }
            }
            .navigationTitle("共享相簿")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(store.isWorking) } }
            .task(id: controller.generation) { await store.reload(manager: controller)?.value }
            .onChange(of: controller.generation) { _, _ in pending = nil; store.invalidate(manager: controller); dismiss() }
            .onChange(of: scenePhase) {
                _, phase in if phase != .active {
                    pending = nil; store.invalidate(manager: controller)
                }
            }
            .onDisappear { store.invalidate(manager: controller) }
            .confirmationDialog("确认更改相簿成员？", isPresented: Binding(get: { pending != nil }, set: {
                if !$0 {
                    pending = nil
                }
            }), titleVisibility: .visible) {
                if let plan = pending {
                    Button("确认成员变更", role: removal(plan) ? .destructive : nil) { pending = nil; store.start(plan, manager: controller) }
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: {
                if let plan = pending {
                    Text(confirmationMessage(plan))
                }
            }
        }.interactiveDismissDisabled(store.isWorking)
    }

    /// snapshot保留官方成员顺序；首位owner不能改角色，最后owner不可移除；每个按钮重复调用统一纯权限规则。
    private func members(_ snapshot: AlbumSharingSnapshot) -> some View {
        Section("当前成员") {
            ForEach(snapshot.albumUsers) { member in
                LabeledContent {
                    if hasActions(member, in: snapshot) {
                        Menu("管理") {
                            ForEach(AlbumSharingRole.allCases, id: \.self) { value in
                                if member.role != value.rawValue, allowed(.role(id: member.id, role: value), in: snapshot) {
                                    Button(value == .editor ? "设为编辑者" : "设为浏览者") { prepare(.role(id: member.id, role: value)) }
                                }
                            }
                            if allowed(.remove(id: member.id), in: snapshot) {
                                Button(member.id.lowercased() == controller.client?.userID.lowercased() ? "退出相簿" : "移除成员", role: .destructive) { prepare(.remove(id: member.id)) }
                            }
                        }.disabled(!ready || !snapshot.hasKnownRoles)
                    } else {
                        Text("只读").foregroundStyle(.secondary)
                    }
                } label: {
                    VStack(alignment: .leading) { Text(member.user.name); Text(member.role).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    /// 只列出fresh GET/users返回且尚不是成员的账户；不提供手输email/UUID或owner角色。
    private func addMember(_ snapshot: AlbumSharingSnapshot) -> some View {
        Section("添加已有用户") {
            Picker("用户", selection: $userID) {
                Text("选择用户").tag("")
                ForEach(store.users.filter { snapshot.roles[$0.id.lowercased()] == nil }) { user in Text(user.name).tag(user.id) }
            }
            Picker("权限", selection: $role) {
                Text("编辑者").tag(AlbumSharingRole.editor); Text("浏览者").tag(AlbumSharingRole.viewer)
            }
            Button("添加此用户") { prepare(.add(id: userID, role: role)) }.disabled(!ready || userID.isEmpty)
        }.disabled(!ready)
    }

    /// command只读检查当前权限；未知/无权动作根本不出现在菜单，最终仍需fresh预检及服务端授权。
    private func allowed(_ command: AlbumSharingCommand, in snapshot: AlbumSharingSnapshot) -> Bool {
        guard let user = controller.client?.userID else { return false }
        return (try? snapshot.require(command, userID: user, users: store.users)) != nil
    }

    /// 没有合法动作的成员行显示明确只读文字，避免viewer/首owner/未知角色出现可点击空菜单。
    private func hasActions(_ member: AlbumSharingMember, in snapshot: AlbumSharingSnapshot) -> Bool {
        allowed(.remove(id: member.id), in: snapshot) || AlbumSharingRole.allCases.contains {
            member.role != $0.rawValue && allowed(.role(id: member.id, role: $0), in: snapshot)
        }
    }

    /// 用户点击才生成一次固定计划；无效输入仅展示本地安全原因。
    private func prepare(_ command: AlbumSharingCommand) {
        do { pending = try store.prepare(command, manager: controller) }
        catch { store.showError("This member action is unavailable. Reload sharing and check your role.") }
    }

    /// 仅移除/本人退出使用破坏性确认样式，照片和相簿本身均不会被此入口删除。
    private func removal(_ plan: AlbumSharingPlan) -> Bool {
        if case .remove = plan.command {
            true
        } else {
            false
        }
    }

    /// 确认明确固定相簿、成员和目标权限；不展示裸UUID或笼统同意，姓名只在当前账户界面使用。
    private func confirmationMessage(_ plan: AlbumSharingPlan) -> String {
        let action = switch plan.command {
        case let .add(_, role): "添加 \(plan.memberName)，权限设为\(role == .editor ? "编辑者" : "浏览者")"
        case let .role(_, role): "将 \(plan.memberName) 设为\(role == .editor ? "编辑者" : "浏览者")"
        case .remove: "移除成员 \(plan.memberName)"
        }
        return "相簿：\(plan.baseline.albumName)。\(action)。照片和原片保留；结果未核对时必须重新读取。"
    }
}
