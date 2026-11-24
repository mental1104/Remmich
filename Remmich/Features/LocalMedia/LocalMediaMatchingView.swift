import SwiftUI

/// 独立本机优先设置页；只呈现真实Controller状态，入口由现有账号设置宿主提供。
struct LocalMediaMatchingView: View {
    let controller: LocalMediaMatchController
    let manager: LibraryManagementController

    var body: some View {
        Form {
            Section("本机照片优先") {
                Toggle("自动匹配并优先使用本机照片", isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0, using: manager) }))
                    .accessibilityIdentifier("local-media-enabled")
                Text("将手机已有照片与Immich匹配，浏览、放大和播放优先读取本机当前版本。不会上传或删除照片，也不自动下载iCloud原片。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("匹配状态") {
                Text(controller.status).accessibilityIdentifier("local-media-status")
                LabeledContent("照片权限", value: permissionLabel)
                LabeledContent("已检查本机项目", value: "\(controller.scanned) / \(controller.total)")
                LabeledContent("元数据关联", value: "\(controller.metadataMatches)")
                LabeledContent("本机校验和关联", value: "\(controller.checksumMatches)")
                LabeledContent("未确认本机项目", value: "\(controller.unmatched)")
                if controller.metadataFailures > 0 {
                    LabeledContent("元数据读取问题", value: "\(controller.metadataFailures)")
                    Text("部分Immich元数据不可用；仅用独立本机校验和继续尝试，不会下载原片或把未命中当成上传。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if controller.running {
                    ProgressView()
                    Button("停止扫描", role: .cancel) { controller.cancel() }.accessibilityIdentifier("local-media-cancel")
                } else {
                    Button(controller.enabled ? "重新扫描已授权照片" : "启用并扫描照片") { controller.scan(using: manager) }
                        .disabled(manager.client == nil).accessibilityIdentifier("local-media-scan")
                }
            }
            Section("范围与限制") {
                Text("首次启用需要照片访问权限。有限权限只扫描已授权范围；启用配置与确认关联按服务器和账号隔离保存。以后启动恢复并自动刷新，照片库变化会使旧关联失效。")
                Text("仅本机可用资源参与读取。无法确认、仅在iCloud或服务端另有编辑时使用Immich。Live Photo本轮仅支持本机静态帧，动态效果仍走现有路径。关联不代表原片已备份，不能用作清理设备空间的凭据。")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("本机照片匹配")
    }

    /// 只解释当前系统已有授权；打开页面不弹授权框，第一次请求由明确按钮/开关触发。
    private var permissionLabel: String {
        switch controller.permission {
        case .unknown: "尚未授权"
        case .full: "全部照片"
        case .limited: "仅已授权照片"
        case .denied: "未允许访问，请在系统设置中调整"
        }
    }
}
