import Foundation

/// 一个可选拍摄设备对应账号内出现过的原始EXIF型号集合；显示名不参与服务端匹配。
nonisolated struct NativeCaptureDeviceOption: Hashable, Identifiable, Sendable {
    /// 与现有Web设备区一致的展示分组；相机仍使用独立相机筛选。
    enum Group: String, CaseIterable, Sendable {
        case iphone, action, other

        /// 返回分组标题，不暴露EXIF原始字段名。
        var title: String {
            switch self {
            case .iphone: "iPhone"
            case .action: "DJI / Insta360"
            case .other: "Other capture devices"
            }
        }
    }

    let label: String
    let models: [String]
    let group: Group
    /// 选项按产品名聚合；稳定身份不依赖候选响应顺序或数组位置。
    var id: String {
        label
    }
}

/// 将官方账号内型号建议整理为现有Web产品分组；别名表只改显示，绝不制造未出现过的型号候选。
nonisolated enum NativeCaptureDeviceCatalog {
    /// 固定产品别名与Web capture-devices.ts保持一致；所有实际请求仍使用候选里的原始字符串。
    private static let aliases: [(label: String, models: [String])] = [
        ("Insta360 GO 3S", ["Insta360 GO 3S"]),
        ("Insta360 X5", ["Insta360 X5"]),
        ("DJI Action 5 Pro", ["DJI OsmoAction5 Pro", "AC004"]),
        ("DJI Pocket 3", ["DJI OsmoPocket3", "PP-101"]),
        ("DJI Mini 4 Pro", ["DJI Mini4 Pro", "FC8482"]),
    ]

    /// models是当前账号的原始型号建议；返回去重、自然排序的产品组选项，排除相机和软件编码器。
    static func options(_ models: [String]) -> [NativeCaptureDeviceOption] {
        var grouped: [String: Set<String>] = [:]
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isCameraModel(trimmed),
                  !trimmed.lowercased().hasPrefix("lavf"), !trimmed.lowercased().hasPrefix("replaykit")
            else { continue }
            grouped[label(model), default: []].insert(model)
        }
        return grouped.map { name, values in
            let group: NativeCaptureDeviceOption.Group = name.lowercased().hasPrefix("iphone") ? .iphone
                : name.lowercased().hasPrefix("dji") || name.lowercased().hasPrefix("insta360") ? .action : .other
            return NativeCaptureDeviceOption(label: name, models: sorted(Array(values)), group: group)
        }.sorted { comesBefore($0.label, $1.label) }
    }

    /// models为已保存或已选原始型号；返回去重的产品显示名，未加载候选也能完整显示已有选择。
    static func selectedTitle(_ models: [String]) -> String {
        sorted(Array(Set(models.map { label($0) }))).joined(separator: " / ")
    }

    /// model为原始EXIF字符串；只在规范化值命中已知别名时改为产品名，否则完整保留。
    private static func label(_ model: String) -> String {
        let key = normalized(model)
        return aliases.first { entry in entry.models.contains { normalized($0) == key } }?.label ?? model
    }

    /// value为产品型号；返回与Web相同的ASCII字母数字小写键，不用于请求或保存。
    private static func normalized(_ value: String) -> String {
        String(String.UnicodeScalarView(value.lowercased().unicodeScalars.filter {
            (97 ... 122).contains($0.value) || (48 ... 57).contains($0.value)
        }))
    }

    /// model为去首尾空白的型号；识别Web相机区管理的品牌与Sony型号前缀。
    private static func isCameraModel(_ model: String) -> Bool {
        model.range(of: #"^(nikon\b|canon\b|sony\b|ilce-|ilca-|dsc-)"#, options: .regularExpression.union(.caseInsensitive)) != nil
    }

    /// values为显示名或原始型号；返回独立自然排序数组，不改变输入集合。
    private static func sorted(_ values: [String]) -> [String] {
        values.sorted { comesBefore($0, $1) }
    }

    /// lhs/rhs是待展示文本；自然比较相同时按原始字符串定序，避免Set遍历顺序影响保存值和游标上下文。
    private static func comesBefore(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.localizedStandardCompare(rhs)
        return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }
}
