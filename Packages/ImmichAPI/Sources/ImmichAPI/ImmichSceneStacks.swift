import Foundation

/// Fork场景展示组，仅描述已存在的照片ID；不代表官方stack或可写入的分组资源。
public struct ImmichSceneStackGroup: Decodable, Sendable {
    /// 不透明展示键；不要求UUID，不将其拼入API路径。
    public let id: String
    public let coverId: String
    public let members: [String]
}

/// 场景证据是否可用与完整组分开；available=false不是HTTP失败，也不代表照片不存在。
public struct ImmichSceneStackReply: Decodable, Sendable {
    public let available: Bool
    public let groups: [ImmichSceneStackGroup]
}
