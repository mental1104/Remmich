# 明确继续未尝试尾队列

来源：独立分支 `codex/feature-backup-unattempted-recovery`，固定基线 `6b3885bcff4b2c870220f1cb9661486b7ae76a89`。只补前台队列恢复入口，未推送、触发 CI、合入 dev、改父 gitlink 或生产。依赖此前保存相簿排除、RAW+JPEG 和前台自动备份源码；这些依赖的 Swift/真机验收状态不能由本片推断。

## 源码证据与本片行为

| 已有行为 | 证据入口 | 本片变化 |
| --- | --- | --- |
| 网络/未确认回执使当前项失败，并暂停后续排队项 | `PhotoBackupWorker.run` 的 failure/requiresStop/pausePhotoBackupWork 路径 | 失败与未知项保留；明确操作只继续其后安全未尝试项 |
| 冷 load 仅把 in-flight 恢复为 paused，不上传 | `PhotoBackupController.load`、`PhotoBackupJournal.recoverInterrupted` | 保留此行为，恢复仍须用户明确点击 |
| 原“继续”将 paused/failed 排队；单项继续只排指定任务 | `resumeForVerification`、`PhotoBackupController.resume` | 原全部/单项明确核查语义保留，执行体与新模式共用同一 Worker/Coordinator |
| 前台自动遇失败/未知会关闭规则，后台只取消 | 前一片 `launchAutomaticWork` | 本入口不重开自动规则，也不承诺自动网络恢复或 OS 后台调度 |

“仅继续未尝试项目”按钮及确认框展示待核对的最多处理数量，并分别显示失败、已尝试/回执待核查、取消和完成的跳过数量。它先重新读取当前账号 SQLite，再按明确保存的包含/排除集合完整重扫；已有 Photos 授权不足、排除相簿失效、未保存草稿或源快照不一致均在上传前停止。实际符合保存规则的数量可以低于提示上限，绝不靠失效的空排除扩大范围；不会把新照片偷偷加入这次尾队列。

只有 queued/paused、`attempts == 0`、无失败、无主体/动态或 RAW/JPEG 回执、且同 localID 没有取消/失败/未完成尝试历史的既有任务可继续。手动重排不会清零尝试次数或清除回执，不能借 queued 状态伪装未尝试。仍符合源版本的安全项才排队；已经移出或被排除的安全未尝试项取消本地任务。失败、取消、完成和已尝试暂停的事实原样保留；被手动重排为 queued 的未知项安全暂停，不能让 Worker 顺带重发。

恢复使用已保存 `allowCloud`，不保存页面草稿，不默许下载 iCloud 原片。原单项明确重试仍重新导出当前源、计算实际完整 SHA1、请求官方查重并执行 fresh GET/必要配对核对；旧 UUID 或部分回执不充当成功。用户取消及未知结果没有自动重放路径。所有执行继续由唯一 `PhotoBackupRunCoordinator`、原 Worker、真实上传客户端和账号 SQLite 持有。

## 验证边界

新增 `Explicit unattempted backup recovery` 测试组：6 个函数 / 7 个声明场景，整文件合计 23 个函数 / 27 个声明场景。包含领域摘要/队列保留，以及真实 Controller → Coordinator → Worker → URLSession/LibraryMutationClient → SQLite 的隔离序列：503 后关闭自动规则 → 新 SQLite/Controller 冷读 → 只继续未尝试尾项 → 用户明确单项重试才重新查重/fresh 回读旧失败项。另有权限/失效排除、真实导出 await 取消后恢复尾项、未保存草稿、await 中撤权后保留未知项。只替换系统源/字节和有限 HTTP 边界，未伪造成功行；取消门与失败清理不依赖 sleep。503 是合成 HTTP 不可用证据设计，不能称为真实设备物理断网验收。

| 关口 | 实际结果 | 完成比例 |
| --- | --- | ---: |
| 实现 | 明确恢复入口、数量/原因、保守计划、原全部/单项路径共用执行体 | 25/25 |
| NAS 静态 | SwiftFormat0.64.5 工作流同范围：0/381 需改、1 个既有 skip；diff 检查通过 | 25/25 |
| Swift 运行 | 新测试未执行；`bash Scripts/check-fork-contracts.sh` 实际退出127，原因 `swiftc: command not found` | 0/25 |
| 集成 | 没有新 CI、dev 整合、Photos/iCloud 或设备验收 | 0/25 |

本片没有服务端 API、SDK、SQL Schema 或日志格式迁移；静态结果不证明 Swift 6 类型检查、运行断言或官方客户端共存通过。后续仍需实际 Swift/CI 执行及有限照片集设备验收。前台自动重连恢复、未知结果自动 fresh 协调、网络条件策略和 OS 后台调度仍属后续独立要求，本片不能替代总体恢复目标。

回退本片源码时保留既有 SQLite 和部分回执；只恢复为原明确全部/单项重试入口，不删除服务器资产或设备原片。前一片的自动备份开关及格式3恢复要求仍然适用。
