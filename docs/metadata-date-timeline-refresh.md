# 日期派生确认与定向时间线刷新

从独立metadata切片45db8a0续建 `codex/feature-metadata-date-timeline-refresh`，不改51e5/fedba7a候选、dev、API/SDK、生产或原片。本工作按“日期投影确认”（1517113）和“旧/新桶索引接线”两个提交审查，保留现有接受代际与bootstrap语义。

## 已核源码与本地查询

- 官方单项PUT先写EXIF并排SidecarWrite，后续MetadataExtraction才在同次asset更新中改fileCreatedAt和localDateTime。日期-only PUT甚至可能不推进asset.updatedAt；其他普通字段也可推进它，因此HTTP200/updatedAt不能证明日期派生完成。
- fileCreatedAt是真实拍摄瞬间；localDateTime是用UTC ISO编码的服务器墙上时间。bucket的localOffsetHours来自二者差值。SDK的单详情capturedAt另映射localDateTime，不能误用它替代真实fileCreatedAt。
- canonical索引正常增量只选最新batch和数量变化桶。集合缓存另有older review，不能推导canonical历史同桶排序已经覆盖。公开Fork taskStatuses没有绑定本次PUT的完成token，不将其当可移植完成凭证。
- 完全本地内存SQLite查询实际通过：EXIF-only保持旧分桶；当前月移2019-06后旧月消失；同2019-06改日后计数不变但顺序改变，正常增量不选该月；另覆盖同墙换offset必须看fileCreatedAt、同instant换offset必须看localDateTime。它不是PostgreSQL/Swift/HTTP验收。

只读源码快照与查询结果：`/volume2/codex-home/mental1104/tmp/remmich-date-server-evidence-20261125.DonpnN/report.txt`、`query-results.json`。父源码固定7d5db7、客户端45db8a0；不复用生产图库或数据库。

## 第一提交：只确认当前投影

新模型要求fresh GET中的EXIF日期、真实fileCreatedAt与预期瞬间一致，localDateTime与服务器实际区名在该瞬间的秒级offset一致。IANA历史秒偏移保留；未知/缺失区名保持未确认，不从GPS或设备区猜测。只核此刻投影，不声称任务队列结束、未来不会再改，亦不突破stack/可见性过滤。

已确认日期写入后，最多3次fresh GET、间隔1秒；未就绪或失败明确保留未确认说明，不再PUT、不无限轮询。页面提供手动只读重试，取消/退出/换号/仅换端点都阻止迟到投影。日期检查时阻止另一项确认覆盖正在核对的状态。

专用需求仅暂存在当前管理账号的assetID→投影Map，通过现有revision通知；不是持久任务队列。能力默认关闭，第二提交在真实AppSession接受索引链存在时启用，孤立管理宿主不会假称已通知时间线。归档/隐藏/锁定资源只说明不在主时间线，不将其手动插入canonical索引。

第一提交新增纯投影9函数48声明场景，以及实际Store/manager/client/URLSession路径的6个合成只读场景：EXIF-only不发布、有限成功/耗尽、取消/页面/账号/端点退休；原38元数据场景保留。Swift未执行，不能把声明计数或本地SQLite查询当作应用通过。

## 第二提交：复用旧/新桶接受流程

AppShell现有management revision观察器接管已验证日期需求，交给原LibraryIndexController。若普通同步正在运行，只合并本账号最新assetID需求；当前run结束/失败后补一轮，不被已有task守卫吞掉。没有第二个索引worker，也不新增通用事件/任务框架。

日期pass从真实accepted snapshot查旧bucketKey，从投影fresh localDateTime只匹配现有服务器summary的UTC年月，不从EXIF字符串、用户输入或GPS造新桶。调用原repo `managementTimelineReader()` 获得代际绑定前台读取器，绕过持久GET/集合缓存；保持主query的timeline、stack、partner和trash范围。正常无日期请求路径继续使用原source和原选择策略。

强制月份必须count完整、桶内ID唯一、每项墙上年月正确；目标在同query中恰一项且真实拍摄/墙上时间/owner/visibility匹配投影。还在创建generation前检查完整拟接受记录的全局大小写规范ID唯一性，防止无关资产在两次串行月份响应间迁移造成跨桶重复；不能让SQL UPSERT吞掉一行而groups重复计数。缺少stack子项/隐藏资产不自行插入。

所有目标检查在beginGeneration及写入前完成；复用原remove/upsert/groups/accept原子事务和accepted-bootstrap发布。账号、端点及run在网络边界和accept前后验证；过期任务不能发布新账号/新路由页面。查看器仍按原策略延后bootstrap，退出再发布；没有重写bootstrap、scroll或viewer算法。这是当前网络快照投影，validate→accept不是跨actor CAS，也不能保证后台任务未来不再改。

失败或不完整月份保留原accepted数据并显示索引错误，不隐去照片。**已消费但失败的日期需求不自动重放；普通“立即同步”不会重放它。必须在元数据页点击“Refresh timeline date”，重新fresh确认后提交新的日期意图。** 活跃run期间尚未消费的新需求保留一次后续pass；账号/端点退休或显式停止网络工作会丢弃旧意图，同样需要重新核对，不能自动挪到新上下文。

第二提交新增7函数12声明场景，经真实SQLiteLibraryIndexStore/同步器/Controller/Bootstrap：普通增量确实保留历史旧日→定向校正日键/顺序；当前月移旧年月且旧桶消失；partial/桶内duplicate/目标变化/query外目标拒绝保留整代；跨forced桶重复非目标拒绝；held后context退休；Controller活跃普通run接到后续需求；真实账号/仅路由变化的迟到响应不发布。网络边界为合成完整月份，使用实际入门/释放门闩，无sleep推进业务。

## 验证与后续

本轮证据目录：`/volume2/codex-home/mental1104/tmp/remmich-date-refresh-20261125.gcCTku`。NAS实际12份Swift的SwiftFormat0.64.5 format/lint、差异、白名单/原bootstrap及SQLite源未改/声明用例计数静态审计通过；原离线契约脚本实际因无swiftc退出127，不能称契约通过。新日期相关为66声明场景（48领域+6 HTTP/Store+12索引），连同原38元数据共28函数104声明场景，均未执行Swift。

独立内存SQLite查询已实际运行，但它是源规则反例，不是新增Swift/SQLite测试执行。编译、Swift测试、真实异步服务HTTP、设备/滚动定位和最终日期排序验收仍未完成；原候选CI和父服务端242项均不能为本日期分支提供收据。阶段4未完成，集合/相簿日期缓存、批量元数据与共享管理均不在本片扩大。

| 关口（各25%） | 完成 | 本轮证据 |
| --- | --- | --- |
| 实现 | 25/25% | A确认+B真实索引消费者已接线 |
| NAS静态 | 25/25% | 12文件格式、范围/保留/计数审计及diff通过 |
| Swift运行 | 0/25% | 无Swift/Xcode，104声明场景未执行 |
| 集成验收 | 0/25% | 新服务HTTP、设备、真实排序/滚动未验 |
| 合计 | 50/100% | 独立源码交root审查，不纳当前CI |

回退需依次撤销索引接线和本投影确认；不改数据库结构，不自动回滚服务器已保存日期，也不进行生产重扫。
