# 本地媒体匹配的 metadata 同步 HTTP 验收

目标是设备已有照片与 **Immich** 对应，之后浏览/放大/播放优先读取本地，避免重新下载 Immich 媒体。`iCloudId` 只是官方 `mobile-app` metadata 的协议键名；本轮没有访问 iCloud，也不把关联、SyncComplete 或校验和读取当成备份完成/手机清理证据。

本轮 **58 次真实 HTTP，其中四个匹配读取窗口共30次**。窗口内只出现 `GET /sync/ack`、`POST /sync/stream` 和 `GET /assets/:id`；整个实验媒体 GET、ACK 修改、reset payload 均为0。**281条记录断言：280通过，1条准备夹具错误保留**：最初错误比较 JSONB 对象键序，改为结构化深比较后复核了原回执，没有重发已成功的账号/上传/metadata 写入。没有服务合同失败。

## 服务与隔离边界

- 全新 project `remmich-match-20261124-umzu3t`，server、独立 curl client、PG、Valkey 全部新建；仅新内部网络 `10.245.24.96/28`，四容器各只有该网，全部挂载位于新私有任务目录，无宿主端口。没有读取生产容器/网络/env/凭据/图库。
- 只复用缓存受信镜像 `sha256:7310097df26f44abf163771913abd5cbfd5d6b93018a8adb66d2238b723ca223`、revision `c15f4ca09a26ae1dc905e351dedc79579f63960a`。PG/Valkey镜像与前次隔离验收相同，库/队列/目录没有复用。未 pull、构建、发布、push、触发CI或修改PR8。
- 本地协议参考源码头 `4c7a3d7987f9b4f2ae54c64bfe12e6a777b632a3`：`utils/sync.ts`、`sync.controller.ts`/DTO/service、`asset.controller.ts`/DTO，以及官方 `mobile/lib/domain/models/asset/asset_metadata.model.dart`、`infrastructure/repositories/local_asset.repository.dart`。**运行的是缓存镜像，不是该源码头的新构建。**
- 两个全新合成账号，FFmpeg生成八张64×48 JPEG和一个1秒MOV，9个资源；其中一个JPEG归另一账号，另有hidden motion与带其 `livePhotoVideoId` 的逻辑still。没有真实媒体/云标识/拍摄位置，也没有PhotoKit Live Photo配对验收。

## 真实请求与数据合同

准备阶段允许注册、上传与写入：`PUT /api/assets/:id/metadata` body 为 `{"items":[{"key":"mobile-app","value":{...}}]}`，200返回实际记录数组；删除该键为 `DELETE /api/assets/:id/metadata/mobile-app` 204。这些写入均明确标记 preparation，未混入匹配窗口。

官方 MobileApp wire value 使用 **`iCloudId`**（大小写准确），完整 opaque 字符串；`createdAt`/`adjustmentTime` 是 ISO 字符串，latitude/longitude 是字符串。官方 Dart nil 值省略键。本轮保存例如带 `/`、`+`、`==`、`/L0/001` 的完整合成ID、日期 `2026-02-16T05:06:07.123+05:45` 和坐标字符串 `0.000000` / `120.500000`，JSONL保持原始字符串，未数值化、截断或规范化日期。

| 场景 | 实际结果及客户端要求 |
| --- | --- |
| stream请求 | `POST /api/sync/stream`，body **只有** `{"types":["AssetMetadataV1"]}`，200、`application/jsonlines+json`；未传reset |
| JSONL外壳 | 每行恰好 **`{type,data,ack}`**，不是ids；ack是opaque进度标记，不能当资源ID，也未发回服务器 |
| upsert行 | type=`AssetMetadataV1`；data=`{assetId,key,value}`，value是JSON对象；没有ownerId字段，owner由服务端认证范围保证，候选仍需fresh详情核owner |
| 删除行 | type=`AssetMetadataDeleteV1`；data=`{assetId,key}`。不能忽略删除后继续使用旧关联 |
| 终止 | 每个成功流最后恰好一个 `SyncCompleteV1`、data={}；JSONL以换行结束。本轮从未ACK此标记 |
| owner隔离 | owner流不含另一账号记录；另账号流仅自己的1条。对方详情GET本轮400；匿名stream、ack、详情均401 |
| 重复iCloudId | 两个自有资源即使五个MobileApp值完全相同，仍返回两条不同assetId，且源文件checksum不同；服务端没有唯一化。另账号同值不会进入owner流 |
| 缺键 | 先写完整对象再只写createdAt，结果只剩createdAt；**value整对象替换，不merge旧字段**。消费者不得从旧快照补回iCloudId/位置/修改时间 |
| 显式null | 另一样本的adjustmentTime/latitude/longitude明确null，JSONL保持null；与缺键有原始JSON区别，不伪造字符串或数值 |
| 非mobile-app键 | 流还包含 `synthetic-unrelated`，其value也能含iCloudId；必须严格过滤key，不能仅检查值内是否有iCloudId |
| 删除后重复读 | 两窗口之间仅在单独preparation阶段删除A的mobile-app；下一流有A删除事件且无A的mobile-app upsert，但A的unrelated键仍在。不能用该键复活旧关联 |
| 不发送ACK的重读 | 同会话再次读流仍返回相同当前metadata及相同记录ack；未推进为已消费，不等于高效增量游标或大账户性能验收 |

