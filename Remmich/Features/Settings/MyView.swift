import SwiftUI

/// 底栏“我的”是账户、备份与应用偏好的统一入口；沿用当前会话持有的控制器，不创建第二条同步通道。
struct MyView: View {
    let session: AccountSession
    let profile: ConnectionProfile
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus
    let libraryIndex: LibraryIndexController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: (Bool) async -> Void
    let sessionController: AppSessionController?
    @State private var showsBackup = false
    @State private var showsPartners = false

    /// 页面只呈现入口；备份和匹配仍由Media中的共享实例负责生命周期。
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    AccountAvatarView(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.userEmail).font(.headline).textSelection(.enabled)
                        Label("Immich account", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            if let sessionController {
                Section("Backup & Sync") {
                    Button { showsBackup = true } label: {
                        Label("Library Sync", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                    .accessibilityIdentifier("my-photo-backup")
                    NavigationLink {
                        settings(initialPage: .index)
                    } label: {
                        Label("Library Sync & Index", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button { showsPartners = true } label: {
                        Label("Partner Sharing", systemImage: "person.2")
                    }
                }
            }
            Section("Settings") {
                NavigationLink { settings(initialPage: .connection) } label: {
                    Label("Server & Connection", systemImage: "network")
                }
                NavigationLink { settings(initialPage: .cache) } label: {
                    Label("Cache & Storage", systemImage: "internaldrive")
                }
                NavigationLink { AppLanguageSettingsView() } label: {
                    Label("App Language", systemImage: "globe")
                }
                .accessibilityIdentifier("my-language")
                NavigationLink { settings(initialPage: .home) } label: {
                    Label("Account & More Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("Me")
        .accessibilityIdentifier("my-root")
        .sheet(isPresented: $showsBackup) {
            if let sessionController {
                PhotoBackupView(controller: sessionController.media.management, backup: sessionController.media.photoBackups,
                                albumSync: sessionController.media.photoBackupAlbumSync, albumAutomation: sessionController.media.photoBackupAlbumAutomation, localMatches: sessionController.media.localMediaMatches)
            }
        }
        .sheet(isPresented: $showsPartners) {
            if let sessionController {
                PartnerSharingView(controller: sessionController.media.management, libraryIndex: sessionController.libraryIndex)
            }
        }
    }

    /// initialPage直接进入既有高级设置子页；使用同一账户和写入通道，保留原有确认门禁。
    private func settings(initialPage: AccountSettingsView.SettingsPage) -> some View {
        AccountSettingsView(session: session, profile: profile, activeRoute: activeRoute, routeStatus: routeStatus,
                            libraryIndex: libraryIndex, saveProfile: saveProfile, signOut: signOut,
                            sessionController: sessionController, showsCloseControl: false, drawsGlassBackground: false,
                            initialPage: initialPage)
    }
}
