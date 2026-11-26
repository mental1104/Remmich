import SwiftUI
import UIKit

/// 已选标签的局部颜色草稿；原生选色器只生成审阅意愿，不读取网络或直接保存。
struct AssetTagColorEditor: View {
    let tag: ManagedTag
    let review: (AssetTagColorChange) -> Void
    @State private var mode = Mode.keep
    @State private var selectedColor: Color

    /// 颜色操作不与改名混合；keep为初始状态，clear是明确选择而非把缺省草稿编码成null。
    private enum Mode: String, CaseIterable { case keep, set, clear }

    /// tag为当前fresh对象；review只进入父页面确认流程。未知旧颜色原样展示，不因无法预览就清除。
    init(tag: ManagedTag, review: @escaping (AssetTagColorChange) -> Void) {
        self.tag = tag; self.review = review
        let current = tag.color.flatMap { try? AssetTagColor(hex: $0) }
        _selectedColor = State(initialValue: current.map(Self.displayColor) ?? .blue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Current tag color", value: tag.color ?? "None")
            Picker("Color action", selection: $mode) {
                Text("Keep current color").tag(Mode.keep)
                Text("Set color").tag(Mode.set)
                Text("Clear color").tag(Mode.clear)
            }
            if mode == .set {
                ColorPicker("Tag color", selection: $selectedColor, supportsOpacity: true)
                if change == nil {
                    Text("Choose a color that can be represented as standard RGB.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button("Review tag color") {
                if let change {
                    review(change)
                }
            }
            .disabled(change == nil || mode == .keep || change?.matches(tag) == true)
            Text("This changes the tag color everywhere. Names, hierarchy and photo relationships are kept.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// 返回当前三态意愿；选色器分量无法表示为有限sRGB时不允许保存，不取缺省值冒充用户颜色。
    private var change: AssetTagColorChange? {
        switch mode {
        case .keep: return .keep
        case .clear: return .clear
        case .set:
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(selectedColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha),
                  [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }) else { return nil }
            return .set(.init(red: UInt8((red * 255).rounded()), green: UInt8((green * 255).rounded()),
                              blue: UInt8((blue * 255).rounded()), alpha: UInt8((alpha * 255).rounded())))
        }
    }

    /// color为已验证sRGB字节，返回原生预览/选色初值；alpha保留，不把RGBA偷偷改成不透明颜色。
    private static func displayColor(_ color: AssetTagColor) -> Color {
        Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255,
              blue: Double(color.blue) / 255, opacity: Double(color.alpha) / 255)
    }
}
