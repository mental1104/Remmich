# 原生日期、位置与评分管理

本轮独立集成分支 `codex/feature-asset-metadata-integration` 从固定PR8 `51e5d1099a60f90f3111e1d69d975b33fdecb24a` 创建，只择取旧 `40f190d23f3cfbbd988fc727c8c52c0c9fa333a3`。原切片基于795；没有整串合入metadata工作树b6f20b6的祖先，也不包含标签36a8500、后续HTTP文档或新服务端评分源码。两份文档冲突保留51e5全部原行和原元数据记录，其他共享写入/查看器逻辑不变。

真实入口仍是资源详情的“编辑与管理 → Date, location and rating”。沿用Remmich SwiftUI表单、现有受限 `LibraryMutationClient.send` 及认证会话；没有新URLSession、持久队列或共享Viewer/Media/Index改动。当前Viewer原 `changed` 回调重读详情并要求正常刷新；`editsChanged`不变。没有修改固定PR8候选、dev、服务端、官方mobile、生成SDK、workflow或生产。

## 已核对的真实契约

原证据来自父Fork dev301d510的controller/DTO/service/access/date与main/Web；本轮重新读取父49a3e993f的单项DTO、EXIF更新、固定区提取及官方v3.4.2合同。`AssetService.updateExif`只省略undefined，rating:null保留；单项更新不接受独立timeZone或日期/位置null。官方5c3837380明确恢复-1=rejected，但已有缓存c15镜像的元数据重提取仍会丢失-1；父源码评分修复已独立合入，不代表生产部署或客户端本轮已HTTP通过。客户端上游仍672f02e，无上游同步。

| 操作 | 官方接口与确认 | 本页行为 |
| --- | --- | --- |
| 读取 | `GET /api/assets/:id`，`asset.read`，精确 200、同资源 ID | 每次重载、写前预检、写后回读都真正请求，不使用索引 GET 缓存 |
| 拍摄日期 | `PUT /api/assets/:id`，`dateTimeOriginal` 字符串 | 仅明确选择时发送含毫秒和固定 UTC 偏移的 ISO；服务端派生 `timeZone`。单项 DTO 无独立时区字段，不支持 null 清空 |
| 位置 | 同 PUT，latitude/longitude 成对、有限且范围合法 | 单轴零值合法；0/0虽被PUT接受，官方后续提取会按Null Island规则丢弃。页面与0/0确认明确提示该边界，不把它当清空或稳定持久化。不省略半边，不调用公共地理查询；DTO不支持清空 |
| 评分 | 同 PUT，`-1` 或 `1...5` 或 `null` | 保留时省略；Rejected=-1；清空明确编码 null。0 是非法新写值，读取的旧版 0 原样展示和保留 |
| 写权限 | `asset.update`，当前 owner，服务端锁定资源还要求 elevated session | 共享可读不等于可写；回收站资源先恢复；服务器的 401/403 等仍决定最终权限 |

所有 PUT 只编码用户选中的元数据键，不发送描述、可见性、收藏或 Live Photo 关联；只修改选中的资源，不修改配对动态资源。要求精确 200、同 ID/owner、同媒体类型/配对 ID，且选中字段实际出现并匹配。评分缺键不能当成明确 null。错误成功码、畸形/错资源响应和未知写入不能显示保存成功，也不会自动重发。

## 确认、并发与生命周期

表单字段默认 keep。审阅捕获固定补丁、完整读取快照与页面/账号代际；确认后 fresh GET 必须仍等于捕获快照，才允许一次 PUT。保存后另发 GET，重新获得可继续编辑的状态。这是并发预检，**不是 CAS 或原子事务**，预检与 PUT 之间仍存在竞态。

明确区分：未发送、已发送但结果未知、200 已确认但回读失败、当前回读已确认。停止等待不会声称回滚；已发送的未知结果只使当前账号读者失效，要求重读。账号/端点切换、页面退出会撤销旧发布权并取消请求；旧响应不能改变新页面，也不能消费旧确认。本轮补齐初次读取的cancel和后台清除pending确认，恢复前台不自动重试。表单、生命周期和确认弹层保持同一State，分some View边界以限制SwiftUI推断复杂度。

写入使用现有 EXIF lock/SidecarWrite 机制，可能产生或更新 sidecar；不覆盖照片/视频原片。PUT 确认的是元数据保存，**不等于后台派生任务已经完成**。

