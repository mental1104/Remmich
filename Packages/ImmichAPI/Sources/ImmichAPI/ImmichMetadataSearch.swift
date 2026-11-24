import Foundation

/// 原生元数据搜索条件；空值表示不限制，不包含账号范围或客户端计算的分页偏移。
public struct ImmichMetadataSearch: Hashable, Sendable {
    /// 资源类型；all 不向服务器发送类型限制。
    public enum Media: String, CaseIterable, Sendable { case all, image, video }

    public var text = ""
    public var media: Media = .all
    public var city = ""
    public var cameraMake = ""
    public var cameraModel = ""

    /// 创建空条件；调用方按用户选择修改值，不自动读取设备照片。
    public init() {}
}

/// 一页实际搜索资源；nextCursor 必须原样传回，不是页码或总数量。
public struct ImmichMetadataSearchPage: Sendable {
    public let assets: [ImmichTimelineAsset]
    public let nextCursor: String?
}
