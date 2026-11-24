# 可视无损编辑切片

本切片基于 Remmich PR7 `364a54f` 与 root 提供的共享资产契约 `4a01d68`（本分支 cherry-pick 为 `0db0488`）。Remmich 上游仍为 `672f02e`，没有同步上游、修改服务端、数据库或生产图库，也没有触发新的 CI。它只推进阶段 3，不代表整个 iPad 阶段完成。

## 行为和入口

原查看器的“编辑与管理 → 无损编辑”进入新 `Features/Editing/AssetEditingView`。`AssetManagementView` 保留原管理功能；root 需要在 `AssetViewerView` 的调用处传入 `media: media, previewRevision: asset.thumbnailRevision`。旧调用仍能编译，但缺少真实媒体控制器时编辑页明确失败，不能盲保存。

- 真实有限预览、原图/结果对照；只在内存中调整参数，不覆盖原片。
- 选框内部拖动、四角缩放、双指捏合，始终落到合法整数像素。精确 Stepper 提供不依赖手势的操作。
- 顺时针/逆时针旋转、水平/垂直镜像，按当前可见结果的轴操作。清除调整使用官方 reset 接口。
- 宽度至少 760 点时并排展示原图选框与结果，较窄窗口上下排列；窗口尺寸变化只重设手势锚点，像素草稿不变。
- 44 点角柄支持指针悬停；Escape 取消、Cmd-S 确认保存、Cmd-[ / Cmd-] 旋转。取消、重新读取和写入分别有明确确认，未保存草稿阻止手势关闭。

## 源身份与官方契约

读取真实 `GET /assets/:id` 和 `GET /assets/:id/edits`，使用当前响应中的 owner、checksum、updatedAt、原始文件名及方向校正尺寸固定草稿。EXIF orientation 为 5/6/7/8/90/-90 时交换宽高，规则来自服务端 `getDimensions`。缺失尺寸或不透明版本、视频、Live Photo、GIF、SVG、INSP、EQUIRECTANGULAR 全景均禁止此静态编辑器；不借用演示图片或公共网络。

`MediaLibraryController.uneditedEditorPreviewRequest` 只在当前已验证路由、同账号远程媒体模式下构造：

`GET /assets/:id/thumbnail?size=preview&edited=false`

它沿用现有 Bearer 会话和受限 Nuke pipeline，最大目标解码尺寸 2048×2048，使用独立 `editor-original|...|checksum|updatedAt|dimensions` 缓存身份。它不复用普通浏览或 SavedPhotos 图片、不注册导出回执、不下载原片。预览方向实际展开，比例明显不符时停止编辑，禁止拉伸假装正确。

预览载入后、恢复前台和保存前均重新读取源版本及完整的当前编辑列表。任一账号/路由代际变化、查看器资源 revision 变化、源或编辑变化使旧预览及提交失效。版本变化保留可见草稿的值，只有显式重载/退出才丢弃；旧异步结果不能重新发布。写入失败后必须重新读取，防止服务端可能已经接受请求时盲目重发。

保存仍为官方 `PUT /assets/:id/edits`（200），清除仍为 `DELETE /assets/:id/edits`（204），服务端仍决定资产权限及媒体支持。方法依据当前 `server/src/controllers/asset.controller.ts:237` 与 `LibraryMutationClient.saveEdits`，没有编辑 POST 路由。裁剪第一项、坐标属于方向校正后的原图，后续旋转/镜像做八种正交变换的等价归一化；不会简单重排不交换的操作。当前固定官方契约外的 action、重复操作、错误参数和越界裁剪整组拒绝。root 的 `5832e5c` 已补充严格解码与 GET assetId 核对，拒绝未知 JSON 行为字段，不将未来参数部分丢弃后覆盖。

