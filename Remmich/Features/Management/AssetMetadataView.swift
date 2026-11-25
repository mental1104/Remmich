import SwiftUI

/// 原生单资源元数据页；每个字段默认keep，只有评分可clear，坐标不经过公共地图/地理查询服务。
struct AssetMetadataView: View {
    let assetID: String
    let controller: LibraryManagementController
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AssetMetadataStore()
    @State private var changesDate = false
    @State private var wallDate = Date()
    @State private var offsetMinutes = 0
    @State private var changesLocation = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var ratingMode: MetadataRatingMode = .keep
    @State private var rating = 3
    @State private var pending: AssetMetadataPlan?

    /// 完整快照、所有权与管理通道空闲均满足才允许生成确认，最终权限仍由服务端裁决。
    private var canWrite: Bool {
        store.hasFreshData && !store.isWorking && !store.isLoading && !store.isCheckingDateProjection && !controller.busy
            && store.snapshot?.ownerId.lowercased() == controller.client?.userID.lowercased()
            && store.snapshot?.isTrashed == false
    }

    /// 常用固定偏移每15分钟一档；真实旧偏移仍保留为选项，不因列表范围而改变原值。
    private var offsetChoices: [Int] {
        var values = Set(stride(from: -12 * 60, through: 14 * 60, by: 15))
        values.insert(offsetMinutes)
        return values.sorted()
    }

    var body: some View {
        NavigationStack {
            metadataLifecycle
                .confirmationDialog("Apply metadata changes?", isPresented: Binding(get: { pending != nil }, set: {
                    if !$0 {
                        pending = nil
                    }
                }), titleVisibility: .visible, presenting: pending) { plan in
                    Button("Apply changes") { store.start(plan, manager: controller); pending = nil }
                    Button("Cancel", role: .cancel) { pending = nil }
                } message: { plan in Text(confirmationText(plan)) }
        }
    }