## 日期分组联调仍未完成

现有发布链已经接通：`management.revision → AppShellView.syncNow → LibraryIndexSynchronizer → accepted generation → AppSessionController.photos/videos.bootstrap`。viewer 在场时暂存 accepted bootstrap，退出后发布；无需另加 Photos observer。

仍有两个有源码证据的边界，不能把详情更新当作时间线验收：

1. 服务端先更新 EXIF，再排 SidecarWrite；`JobService` 在 sidecar 成功后排 metadata extraction，后者才更新资源 `localDateTime`。因此紧随 PUT 的 GET/索引同步可能仍看到旧分桶字段。
2. 当前 incremental 仅重取最新两个桶和计数有变化的桶。历史月份内部改日期、计数不变时，已有记录可能保留旧排序。

后续最小 targeted refresh 建议：输入当前账号代际、assetID、读取时已知 old bucket（以当前 accepted index 为准）以及请求日期；在 fresh 资源 `localDateTime` 确认派生完成后，强制获取真实前后桶，即使两者相同或计数未变，再复用现有 accept/bootstrap 发布。旧桶来自 accepted index 比从 EXIF 猜测可靠；新桶应取服务端实际派生结果。`AssetMetadataPlan.baseline`、`patch.date`、`AssetMetadataSnapshot.localDateTime` 保留必要信息，但本片没有修改共享索引/时间线、添加每次全量同步或无限轮询。失败必须保留尚未完成的刷新状态，不能报告已重排。

## 已做与未做的验证

现有测试扩展为10个函数、38个声明场景，经实际 `AssetMetadataStore → LibraryManagementController → LibraryMutationClient → URLSession` 路径注入独立合成字节，尚未执行Swift。覆盖完整请求body、省略与null、日期/偏移、单轴零与边界坐标、合法/非法评分、fresh GET与精确状态、owner/回收站、写前远端变化、响应缺字段/错ID/owner/zone、写后读取失败/变化、取消的三个写阶段、账号/端点隔离；本轮另加初次GET的取消/页面/换号/换端点四个门闩场景。0/0只检查官方请求编码，不将纯合成即时回执当成最终派生持久化证据。

私有URLProtocol接管所有host，未知请求失败而不回源；断言完整GET→GET→PUT→GET序列、Bearer、全部body与无多余请求。端点切换场景保持AccountSession逐字段不变，仅更换请求endpoint，独立覆盖路由代际。门闩通过真实请求到达/操作结束/取消清理推进，无sleep猜测时序。复杂的throwing prepare和JSON解析分步再进入#require/#expect；保留全部原断言，不将单宏复杂实参当成已证编译失败。

NAS本轮实跑六份Swift文件的SwiftFormat0.64.5 format/lint、shell语法、静态合成JSON与白名单/共享通道/历史文档保护审计、`git diff --check`。实际尝试原离线契约脚本exit127，原因是缺少swiftc；不能算契约执行通过。新日志/退出码/审计/官方源码快照保存在 `/volume2/codex-home/mental1104/tmp/remmich-metadata-integration-20261125.urp2PQ`。未运行Swift编译、38场景、HTTP黑盒、异步sidecar/排序效果、真机或官方客户端共存；旧c15 HTTP423断言396通过27失败保持历史，不能用旧51e5或新父评分242项服务端测试替代本片执行。

| 关口（各25%） | 本轮完成 | 边界 |
| --- | --- | --- |
| 实现 | 25/25% | 页面、当前写通道与双代际接线齐备 |
| NAS静态 | 25/25% | 格式/语法/有限源码审计实跑通过 |
| Swift运行 | 0/25% | NAS无Swift，编译和38场景未执行 |
| 集成验收 | 0/25% | 服务异步派生、排序及设备操作未验 |
| 合计 | 50/100% | 独立源码可交root整合，阶段4未完成 |

后续阶段 4：日期派生/历史排序 targeted refresh 联调；标签增删关系及标签管理另行核约并独立提交；共享相簿角色/成员管理；批量元数据与更多设备/辅助功能验收。日期/位置清空需要官方支持或另行定义兼容扩展，不以假值实现。

回退本独立提交即可移除入口/代码；已保存的元数据和 sidecar 不会因客户端回退自动恢复，恢复旧值需用户审阅后通过服务器正常修改。
