import Nuke
import NukeUI
import SwiftUI

/// 从原生People页进入的独立管理sheet；原有卡片/人物时间线继续负责浏览。
struct PeopleManagementView: View {
    let source: any PeopleManaging
    let media: MediaLibraryController
    let owner: UUID
    let onFresh: ([ManagedPerson]) -> Void
    let onAttemptFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var store = PeopleManagementStore()
    @State private var selection: ManagedPerson?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Rename your person records, hide or show people, or merge two identities. Photos are retained.")
                        .font(.caption).foregroundStyle(.secondary)
                    status
                }
                Section("People, including hidden") {
                    ForEach(store.people) { person in
                        Button { selection = person } label: {
                            HStack {
                                ManagedPersonPortrait(person: person, media: media, size: 40)
                                Text(person.displayName).foregroundStyle(.primary)
                                Spacer()
                                if person.isHidden {
                                    Label("Hidden", systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                        .disabled(store.busy || store.needsReload)
                        .accessibilityIdentifier("manage-person-\(person.id)")
                    }
                    if store.hasLoaded, store.people.isEmpty {
                        Text("No people").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Manage people")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { reloadButton }
            }
            .navigationDestination(item: $selection) { person in
                PeopleManagementDetail(person: person, store: store, source: source, media: media, run: run)
            }
        }
        .task(id: owner) { store.invalidate(); selection = nil; await store.reload(source: source) }
        .onChange(of: store.revision) { _, _ in selection = nil; onFresh(store.people) }
        .onChange(of: store.mutationRevision) { _, _ in onAttemptFinished() }
        .onDisappear { operation?.cancel(); operation = nil; store.invalidate() }
        .accessibilityIdentifier("people-management-root")
    }

    /// 明确Reload只重发GET，不重放上次确认的改名/隐藏/合并。
    private var reloadButton: some View {
        Button("Reload") { run { await store.reload(source: source) } }.disabled(store.busy)
    }

    /// 状态区分busy、失败与确认后的成功，错误时旧数据仍可看但不可继续写。
    @ViewBuilder private var status: some View {
        if store.busy {
            ProgressView("Contacting server")
        }
        if let error = store.error {
            Text(L10n.string(error)).foregroundStyle(.red).accessibilityIdentifier("people-management-error")
            Text("Reload people before another change.").font(.caption).foregroundStyle(.secondary)
        }
        if let notice = store.notice {
            Text(notice).foregroundStyle(.secondary)
        }
    }

    /// action由当前页面持有；离开整个管理页时取消，详情确认动作不生成隐形后台任务。
    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard owner == media.management.generation else { store.invalidate(); return }
        operation?.cancel()
        operation = Task { await action() }
    }
}

/// 确认时固定人物和合并方向；任何失败后必须Reload，不以本地列表假定服务端回滚。
private struct PeopleManagementDetail: View {
    let person: ManagedPerson
    let store: PeopleManagementStore
    let source: any PeopleManaging
    let media: MediaLibraryController
    let run: (@escaping @MainActor () async -> Void) -> Void
    @State private var name = ""
    @State private var targetID = ""
    @State private var confirmation: Confirmation?

    /// 确认载荷保存真正提交的字段；弹窗显示期间列表/输入变化不能偷偷改变写入内容。
    private enum Confirmation: Identifiable {
        case rename(String), visibility(Bool), merge(ManagedPerson)
        var id: String {
            switch self { case .rename: "rename"; case .visibility: "visibility"; case .merge: "merge" }
        }
    }

    var body: some View {
        Form {
            Section {
                HStack { ManagedPersonPortrait(person: person, media: media, size: 64); Text(person.displayName) }
            }
            if let error = store.error {
                Section {
                    Text(L10n.string(error)).foregroundStyle(.red)
                    Text("Reload people before another change.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.busy {
                Section { ProgressView("Contacting server") }
            }
            Section("Name for your account") {
                TextField("Name", text: $name)
                Text("Only your record is renamed. An empty name becomes Unnamed.").font(.caption).foregroundStyle(.secondary)
                Button("Review name change") { confirmation = .rename(name) }
                    .disabled(!canWrite || name == person.name)
            }
            Section("Person visibility") {
                Text(L10n.string(person.isHidden ? "This person is hidden from the normal People list." : "This person appears in the normal People list."))
                Button(L10n.string(person.isHidden ? "Review showing person" : "Review hiding person")) { confirmation = .visibility(!person.isHidden) }
                    .disabled(!canWrite)
                Text("Hiding a person does not hide, trash or delete their photos.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Merge this person into") {
                Picker("Keep target", selection: $targetID) {
                    Text("Select a target").tag("")
                    ForEach(store.people.filter { $0.id != person.id }) { target in
                        HStack {
                            ManagedPersonPortrait(person: target, media: media, size: 40)
                            Text(target.displayName)
                            if target.isHidden {
                                Image(systemName: "eye.slash")
                            }
                        }.tag(target.id)
                    }
                }
                .pickerStyle(.navigationLink)
                if let target = store.people.first(where: { $0.id == targetID }) {
                    HStack { ManagedPersonPortrait(person: target, media: media, size: 64); Text("Keep \(target.displayName)") }
                }
                Text("The target is first. The server keeps the first available name and birth date and may also merge linked records shared with other users.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Review merge", role: .destructive) {
                    if let target = store.people.first(where: { $0.id == targetID }) {
                        confirmation = .merge(target)
                    }
                }.disabled(!canWrite || targetID.isEmpty)
            }
        }
        .navigationTitle(person.displayName)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Reload") { run { await store.reload(source: source) } }.disabled(store.busy) } }
        .onAppear { name = person.name }
        .confirmationDialog("Confirm person change", isPresented: Binding(get: { confirmation != nil }, set: {
            if !$0 {
                confirmation = nil
            }
        }), titleVisibility: .visible, presenting: confirmation) { change in
            switch change {
            case let .rename(value): Button("Save name for your account") { run { await store.rename(person, name: value, source: source) } }
            case let .visibility(hidden): Button(L10n.string(hidden ? "Hide person" : "Show person")) { run { await store.setHidden(person, hidden: hidden, source: source) } }
            case let .merge(target): Button("Merge into \(target.displayName)", role: .destructive) { run { await store.merge(target: target, sourcePerson: person, source: source) } }
            }
        } message: { change in
            switch change {
            case let .rename(value): Text("Rename \(person.displayName) to \(value.isEmpty ? "Unnamed" : value) for your account?")
            case let .visibility(hidden): Text(L10n.string(hidden ? "Hide this person from the normal People list? Photos remain unchanged." : "Show this person in the normal People list?"))
            case let .merge(target): Text("Merge \(person.displayName) into \(target.displayName)? Shared linked records may also merge. Photos are retained. This cannot be undone here.")
            }
        }
    }

    /// fresh列表和空闲状态均满足才可确认写入；失败后Reload是唯一恢复入口。
    private var canWrite: Bool {
        !store.busy && !store.needsReload
    }
}

/// 管理页复用现有账号隔离的人物缩略图/pipeline；无名或重名人物仍可通过真实头像选择合并方向。
private struct ManagedPersonPortrait: View {
    let person: ManagedPerson
    let media: MediaLibraryController
    let size: CGFloat
    @Environment(\.displayScale) private var scale

    var body: some View {
        let summary = LibraryPerson(id: person.id, name: person.name, updatedAt: person.updatedAt ?? .distantPast)
        LazyImage(request: media.personThumbnailRequest(summary, pixels: max(1, Int((size * scale).rounded(.up))))) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .pipeline(media.pipeline ?? .shared)
        .frame(width: size, height: size).clipShape(.circle).accessibilityHidden(true)
    }
}
