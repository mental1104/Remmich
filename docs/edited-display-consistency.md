# 编辑结果、原片与离线副本

本修复接续可视编辑 `ee01628`，并消费 root 的严格编辑文档契约 `5832e5c`（本分支为 `3d5552b`）。它不修改服务端/API、SQL schema、原片、生产配置或 workflow；新增 Swift 测试仍等待统一 macOS CI。

## 请求与缓存边界

普通远程浏览与对应派生规格下载现在明确请求 `GET /assets/:id/thumbnail?size=thumbnail|preview|fullsize&edited=true`。编辑页继续明确 `edited=false`，独立于普通图片、Saved Photos 和导出 manifest。原片 `/assets/:id/original`、视频播放和显式原片分享保持既有查询与回退约束。

普通展示使用新 `server-edited-v1` Nuke 身份，额外保留 Date 精度；同秒不同 updatedAt 不能命中同一派生预览。导出 manifest 记录实际 ImageRequest 身份，派生规格只读取新模式的缓存键；原片/播放仍接受原有键。Nuke 的 `imageID` 同时决定缓存与请求合并，参见 [ImageRequest 源码](https://github.com/kean/Nuke/blob/main/Sources/Nuke/ImageRequest.swift)。

持久缩略图下载和队列预取共用 edited=true URL。新文件名 `edited-v1-<asset>-<milliseconds>.bin` 区分旧缓存；旧文件和 SQL 行不自动删除。warm/完成统计额外核对文件名的毫秒版本；旧记录由正常 warm/rebuild 替换。可用/已索引 manifest 拒绝旧无模式文件。冷恢复队列拒绝旧未编辑完成体，并在预取时取消、替换该资产旧 cache 配对。原片导出、账户/路由生命周期不变。

## 保存到手机的来源标记

`MediaExportJob` 和 `MediaPhotosReceipt` 添加 optional `sourceMode`：`original`、`editedDisplay`、`playback`。SQLite 仍存同一个 journal JSON，没有数据库迁移。历史缺失字段保持 nil，既不猜测为已编辑，也不删除。

新任务记录实际选择的请求模式，Photos 成功后回执只复制任务已知模式。冷恢复旧任务不被追认。`editedDisplay` 代表明确请求 edited=true，**不保证服务器当时已完成异步派生图**。

普通 thumbnail/preview/fullsize 只复用同资产、版本、规格且 sourceMode=editedDisplay 的本地 Photos 回执。新的编辑派生保存仍可离线复用；原片不能替代普通编辑展示。历史未知副本继续存在于显式 Saved Photos 入口，显式原片仍可离线使用旧原片回执。已有未知副本阻止自动重复导入，并显示说明，不静默创建手机重复照片。

## 异步派生与刷新边界

真实服务端顺序为 `AssetService.editAsset/removeAssetEdits → AssetEditRepository.replaceAll → 排 AssetEditThumbnailGeneration → HTTP 回执`。asset_edit 的 insert/delete 触发器更新 asset.isEdited；派生文件和 asset.width/height 在 `MediaService.generateAssetEditThumbnails` 后续任务中才更新。`getForThumbnail(edited=true)` 优先已编辑文件，缺少时仍可回落未编辑文件。因此 HTTP 成功不能证明渲染完成，客户端没有额外生成完成 API，也没有伪造状态。

实际读取到后续 updatedAt 后，新远程身份和持久 warm 的毫秒文件版本会拒绝中间缓存。查看器实际图片 metadata 决定最终显示比例，不从原始 EXIF 猜裁剪比例，也不修改 Timeline 模型。root 仍需刷新查看器独立的 AssetViewerSession 快照；现有管理回调只刷 detail、AppShell 只触发一次 sync，可能早于派生完成。该集成与实际异步时序验收未完成，不能称端到端编辑验收通过。

索引 sourceRevision 字符串保留既有不带小数 ISO 契约，避免越界改写所有消费者。新文件名检查和远程缓存补足本路径；没有声称已修复所有索引子秒精度、所有中间版本的完成判定或原子编辑竞争。

## 验证与回退

新增/更新 Swift 测试走真实 Nuke、SQLite、媒体控制器和持久队列模型：展示 URL/身份、编辑/未编辑合成字节隔离、旧缓存拒绝、同秒版本重读、新模式冷恢复、legacy unknown、原片不遮盖展示、旧缩略图保留及队列旧完成体替换。queue fixture 使用 cacheAllowed=false 与空 nativeTasksProvider，图片 fixture 使用局部 DataLoading，不发真实网络或访问 Photos。

NAS 实际检查为 11 个受影响 Swift 文件 SwiftFormat 0.64.5 scoped lint 与 diff 检查。Swift 编译、所有新增/更新测试、模拟器画面、真实异步渲染、iPhone/iPad 真机及官方客户端共存均未执行，交 root 统一 CI 与后续设备验收。

回退此提交不影响服务器编辑、原片或手机副本。旧客户端忽略可选 JSON 字段，新模式文件可留待正常缓存清理。没有 SQL migration、生产变更或自动照片删除需要回滚。
