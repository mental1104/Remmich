# 伙伴共享与照片时间线核对

独立分支codex/feature-partner-sharing从612e0c3创建，保留公开链接/共享成员/日期刷新原分支，不修改这些工作区。上游仍672f02e，没有同步。先核父仓库7653378；收口时重核父仓库4af6a3a3c及main，partner controller/service/DTO/repository与PartnerUpdate ACL无差异。

| 操作 | 官方请求 | 精确成功码 | 本人能改变的内容 |
| --- | --- | --- | --- |
| 分享给我 | GET partners?direction=shared-with | 200 | 读取别人向本人的授权 |
| 我分享给谁 | GET partners?direction=shared-by | 200 | 读取本人向别人的授权 |
| 添加伙伴 | POST partners，sharedWithId | 201 | 仅本人→所选现有账户，不使用deprecated POST/:id |
| 停止共享 | DELETE partners/:sharedWithId | 204 | 仅本人→对方，互相共享时另一方向保留 |
| 时间线偏好 | PUT partners/:sharedById，inTimeline | 200 | 接收者决定对方照片是否进入本人的服务端时间线 |

响应用户ID始终是对方，不是共享关系UUID。inTimeline在官方DTO可省略，缺失/null保留未知，不默认false。来向没有“代替对方撤销”按钮；去向没有“修改对方时间线”按钮。候选按官方Web/mobile排除本人及已有outgoing，只取当前GET/users返回的现有账户，不发送邮件、邀请或其他外部消息。

Profile→Account→伙伴关系与时间线进入新SwiftUI页面。已有Library Partners只读浏览保留，不实现第二套图库。所有动作先fresh读取两个方向/候选，再明确目标姓名与单向效果，确认后fresh双向预检、唯一精确写、fresh双向验证。确认期关系或候选改变、错误状态/目标/偏好回执、读取失败或额外相反方向变更都不宣称成功；未知结果要求重读，禁止自动重发。账号/端点/后台/退出每个await后校验代际，旧完成值不能发布新账号。

## 服务端保存与本机列表分别确认

主照片查询已有includesPartners=true，SDK发送withPartners，服务端TimelineService按当前用户incoming的inTimeline扩展owner范围。原索引增量却只读取最新两月及数量变化月份，旧月份等数量换成员会被复用；日期强制月份列表也只是内存资料。仅保存服务器开关或调用syncNow都不能证明本机列表已应用，重启后也不能靠一次内存请求恢复。

新逻辑复用原唯一LibraryIndexSynchronizer，不增加worker或修改旧accept事务：

1. 每个同步pass前由原ImmichTimelineRepository fresh GET incoming伙伴，规范化为账号namespace、伙伴ID与Bool?。前台/后台共用此已认证源，不依赖后台可能未配置的Media管理器。
2. 与原Accounts/namespace目录中的partner-timeline-policy.json比较。凭据包括formatVersion、待接受generation和规范policy；只有格式、namespace、已知bool、完整策略及当前accepted generation均匹配才允许原增量计数复用。
3. 凭据缺失/损坏/未知版本/代际不符/策略改变或未知flag时，先持久退休旧index GET，再使用原managementTimelineReader；对已有目录强制所有当前月份，加上旧accepted中已消失月份的空替换。首次空目录仍允许原短开屏批；未完成整个范围时不准备凭据。
4. 每个读取月份核对count、唯一ID及成员所属年月，合并后再核全局唯一。fresh策略bookend变化即拒绝；完整月份只在真实building generation上准备原子JSON，再检查原账号/路由/run/Task，最后沿原SQL原子accept。
5. 若在凭据写后、accept前中断，凭据与旧accepted代际不符，冷恢复强制重读；accept后中断则可从真实已接受代际恢复匹配。不是PUT后仅写内存dirty标志，因此其他客户端改变策略及迟到PUT结果也在下一次fresh策略读取中被识别。

旧GET退休沿原Queue的index lane移除、取消和回调代际规则。原finishIndexPass会吞持久写失败，因此增加专用throwing retirePartnerTimelineIndexPass；仅该新入口要求写盘成功，原函数与所有旧调用保持原样。received/completed仍必须找到现存job、owner/pass/attempt，迟到临时文件会被原guard删除，不能重建旧job。cache/export/albums等其他lane保留；没有删除照片、原片、导出或备份回执。

凭据是可重建的本机索引证明，不是备份资料。仅保存UUID/可空偏好/代际与namespace，不含姓名、邮箱、token、密码或链接。使用原账号目录、Data.atomic和0600/已有iOS文件保护。缺损可在完整fresh核对后重建；I/O失败阻止新accept，旧accepted仍可使用。不修改SQLite表/迁移/原accept实现。

原manager revision→AppShell→唯一Index run入口保留，新增的有限调度标志仅防止在途run漏掉下一轮；失败不无限重试，持久正确性来自查询作用域凭据。页面分别显示fresh服务端状态与匹配accepted证明的本机状态。未完成或失败时只允许重新读取照片列表，不重发PUT；不把服务端保存成功或sync请求当本机成功。已接受元数据也不代表SwiftUI设备绘制已验收。

## 验证边界

新增21函数73声明场景，均尚未执行Swift：

- PartnerSharingContractTests：7函数47项，真实Store→manager→客户端→私有URLSession，覆盖四动作/准确query与body、禁止反方向/未知状态、fresh预检变化、精确回执、双向后读、5阶段×4退休方式20个实际请求门。
- PartnerTimelineIndexTests：11函数21项，真实同步器、SQLite及原子文件，覆盖等数旧月换成员、新旧月份、半桶/等count重复/错月、accept前后冷恢复、缺/坏/未来版本/错误代际/未知flag、building门禁、bookend改变、在途补run、换号/端点、真实Queue迟到回调与实际文件系统I/O失败。只在依赖端口提供合成元数据，没有直接写DB伪造accepted结果。
- PartnerTimelineRepositoryTests：3函数5项，通过原repo的既有Loader字节边界核对fresh方向/认证、失败/未知状态与不合作迟到响应。此组不声称走真实URLSession；前述Store组才使用私有URLSession。没有访问真实服务、账户图库、Photos或原片。

NAS实际16文件SwiftFormat format/lint、bash语法、diff检查通过。独立Node审计解析7个实际Swift JSON片段并计算21/73声明矩阵，证明原client传输/其他写方法、旧SQL/备份/导出/accept、旧Queue/native回调/取消、共享HTTP夹具逐字保留；源码顺序核对为退休→fresh，building凭据→原accept。审计脚本：/volume2/codex-home/mental1104/tmp/remmich-partner-source-audit-20261125.cjs。这不是Swift、SQL、HTTP或设备运行证据。

Swift编译、73场景、真实服务HTTP、后台系统调度及设备UI未验证。每个pass通常增加两个元数据GET；策略变动/旧目录缺证明时会完整重读月份，未测量大图库耗时/服务器负载，不声称性能提高。顺序策略/月读取不构成服务端事务；变化时维持未确认并等待仅读重试。另已向root报告旧Library伙伴图库query仍保留includesPartners=true的独立范围问题，本片不借此改组织浏览入口。

没有push、CI、合dev、父gitlink、server/API/官方SDK/workflow/生产变更。回退只撤销本客户端模块及读取核对，派生凭据可保留；已由用户确认的真实伙伴关系/偏好不会因代码回退自动撤销，需要另外明确操作。本片没有在任何真实账户建立或撤销关系。
