# 系统后台照片备份

2026-11-25，独立codex/feature-system-background-photo-backup从98109d6创建。客户端上游672f02e、服务端官方v3.4.2均无同步；用户要求前五项开发收口，运行与设备验收统一后置。

## 可见行为与持久事实

照片备份页新增“系统后台备份（本账户）”，默认关闭，独立于前台自动备份。启用需已读取当前账号、保存包含/排除及iCloud选择且没有草稿；开关只保存同意，不隐式保存页面选择。系统根据自己的时机分配processing时间，不保证固定周期或锁屏即刻上传。

同意保存为原PhotoBackupJournal.Header的可选backgroundAutomaticEnabled；旧缺键为关闭，前台开关不能推导后台同意。已有格式/namespace/选择完整性仍检查，不改SQL schema或迁移。旧客户端忽略新可选字段会失去后台启用，而不会扩大上传范围。关闭先取消并等待实际后台任务再存false；取消/账号代际错误不发布旧结果。明确“停止并关闭自动备份”关闭并后读确认前台/系统后台两项，失败显示未确认，不宣称关闭已保存。

## 系统与实际队列接线

复用原LibraryBackgroundSyncCoordinator的processing注册、任务标识、系统请求、资源条件、expiration和唯一AppSession owner。refresh仍只做原索引；没有第二调度器、独立上传器、常驻定时器或新增系统identifier。Info既有processing/fetch权限及两标识数组逐字保留，只修正照片用途描述以涵盖明确自动启用。

processing恢复登录并重新验证路由后，先执行明确同意的后台备份，再继续原索引。headless恢复原本不初始化Media pipeline，所以只把已验证session/endpoint绑定到现管理通道；不要求前台曾出现，不为后台创建整套图片pipeline。后台同意先只读已验证日志头，不因用户未同意而恢复任务或请求Photos权限。

同意开启后使用原Controller.load和runSavedQueue.background，重新核对已保存相簿/排除、已有Photos权限、账号/端点及iCloud意愿；扫描新源并使用与前台相同的安全计划，交原唯一PhotoBackupRunCoordinator/Worker/SQLite执行。不把background伪装成foreground active，不发新权限弹窗。失败、取消、已尝试未知和部分Live/RAW回执不自动重发，保留原人工核查与恢复语义。

系统expiration取消父任务并传到实际Worker，原调度器等待清理并完成系统回执；后台同意保持，不调用用户停止入口。Worker保留原检查点、查重、完整媒体与暂停恢复。任务结束后仍开启则保留或补排原processing请求；冷同意晚于首次排程恢复也不依赖前台页面重排。账号/端点退役按原代际检查停止，旧错误不覆盖新账号结果。

## 实际检查与待统一验收

- 新增7函数9声明场景：旧头/独立同意、真实Controller/SQLite/Worker/私有HTTP新源成功、明确停止两开关、disabled/权限/草稿三门、跨账号草稿隔离、真实导出await后到期取消，以及实际AppSession冷processing管理绑定且Media pipeline仍nil。全部**未执行Swift**；最后一项不等于OS实际授予过任务。冷load同时修正草稿仅在原configurationScope内保留，不能污染新账号配置。
- 旧自动备份测试/HTTP夹具/退役门和旧会话测试逐字保留，原Worker/Exporter、SDK、编译输入、工作流及系统标识未改；NAS独立Node源码/JSON/边界审计通过。
- 本片9个修改Swift文件SwiftFormat0.64.5 lint通过，diff通过。只读同伴审查发现并实际修正冷管理通道、开关await后外层校验、旧owner迟到错误发布三处问题；不是Swift编译或运行证明。
- Swift6/Xcode、合成回归执行、真实Photos/iCloud、系统调度/后台时间/耗电、签名设备与官方客户端共存均待最终统一验收。没有新CI、push、dev合并、父gitlink、真实服务HTTP或生产操作。

回退客户端补丁保留原队列和已确认回执；旧同名系统任务仍由旧索引处理，不代表服务端已上传原片会撤销。用户已保存的远端资产、相簿关系及恢复资料不能靠回退代码当作已回滚。
