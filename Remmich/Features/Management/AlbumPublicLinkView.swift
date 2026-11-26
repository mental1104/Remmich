import SwiftUI
import UIKit

/// 相簿公开链接的独立管理页；现有Library浏览卡继续只读，链接地址仅在明确复制时进入系统剪贴板。
struct AlbumPublicLinkView: View {
    let controller: LibraryManagementController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AlbumPublicLinkStore()
    @State private var editor: PublicLinkEditorSelection?
    @State private var pending: AlbumPublicLinkPlan?
    @State private var showsConfirmation = false
    @State private var copied = false

    private var ready: Bool {
        store.hasFreshData && !store.isLoading && !store.isWorking && !controller.busy
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if !store.albums.isEmpty {
                    albumSection
                }
                if let album = store.album {
                    linksSection(album)
                    if album.canManage(controller.client?.userID ?? "") {
                        Section { Button("创建公开链接") { editor = .init(link: nil) }.disabled(!ready) }
                    } else {
                        Section { Text("创建需相簿所有者或编辑者权限。你自己已创建的链接仍可修改或撤销。")
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else if store.hasFreshData, store.albums.isEmpty {
                    Section { Text("当前没有可见相簿。") }
                }
            }
            .navigationTitle("相簿公开链接")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(store.isWorking) } }
            .task(id: controller.generation) { await store.reload(manager: controller)?.value }
            .onChange(of: controller.generation) { _, _ in retire(); dismiss() }
            .onChange(of: scenePhase) {
                _, phase in if phase != .active {
                    retire()
                }
            }
            .onDisappear { retire() }
            .sheet(item: $editor, onDismiss: { showsConfirmation = pending != nil }) { selection in
                AlbumPublicLinkEditor(link: selection.link) { options in
                    prepare(selection.link.map { .update($0, options) } ?? .create(options))
                    editor = nil
                }
            }
            .confirmationDialog("确认公开链接变更？", isPresented: $showsConfirmation, titleVisibility: .visible) {
                if let plan = pending {
                    Button(isRevocation(plan) ? "撤销此链接" : "确认公开链接设置", role: isRevocation(plan) ? .destructive : nil) {
                        pending = nil; copied = false; store.start(plan, manager: controller)
                    }
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: {
                if let plan = pending {
                    Text(confirmationMessage(plan))
                }
            }
        }.interactiveDismissDisabled(store.isWorking)
    }

    /// 状态不展示原始HTTP响应或密钥；后台/停止等待后的未知结果必须由用户重新读取核对。
    private var statusSection: some View {
        Section {
            Text("仅显示你创建的相簿链接。持有链接的人可按设置访问；撤销不删除照片或相簿。")
                .font(.footnote).foregroundStyle(.secondary)
            if let error = store.error {
                Text(L10n.string(error)).foregroundStyle(.red)
            }
            if let notice = store.notice {
                Text(notice).foregroundStyle(.secondary)
            }
            if copied {
                Text("链接已复制，地址使用当前服务器连接。密码需单独告知对方。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.isLoading {
                ProgressView("读取公开链接")
            }
            if store.isWorking {
                ProgressView("保存并核对公开链接")
                Button("停止等待") { retire(); store.showError() }
            }
            Button("重新读取公开链接") { pending = nil; copied = false; store.reload(manager: controller) }
                .disabled(store.isLoading || store.isWorking || controller.client == nil)
        }
    }

    /// 选择相簿只启动fresh读取，旧确认和复制状态随选择失效，不自动创建公开链接。
    private var albumSection: some View {
        Section("相簿") {
            Picker("选择相簿", selection: Binding(get: { store.selectedID }, set: { id in
                pending = nil; copied = false; store.reload(albumID: id, manager: controller)
            })) { ForEach(store.albums) { album in Text(album.albumName).tag(Optional(album.id)) } }
                .disabled(store.isLoading || store.isWorking)
        }
    }

    /// album是已fresh读取的当前相簿；每个链接以创建日期/描述区分，密码只显示保护状态。
    private func linksSection(_ album: AlbumSharingSnapshot) -> some View {
        Section("我创建的链接") {
            if store.links.isEmpty {
                Text("此相簿没有你创建的公开链接。")
            }
            ForEach(store.links) { link in
                VStack(alignment: .leading, spacing: 8) {
                    if let description = link.options.description, !description.isEmpty {
                        Text(description).font(.headline)
                    } else {
                        Text(album.albumName).font(.headline)
                    }
                    Text("创建于 \(link.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    Text(link.options.password?.isEmpty == false ? "密码保护" : "无密码").font(.caption)
                    if let expires = link.options.expiresAt {
                        Text("\(expires <= .now ? "已过期" : "有效至") \(expires.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    } else {
                        Text("无到期时间").font(.caption)
                    }
                    HStack {
                        Button("复制链接") {
                            if let url = store.copyURL(for: link, manager: controller) {
                                UIPasteboard.general.url = url; copied = true
                            } else {
                                store.showError()
                            }
                        }
                        Button("修改设置") { editor = .init(link: link) }
                        Button("撤销", role: .destructive) { prepare(.revoke(link)); showsConfirmation = pending != nil }
                    }.buttonStyle(.borderless).disabled(!ready)
                }.padding(.vertical, 4)
            }
        }
    }

    /// command来自用户选择，固定相簿和完整选项后才显示确认；失败不发送请求且不显示敏感参数。
    private func prepare(_ command: AlbumPublicLinkCommand) {
        do { pending = try store.prepare(command, manager: controller) }
        catch { pending = nil; store.showError() }
    }

    /// 清除所有页面确认/表单及Store敏感快照；不会撤销已由服务端完成的未知操作。
    private func retire() {
        pending = nil; editor = nil; showsConfirmation = false; copied = false; store.invalidate(manager: controller)
    }

    /// 只有撤销使用破坏性确认样式，相簿/媒体不在删除范围。
    private func isRevocation(_ plan: AlbumPublicLinkPlan) -> Bool {
        if case .revoke = plan.command {
            true
        } else {
            false
        }
    }

    /// 确认列出访问权限和到期/保护状态，永不回显服务端密码、密钥或自定义地址。
    private func confirmationMessage(_ plan: AlbumPublicLinkPlan) -> String {
        let options: AlbumPublicLinkOptions
        let action: String
        switch plan.command {
        case let .create(value): options = value; action = "创建一个公开链接"
        case let .update(_, value): options = value; action = "修改此公开链接"
        case .revoke: return "相簿：\(plan.album.albumName)。撤销此链接后，持有者不能再通过它访问；照片和相簿保留。"
        }
        let expiration = options.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "无到期时间"
        return "相簿：\(plan.album.albumName)。\(action)。上传：\(options.allowUpload ? "允许" : "禁止")；下载：\(options.allowDownload ? "允许" : "禁止")；元数据：\(options.showMetadata ? "显示" : "隐藏")；密码：\(options.password == nil ? "无" : "保护")；\(expiration)。"
    }
}

/// 创建/修改表单的局部身份，不将密钥或链接UUID作为SwiftUI视图ID。
private struct PublicLinkEditorSelection: Identifiable { let id = UUID(); let link: AlbumPublicLink? }

/// 密码操作必须明确区分保留、新值、清除；旧密码从不预填可见表单。
private enum PublicLinkPasswordAction: String, CaseIterable { case keep, replace, remove }

/// 一份明确选项草稿；保存只生成上层确认，尚不发送写请求，取消不改变服务端。
private struct AlbumPublicLinkEditor: View {
    let link: AlbumPublicLink?
    let submit: (AlbumPublicLinkOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var description: String
    @State private var slug: String
    @State private var expiration: Date
    @State private var expires: Bool
    @State private var allowUpload: Bool
    @State private var allowDownload: Bool
    @State private var showMetadata: Bool
    @State private var passwordAction = PublicLinkPasswordAction.keep
    @State private var password = ""

    /// link为空代表新建；submit将完整草稿交回确认层。读取现有密码只用于保留操作，不初始化SecureField。
    init(link: AlbumPublicLink?, submit: @escaping (AlbumPublicLinkOptions) -> Void) {
        self.link = link; self.submit = submit
        _description = State(initialValue: link?.options.description ?? ""); _slug = State(initialValue: link?.options.slug ?? "")
        _expiration = State(initialValue: link?.options.expiresAt ?? .now.addingTimeInterval(86400)); _expires = State(initialValue: link?.options.expiresAt != nil)
        _allowUpload = State(initialValue: link?.options.allowUpload ?? false); _allowDownload = State(initialValue: link?.options.allowDownload ?? true)
        _showMetadata = State(initialValue: link?.options.showMetadata ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("链接设置") {
                    TextField("描述（可留空）", text: $description)
                    TextField("自定义地址（留空清除）", text: $slug).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("修改或清除自定义地址可能使旧地址失效。链接仅在确认创建后生成。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("设置到期时间", isOn: $expires)
                    if expires {
                        DatePicker("到期时间", selection: $expiration)
                    }
                }
                permissionSection
                passwordSection
            }
            .navigationTitle(link == nil ? "新建公开链接" : "修改公开链接")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("核对并确认") { submit(options()) }
                    .disabled(passwordAction == .replace && password.isEmpty)
                }
            }
            .onChange(of: showMetadata) {
                _, enabled in if !enabled {
                    allowDownload = false
                }
            }
            .onDisappear { password = "" }
        }
    }

    /// 新建或用户主动隐藏元数据时保留禁下载联动；既有合法组合原样显示，并允许明确关闭已有下载。
    /// 上传权限独立可见，默认新建不允许上传；编辑其他字段不隐式收窄现有权限。
    private var permissionSection: some View {
        Section("公开访问权限") {
            Toggle("显示照片元数据", isOn: $showMetadata)
            Toggle("允许下载", isOn: $allowDownload).disabled(!showMetadata && !allowDownload)
            Toggle("允许上传到此相簿", isOn: $allowUpload)
        }
    }

    /// 新旧表单均支持明确设置/移除，修改时“保留”只在内存带回原值，永不展示原密码。
    private var passwordSection: some View {
        Section("密码") {
            Picker("密码操作", selection: $passwordAction) {
                Text(link == nil ? "不设置密码" : "保留现状").tag(PublicLinkPasswordAction.keep)
                Text("设置新密码").tag(PublicLinkPasswordAction.replace)
                Text("清除密码").tag(PublicLinkPasswordAction.remove)
            }
            if passwordAction == .replace {
                SecureField("新密码", text: $password).textContentType(.newPassword)
            }
            Text("原密码不会显示。新密码需单独发送给接收者；复制链接不会复制密码。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// 将当前完整草稿交给纯规范化/确认层；空字符串转null，保留/清除密码不靠省略字段表达。
    private func options() -> AlbumPublicLinkOptions {
        let value = switch passwordAction { case .keep: link?.options.password; case .replace: password; case .remove: nil as String? }
        return .init(description: description.isEmpty ? nil : description, password: value, slug: slug.isEmpty ? nil : slug,
                     expiresAt: expires ? expiration : nil, allowUpload: allowUpload, allowDownload: allowDownload, showMetadata: showMetadata)
    }
}
