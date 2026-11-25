/// 人物管理挂在同一账户仓库；实际方法留在原actor内，复用其私有身份/端点代际和取消边界。
extension ImmichTimelineRepository: PeopleManaging {}
