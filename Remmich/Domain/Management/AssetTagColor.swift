import Foundation

/// 标签颜色的标准sRGB字节；接受官方四种hex长度，规范为六/八位，不包含标签名称、层级或照片关系。
nonisolated struct AssetTagColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    /// hex允许官方RGB/RGBA/RRGGBB/RRGGBBAA及可选#；其他字符、空白或长度失败，不把坏值当成清除。
    init(hex: String) throws {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard [3, 4, 6, 8].contains(digits.count), digits.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0) }) else {
            throw AssetTagError.invalidColor
        }
        let expanded = digits.count <= 4 ? digits.map { String(repeating: String($0), count: 2) }.joined() : digits
        guard let value = UInt32(expanded, radix: 16) else { throw AssetTagError.invalidColor }
        let rgba = expanded.count == 6 ? value << 8 | 255 : value
        red = UInt8((rgba >> 24) & 255); green = UInt8((rgba >> 16) & 255)
        blue = UInt8((rgba >> 8) & 255); alpha = UInt8(rgba & 255)
    }

    /// red/green/blue/alpha为0...255的sRGB分量；缺省alpha为不透明，原生选色器先验证有限范围再调用。
    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// 返回官方接受的#RRGGBB或#RRGGBBAA；不透明不额外写alpha，比较仍按完整RGBA语义。
    var hex: String {
        let rgb = String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
        return alpha == 255 ? rgb : rgb + String(format: "%02X", Int(alpha))
    }
}

/// 用户的三态颜色意愿；keep省略字段，clear明确null，set只写颜色，不混同改名或移动层级。
nonisolated enum AssetTagColorChange: Equatable, Sendable {
    case keep, set(AssetTagColor), clear

    /// tag为真实响应；官方mapTag把数据库无颜色省略，只有该已核合同允许把无值确认成未设颜色。
    func matches(_ tag: ManagedTag) -> Bool {
        switch self {
        case .keep: true
        case let .set(color): tag.color.flatMap { try? AssetTagColor(hex: $0) } == color
        case .clear: tag.color == nil
        }
    }
}

/// 官方PUT的颜色专用正文；编码全部键由本类型决定，不能夹带name/parentId或任意缺省值。
nonisolated struct AssetTagColorPatch: Encodable, Sendable {
    let change: AssetTagColorChange
    private enum CodingKeys: String, CodingKey { case color }

    /// encoder接收用户明确三态意愿；keep为空对象且不会进入写通道，清除必须编码JSON null。
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch change {
        case .keep: break
        case let .set(color): try values.encode(color.hex, forKey: .color)
        case .clear: try values.encodeNil(forKey: .color)
        }
    }
}
