# 查看器编辑后刷新

本切片接续 `ee01628`、`be0a181`、`494bb1c`，收口本轮阶段 3 范围。只接 Remmich 原生管理/查看器、单张真实读取和相关测试；没有服务端/API/schema/数据库迁移、生产、workflow、push 或 CI 触发。

## 当前真实契约

- `server/src/controllers/asset.controller.ts` 使用 `PUT /assets/:id/edits`，清除为 DELETE。参数成功和异步派生完成是两件事。
- `GET /assets/:id` 返回真实 updatedAt、width/height、thumbhash、收藏/可见性等，没有本次编辑的派生 ready 标记。尺寸或 isEdited 变化不能证明这次编辑已渲染。
- Fork `taskStatuses` 的映射 `server/src/services/job.service.ts:getAssetTaskName` 包括 AssetGenerateThumbnails，**不包括** AssetEditThumbnailGeneration，不能借它的 thumbnailGeneration completed 推断编辑完成。
- `GET /jobs` 是需管理员权限的全局队列统计，不能证明某张某版本图片已完成。
- 官方 Web 在请求前监听 `AssetEditReadyV2`，限时 10 秒；事件在 `JobService.onDone` 的编辑分支发送。当前 Remmich 没有 Socket.IO transport，本切片不引入新的通用连接/依赖，也不伪造该事件。

## 可操作闭环

查看器已给 AssetManagementView 注入同账号 media 和 thumbnailRevision。编辑/重置成功走专用回调，开始有限读取；其他管理成功或“刷新照片”按钮只读一次。旧管理宿主没有专用回调时仍使用原 changed，不丢刷新通知。

`LibraryMutationClient.freshViewerAsset` 通过现有无 cookie/cache/redirect 的 Bearer 会话直接 GET 当前选中 ID，单请求 timeoutInterval=4 秒，精确200，匹配 UUID/owner、静态 IMAGE、无 Live Photo、有效 updatedAt 才返回。它不读取后台索引缓存/GET 队列，不向 `/jobs` 请求管理员权限。

编辑后最多读取 4 次，相邻读取间隔 1 秒；第一次错误立即停止，无自动重试。每次响应都会用真实字段替换当前 session 的同一资源，保留捕获时间、排序、选中 ID 和原片语义。即使最后读取到新版本，提示仍是“编辑参数已保存。预览可能仍在生成，可再次刷新。”；普通刷新显示已读取当前状态，同样不承诺 ready。错误显示明确可再次刷新，后台恢复不自动启动无限观察。

会话 sourceAssets 和所选 summary 同步更新，晚返回的旧邻居桶不能覆盖直读版本；旧版本也不能反向替换新版本。实际 ZoomableStillImageView 的加载身份包含子秒 revision，版本变更会清掉旧 loadedTargetPixels/像素状态并请求新的 edited=true 预览。最终显示比例仍由实际解码图 metadata 决定，缺服务器尺寸时只保留旧占位比例，不从 EXIF 猜裁剪结果。

切换选择、账户、路由 generation、进入后台、开始关闭或消失均取消刷新。read/publish 前后再次核对 requestID、任务取消及当前上下文，旧响应不能发布到新资源。有限读取不覆盖原片；Saved Photos、视频和 Live Photo 仍使用既有播放/离线读取流程。编辑后的新版本会清掉此前显式原片显示请求，以便回到编辑预览；其他显式原片触发条件不变。

## 实际验证与限制

新增真实 URLSession fixture 检查 GET/路径前缀/Bearer/4秒配置、200与错误状态、ID/owner/类型/版本拒绝、合成超时和显式重试恢复；真实 RefreshController/session 测试检查最多4次、真实管理通道账号/路由切换、选择切换、模拟后台边界、忽略取消的旧read、晚返回旧邻居桶。新增真实 UIKit 宿主测试会修改所用 summary 并检查同秒新版本引发第二个预览请求，没有只比较缓存键而跳过产品 View。

网络 fixture 只在每个 session 注入局部 URLProtocol、按随机 host 隔离；所有请求均拦截，不访问服务端或 Photos。时序由 actor 闸门建立，错误也会释放观察者，避免测试卡死。后台切换的环境回调和 SwiftUI 刷新按钮实际点击仍须 UI/设备验收，不能把状态机测试当成硬件交互通过。

实际 NAS 通过：9 个受影响 Swift 文件 SwiftFormat 0.64.5 scoped lint、`bash -n Scripts/check-fork-contracts.sh`、diff 检查。离线契约脚本只增 Foundation-only DTO 源文件一行，不改检查/触发条件。NAS 没有 Swift/Xcode，新增/更新 Swift 测试、app 编译、真实渲染与 iPhone/iPad/官方客户端共存仍未执行；等待 root 统一候选 CI。有限读取可能结束在旧派生版本，必须允许用户再次刷新；仍不提供服务端原子 CAS 或真正 ready 确认。

回退此客户端切片只撤回桥接/刷新/显示失效逻辑；保留已经保存的官方编辑、原片、手机副本和前面三个切片。没有生产或迁移需要恢复。
