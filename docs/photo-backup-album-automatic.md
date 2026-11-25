# 自动增量相簿组织

原自动片 `0985ed3` 从 `9c0e01a` 继续，整合 RAW 证明提交 `776be402`（原分支择取为 `5108a8a`），保留 `921d350` 的编辑者权限和仅所有者创建恢复。本次从完整候选 `af5c22a` 独立择取自动增量为 `c0929df`，保留既有系统后台、完整角色和阶段 3–5，再接入实际 AppSession processing 调用。官方基线仍为 `672f02e`，没有上游同步。自动组织开发源码已完成；Swift、系统行为与最终整合验收尚未执行。

## 用户行为

- 备份页提供默认关闭、按账号持久的自动相簿规则。开启说明明确采用已保存的包含/排除相簿、已有映射与照片授权；未保存草稿不生效，关闭页面不会丢失 Media 持有的前台规则。
- 实际前台激活、Photos 变化、备份完全退役、匹配与映射变化合并触发一次。共用已有组织 Controller、SQLite 账本和唯一备份 Coordinator，先等待上传完全退役，再重新核对当前上下文。
- 只增量补入有完整当前证明的安全新关系。自动路径跳过失败、未知、发送中、取消、已确认及部分确认的同源历史；这些项目仍需手动预览与核查。自动规则不创建相簿、不按同名认领、不改名、不移除关系或照片。
- 既有服务器交集继续使用严格 fresh 的当前 metadata 关联；新上传可使用真实 Worker 保存的同源原图 SHA1。旧摘要缺失不猜 UUID；Live 只组织主体，RAW/JPEG 两主原图都须证明及本轮 fresh 确认。组织不上传原片，不从 iCloud 或 Immich 下载原片；所选且本机已有的未编辑 RAW/JPEG 可读取两份本机原图摘要。

## 系统 processing 接口

`PhotoBackupAlbumAutomation.performBackground(backup:using:scope:validateLease:store:) async throws -> Bool` 是实际 await 入口，不依赖 SwiftUI 或 Media 初始化，不把后台伪装为前台。

调用者必须在备份 Task 和该 scope 的 `PhotoBackupRunCoordinator.perform` 完全退出后，于同一系统 processing 租约内调用。不能在相同 Coordinator 的 perform 闭包内重入。`validateLease` 由现有系统调度方检查租约、账号、端点及独立后台备份同意；expiration 必须取消实际外层 Task。方法将取消传给实际 prepare/synchronize 返回的独立 Task，并等待其完成。返回 true 表示本次安全候选全部完成或没有新关系，false 表示忙、草稿、权限、部分或未完成，不能解释为整个备份完成。

headless 匹配仅冷读同账号已保存关联，不开启全库扫描/hash，不弹授权。当前源、照片访问、账号代际、端点、远端资产与角色仍由实际组织路径逐项复核。

本次实际 `AppSession.performBackgroundPhotoBackup` 在上传 `operation.value` 退出、`backgroundLastResult == true` 且 fresh 后台同意仍开启后，于原 processing 租约结束前 await 上述入口。固定原租约 ID/kind、session、manager generation/scope、验证端点、routeGeneration 与网络路径；每次检查同时拒绝 Task 取消及独立后台同意关闭。只调用原 management.configure，不创建 Media pipeline。失败上传、已撤销租约或后台关闭不接组织，也不能用 aux 自动开关代替后台授权。

`prepare` / `synchronize` 新增默认 nil 的 `validateExternal` 窄端口，组合进入已有内部 check。网络路径变化未必取消父 Task，因此不能仅在整个组织 Task 完成后核租约；真实资产/角色/成员 GET 返回、PUT 前后及 checkpoint 都使用同一闭包。手动入口默认 nil，保留原明确确认行为。

## 关闭、持久化与未知结果

v3 的 `automaticEnabled` 是单一账号意愿。原子 header-only setter 保留所有 operation、创建意图和已收到的 201 身份，不用另一 Coordinator 打断手动上传或创建。旧计划保存继续保留磁盘最新意愿，不能由旧内存重新启用规则。

前台关闭撤销自己拥有的自动任务，并保存 false。另一个 headless 实例不依赖全局 registry：自动 synchronize 在实际 PUT 前及关键 await 后 fresh 读取并验证当前 header；检查点同一 SQLite 事务再核授权，关闭后不能继续写确认。手动 `automatic:false` 保持原明确确认行为。关闭规则不等于所有实例的 HTTP 已立即退役，已发出的请求仍可能完成；后续检查点停止，已有服务器关系不回滚，sending/queued 恢复事实保留供手动核查。

## 实际证据

原自动片新增 10 个测试函数、17 个声明场景；本次桥接补 2 个函数、5 个声明场景。合并此前手动、创建、角色、RAW 切片后，本文件共 46 个函数、118 个声明场景。这些数量是源码声明审计，不是通过数。

新增回归使用真实 Controller/Worker/client/SQLite 与合成 URLProtocol HTTP，覆盖默认关闭、事件合并、保存意愿、草稿/权限、unsafe 历史、真实 Coordinator owner、账号/前后台退役、headless/expiration、冷恢复不全库扫描、真实 ABC 原片 duplicate 校验到 primaryChecksum 再到自动成员写入。跨实例两场景在真实远端 GET 或首个 RAW PUT 已提交后持有响应，由另一个 driver 仅保存关闭；原 waiter 和租约保持有效，断言无后续 JPEG PUT、不误记 confirmed，并冷读保留 false 和 sending/queued。所有 gate 都有取消/释放/等待清理，不用 sleep 宣称请求已进入。

本次额外回归用真实 `PhotoBackupController.runSystemBackground` 完成原 Worker/HTTP/SQLite 上传周期后才调同租约组织，覆盖完整成功、后台独立关闭与租约先退役三个分支，确认原上传完成和摘要不被组织状态覆盖。另一组在真实成员 GET 或首个 PUT 后持有响应，只撤销租约而不 cancel waiter，拒绝后续 JPEG 和 confirmed；该场景能发现只在整 Task 外层核租约的旧路径。AppSession 的真实 PhotoKit 正例和系统启动时机仍未运行，不以这些合成端口代替。

| 关口 | 实际结果 | 计入证据 |
| --- | --- | ---: |
| 实现 | 前台驱动、headless await、UI 接线、持久意愿与取消门禁源码齐 | 25/25 |
| 静态 | 本次总候选 NAS SwiftFormat 0.64.5：0/458 需要修改、1 skip；diff/bash 检查通过；保护路径及历史保留审计完成 | 25/25 |
| 运行 | 未运行 Swift、合成 HTTP 测试、PhotoKit/UI/系统后台；离线契约实际退出 127，缺少 swiftc | 0/25 |
| 整合 | AppSession 桥接源码已接；尚未执行整体验收、真实服务和设备验收 | 0/25 |

本片开发 100%，上述实际证据为 50/100，不能宣称运行或整个阶段 2 完成。没有 push、触发 CI、合 dev、修改父 gitlink、生产、官方移动端、API/SDK、workflow、签名或上传 Header/后台配置。系统后台源码已在基线，网络恢复仍是另一独立提交，待 root 正常整合。

## 回退

先关闭保存的自动规则，再撤销本片调用方；保留 v3 识别与恢复代码及账本，不删除/降级已有组织、创建或上传事实。回退客户端不会撤销已完成的远端相簿成员，也不能把 sending/unknown 直接重排为安全新关系。
