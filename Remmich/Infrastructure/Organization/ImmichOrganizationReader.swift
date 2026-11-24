/// 把原仓库的受鉴权、取消和代际保护的组织读取暴露给原生入口，不创建另一个账号会话。
extension ImmichTimelineRepository: OrganizationReading {}

/// 相簿列表及成员管理复用原仓库生命周期，写后读取不能脱离凭据/端点代际保护。
extension ImmichTimelineRepository: ManagementAlbumReading, ManagementTimelineProviding {}