    /// 字段表单独立于生命周期和确认弹层，保留原State与绑定并限制SwiftUI泛型表达式长度。
    private var metadataForm: some View {
        Form {
            statusSection
            if let snapshot = store.snapshot {
                currentSection(snapshot)
                dateSection.disabled(!canWrite)
                locationSection.disabled(!canWrite)
                ratingSection.disabled(!canWrite)
                Section {
                    Button("Review changes") { review() }
                        .disabled(!canWrite || (!changesDate && !changesLocation && ratingMode == .keep))
                    Text("Changes affect this server asset in all clients. Unselected fields stay unchanged.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if snapshot.livePhotoVideoId != nil {
                        Text("The paired Live Photo resource keeps its own metadata.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 同一表单绑定真实账号代际和可见状态；离开前台清除待确认意图，取消读取/写入但不自动重试。
    private var metadataLifecycle: some View {
        metadataForm
            .navigationTitle("Date, location and rating")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(store.isWorking) } }
            .interactiveDismissDisabled(store.isWorking)
            .task(id: controller.generation) {
                if let task = store.reload(assetID: assetID, manager: controller) {
                    await task.value
                }
            }
            .onChange(of: store.snapshot) {
                _, snapshot in if let snapshot {
                    seedDraft(snapshot)
                }
            }
            .onChange(of: store.confirmedChanges) { old, current in
                if current > old, store.savedAccountGeneration == controller.generation {
                    changed()
                }
            }
            .onChange(of: controller.generation) { _, _ in pending = nil; store.invalidate(manager: controller); dismiss() }
            .onChange(of: scenePhase) {
                _, phase in if phase != .active {
                    pending = nil
                    store.cancel()
                }
            }
            .onDisappear { store.invalidate(manager: controller) }
    }

    /// 本地错误/保存回执与真正进行中的任务分开显示；停止等待不会被描述成撤销服务器修改。
    private var statusSection: some View {
        Section {
            if let notice = store.notice {
                Text(notice).foregroundStyle(.secondary)
            }
            if let error = store.error {
                Text(error).foregroundStyle(.red)
            }
            if store.isLoading {
                ProgressView("Loading current metadata")
            }
            if store.isWorking {
                ProgressView("Checking and saving metadata")
                Button("Stop waiting") { store.cancel() }
            }
            if let notice = store.dateProjectionNotice {
                Text(notice).foregroundStyle(.secondary)
            }
            if controller.metadataDateRefreshAvailable {
                if store.isCheckingDateProjection {
                    ProgressView("Checking timeline date")
                    Button("Stop date checking") { store.cancel() }
                }
                Button("Refresh timeline date") { pending = nil; store.refreshTimelineDate(manager: controller) }
                    .disabled(!store.hasFreshData || store.isWorking || store.isLoading || store.isCheckingDateProjection)
            }
            Button("Reload server metadata") { pending = nil; store.reload(assetID: assetID, manager: controller) }
                .disabled(store.isWorking || store.isLoading || store.isCheckingDateProjection)
        }
    }

    /// snapshot只来自真实GET；未知/旧版评分保持可读，不能因显示而自动规范化写回。
    private func currentSection(_ snapshot: AssetMetadataSnapshot) -> some View {
        Section("Current server metadata") {
            Text(snapshot.originalFileName)
            LabeledContent("Capture time", value: snapshot.exifInfo?.dateTimeOriginal ?? "Not recorded")
            LabeledContent("Time zone", value: snapshot.exifInfo?.timeZone ?? "Not recorded")
            if let latitude = snapshot.exifInfo?.latitude, let longitude = snapshot.exifInfo?.longitude {
                LabeledContent("Coordinates", value: "\(latitude), \(longitude)")
            } else {
                LabeledContent("Coordinates", value: "Not fully recorded")
            }
            LabeledContent("Rating", value: ratingLabel(snapshot.exifInfo?.rating))
            if snapshot.ownerId.lowercased() != controller.client?.userID.lowercased() {
                Text("Only the owner can change this metadata.").foregroundStyle(.secondary)
            } else if snapshot.isTrashed {
                Text("Restore this asset from trash before changing metadata.").foregroundStyle(.secondary)
            }
        }
    }

    /// DatePicker使用中性UTC墙上时间；改变偏移保留显示的时分，按用户选择重新解释瞬间，与Web确认语义一致。
    private var dateSection: some View {
        Section {
            Toggle("Set capture date and time", isOn: $changesDate)
            if changesDate {
                DatePicker("Date and time", selection: $wallDate, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                Picker("UTC offset", selection: $offsetMinutes) {
                    ForEach(offsetChoices, id: \.self) { offset in
                        Text(offsetLabel(offset)).tag(offset)
                    }
                }
            }
        } header: { Text("Capture date") } footer: {
            Text("Changing the offset keeps the displayed time. This server supports replacing the date, but not clearing it.")
            Text("The server may derive a different time zone while processing. Reload to verify the final value; timeline ordering may update later.")
        }
    }

    /// 经纬度作为一对编辑，空文本不是清空；客户端只把用户输入传给已连接服务器。
    private var locationSection: some View {
        Section {
            Toggle("Set coordinates", isOn: $changesLocation)
            if changesLocation {
                TextField("Latitude (-90 to 90)", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude (-180 to 180)", text: $longitude).keyboardType(.numbersAndPunctuation)
            }
        } header: { Text("Location") } footer: {
            Text("Use decimal degrees with a period. Coordinates go only to your Immich server. Clearing coordinates is not supported by this server.")
            Text("A single zero coordinate is valid. This server discards (0, 0), called Null Island, during metadata processing.")
        }
    }

    /// 评分明确分keep/set/clear；0只可能作为旧数据展示，绝不能当作新写值或未评分发送。
    private var ratingSection: some View {
        Section("Rating") {
            Picker("Action", selection: $ratingMode) {
                Text("Keep current").tag(MetadataRatingMode.keep)
                Text("Set rating").tag(MetadataRatingMode.set)
                Text("Clear rating").tag(MetadataRatingMode.clear)
            }
            if ratingMode == .set {
                Picker("Rating", selection: $rating) {
                    Text("Rejected").tag(-1)
                    ForEach(1 ... 5, id: \.self) { value in Text("\(value) stars").tag(value) }
                }
            }
        }
    }

    /// snapshot为当前fresh快照；重载后重新审阅，不能自动把旧草稿变成下一次写入。
    private func seedDraft(_ snapshot: AssetMetadataSnapshot) {
        changesDate = false; changesLocation = false; ratingMode = .keep
        let instant = AssetMetadataDateValue.parse(snapshot.exifInfo?.dateTimeOriginal) ?? Date()
        offsetMinutes = AssetMetadataDateValue.initialOffset(dateText: snapshot.exifInfo?.dateTimeOriginal,
                                                             zoneName: snapshot.exifInfo?.timeZone, instant: instant)
        wallDate = instant.addingTimeInterval(Double(offsetMinutes * 60))
        latitude = snapshot.exifInfo?.latitude.map { String($0) } ?? ""
        longitude = snapshot.exifInfo?.longitude.map { String($0) } ?? ""
        let current = snapshot.exifInfo?.rating ?? 3
        rating = current == -1 || (1 ... 5).contains(current) ? current : 3
    }

    /// 用户点击审阅时才构造补丁；未选字段省略，任何输入错误均在HTTP前拒绝。
    private func review() {
        do {
            var patch = AssetMetadataPatch()
            if changesDate {
                patch.date = .init(instant: wallDate.addingTimeInterval(-Double(offsetMinutes * 60)), offsetMinutes: offsetMinutes)
            }
            if changesLocation {
                guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AssetMetadataError.invalidLocation }
                patch.location = .init(latitude: lat, longitude: lon)
            }
            switch ratingMode {
            case .keep: patch.rating = .keep
            case .set: patch.rating = .set(rating)
            case .clear: patch.rating = .clear
            }
            pending = try store.prepare(patch, manager: controller)
        } catch { store.showError((error as? AssetMetadataError)?.errorDescription ?? "Reload metadata before reviewing another change.") }
    }

    /// plan固定了被修改字段和值；只在本地确认中显示用户选择，不写日志或调用地理服务。
    private func confirmationText(_ plan: AssetMetadataPlan) -> String {
        var lines = [plan.baseline.originalFileName]
        if let date = plan.patch.date {
            lines.append("Capture time: \((try? date.encodedValue()) ?? "Invalid date")")
        }
        if let location = plan.patch.location {
            lines.append("Coordinates: \(location.latitude), \(location.longitude)")
            if location.latitude == 0, location.longitude == 0 {
                lines.append("The server will discard (0, 0) during later metadata processing. This is not a supported location-clear operation.")
            }
        }
        switch plan.patch.rating {
        case .keep: break
        case let .set(value): lines.append("Rating: \(ratingLabel(value))")
        case .clear: lines.append("Clear the existing rating")
        }
        lines.append("Other fields stay unchanged. The server will be checked again before saving.")
        return lines.joined(separator: "\n")
    }

    /// value是服务端当前评分或合法新值；未知旧数据只读展示，不转换为新请求。
    private func ratingLabel(_ value: Int?) -> String {
        guard let value else { return "Unrated" }
        if value == -1 {
            return "Rejected"
        }
        if value == 0 {
            return "Legacy 0 (kept unless changed)"
        }
        return (1 ... 5).contains(value) ? "\(value) stars" : "Unknown rating \(value) (kept unless changed)"
    }

    /// minutes为固定UTC偏移，返回清晰的带符号小时/分钟显示，零偏移不会被当成缺省。
    private func offsetLabel(_ minutes: Int) -> String {
        String(format: "UTC%@%02d:%02d", minutes < 0 ? "-" : "+", abs(minutes) / 60, abs(minutes) % 60)
    }
}

/// 元数据页本地意图，与服务端评分数值分离，防止keep/clear误编码成0。
private nonisolated enum MetadataRatingMode: Hashable, Sendable { case keep, set, clear }