服务端没有原子比较并写入或编辑版本 CAS：重读与写入之间仍存在并发窗口。本客户端不声称消除所有同时编辑竞争，也不会修改官方 API 来制造此保证。后续已补普通派生图 edited=true 与离线来源标记，异步生成/查看器刷新边界见 [编辑显示一致性](edited-display-consistency.md)，不能把写入成功当渲染完成。

## 实际证据

已对照当前服务端源代码：`editing.dto.ts`、`asset.service.ts`、`asset.util.ts`、`transform.ts` 与 `media.repository.ts`。后两者 Git blob 分别为 `a5bfb2c779fca402e4987bc242859d9c0bf5d0de`、`da9abc2ee379a90d373fa4195ec72081dc1173b7`。服务端 compose 原数组顺序、负角旋转、horizontal→flipY / vertical→flipX，再以 `[[a,b],[c,d]]` 传入 Sharp；实际可见的 90 度为顺时针、270 度为逆时针。

2026-11-24 在隔离服务端开发依赖中，用 Node 22.22.3、Sharp 0.35.5 和真实 transformation-matrix 运行 9 个合成色块场景。未启动 Immich、访问数据库、网络或照片。输入为 60×40 像素，六个 20×20 灰块：`[[1,2,3],[4,5,6]]`，只采样块中心。

| 场景 | 实际结果 |
| --- | --- |
| 无调整 | `[[1,2,3],[4,5,6]]` |
| 90 / 180 / 270 度 | `[[4,1],[5,2],[6,3]]` / `[[6,5,4],[3,2,1]]` / `[[3,6],[2,5],[1,4]]` |
| 水平 / 垂直镜像 | `[[3,2,1],[6,5,4]]` / `[[4,5,6],[1,2,3]]` |
| 水平镜像再 90 度 | `[[6,3],[5,2],[4,1]]` |
| 90 度再水平镜像 | `[[1,4],[2,5],[3,6]]` |
| x=20、y=0、40×40 裁剪，再 90 度和水平镜像 | `[[2,5],[3,6]]` |

NAS 临时复现脚本 `/tmp/remmich-editor-sharp-golden.mjs`，报告 `/tmp/remmich-editor-sharp-golden.json`。依赖根目录为 `/volume2/code/worktrees/immich-nas-dev/remmich-parallel-server-build/server`。该证据只验证官方图像操作的语义，不等于 SwiftUI 渲染通过。

新增 Swift Tests 覆盖 EXIF、边界与非法浮点、宽窄窗口映射、原始参数导入/等价归一化/拒绝、资源版本、实际 DTO 解码、UIKit 色块与方向校正、产品 SwiftUI ImageRenderer 裁剪及原图对照。真实媒体控制器请求测试检查前缀路径、GET/Bearer、edited=false、独立缓存、换账号和缺路由拒绝；所有网络读取由局部无网络 loader 阻断，没有全局 URLProtocol 注册。

实际通过：9 个 Sharp 色块断言；9 个受影响 Swift 文件的 SwiftFormat 0.64.5 scoped lint；`git diff --check`。NAS 没有 Swift/Xcode，新增 Swift Tests、app 编译、ImageRenderer 像素断言和 UI 交互均**未执行**，由 root 合并后统一 macOS CI 验证。iPhone 15 Pro / iPad Pro 2022 11 英寸真机、官方客户端共存、真实照片编辑效果、手势与键盘/指针体验仍未验收。

## 后续与回退

阶段 3 还需要普通查看器 edited 资源闭环、派生版本刷新，以及全应用 iPad 多任务/尺寸变化、键盘/指针、Dynamic Type、无障碍和设备验收。本切片不把搜索 UI 测试或 API Schema 检查当成编辑验收。

可独立 revert 本客户端编辑切片，恢复旧表单或暂时隐藏入口；不会恢复或删除已保存的官方服务端编辑。恢复原图应由用户明确使用现有 reset 操作，原始照片始终保留。未修改生产配置，也没有任何迁移需回滚。