## 四个只读匹配窗口

| 窗口 | 请求数 | 实际JSONL |
| --- | ---: | --- |
| owner初次、含匿名/外owner拒绝和8份详情 | 15 | 6条upsert（5条mobile-app＋1条unrelated）、1条删除、1条SyncComplete |
| 另一账号 | 5 | 1条自有upsert、1条SyncComplete；读owner详情拒绝 |
| owner无ACK重复读取 | 4 | 与初次相同的metadata记录；再次fresh详情 |
| owner删除A后 | 6 | 5条upsert（4条mobile-app＋1条unrelated）、2条删除、1条SyncComplete |

每个窗口前后 `GET /sync/ack` 都是 **[]**，精确一致。没有遇到fresh-session SyncReset，因此没有执行任何显式reset对照；不能据此声称已验证老会话要求重置时的生命周期。只读含义是“无写API/ACK/reset调用”，不等于断言服务器完全没有内部会话访问时间等副作用。

13份成功fresh详情逐项核对同UUID/owner、type=IMAGE或VIDEO、`isTrashed=false`、`isOffline=false`、`isEdited=false`；这些键都真实存在。`checksum`是Base64 SHA1，解码20字节，与已知合成源原片的独立Node SHA1相同。`livePhotoVideoId`显式为null，或逻辑still上等于motion UUID。未通过GET original、thumbnail、preview、video或playback核checksum；窗口里没有此类请求，整个实验也没有。

这些字段提供匹配与fresh权限/状态检查的必要信息，**不证明客户端已正确关联设备照片，或已实现本地浏览/放大/播放**。本轮未构造true的trash/offline/edited状态、共享相簿/partner、真实CloudIdentifier、PhotoKit本地可用性、取消/换号、老会话SyncReset或大账户流。

## 证据、回收与后续

归档 `/tmp/remmich-local-match-http-20261124-b5qlPg/`：

- `evidence/http-results.json` 完整58次请求、phase、body及状态；每个同label `.body` / `.headers` 是原始响应，认证响应仅保留脱敏副本。
- 四个 `match-*-stream.jsonl` 是原始JSONL；`read-windows.json` 绑定ACK前后、精确记录及详情；`request-audit.json` 独立重放请求清单，确认30次只读窗口白名单、0媒体GET/ACK修改/reset、请求label唯一。
- `prepared-state.json` 是完整合成样本与源SHA1/SHA256，`image-source.json`、container/network receipt固定镜像/协议边界；`assertions.json` 保留准备期键序误判和后续正确复核，不隐藏失败。
- `service.log` 在回收前归档并脱敏；`cleanup.json` 验证四容器/网络/工具为0，新PG/Valkey/媒体/client-data及全部密码/Bearer/env/header已移除，没有复用或保留测试库。126个证据文件对5个临时秘密值扫描通过。没有全局prune、生产动作或新macOS链。

原任务目录 `/volume2/codex-home/mental1104/tmp/remmich-local-match-http-20261124-UmzU3t/` 也仅保留安全证据、合成夹具与脚本。六个runner的Node语法检查、Compose配置、仓库diff检查通过；脚本有固定project/path守卫，复现需全新项目/目录/随机凭据，不可重新使用本次已删除登录。

后续由客户端只读媒体通路和PhotoKit索引任务处理：按完整owner/session隔离解析mobile-app，严格校验元数据与歧义候选，fresh详情拒绝不适合本地替代的状态，接通本地预览/原片/视频与无网络下载验证。Swift实现、设备运行和官方客户端共存仍未验；本报告不授权备份确认、媒体删除或生产变更。
