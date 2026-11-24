/// 把原仓库的受鉴权、取消和代际保护的组织读取暴露给原生入口，不创建另一个账号会话。
extension ImmichTimelineRepository: OrganizationReading {}
