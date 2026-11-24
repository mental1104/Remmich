# 设备本地与Immich资产匹配、本地优先浏览

2026-11-24用户明确：这里的“云端”是Immich。设备Photos与服务器有大量交集，目标是关联两端资产，在缩略图、放大图片和播放时优先读设备已有媒体，避免重复请求Immich图片/视频。不是仅优化备份查重，也不是要求每次先下载iCloud原片。

服务器仍允许同步索引、关联元数据及必要的fresh资产状态。匹配后媒体数据走本机；本机当前授权/版本/资源不可读时才回退远端。不能用本机旧照片掩盖Immich独立无损编辑，不把关联当作备份完成或删除设备原片的证据。

## 已核官方实现

- `mobile/lib/infrastructure/repositories/local_asset.repository.dart:222` 的 `reconcileHashesFromCloudId` 在完整cloud ID、createdAt、adjustmentTime、latitude、longitude逐项相等时复用远端checksum；`hash.service`先进行这一步。
- 官方mobile-app metadata wire key为 `iCloudId`。日期为ISO字符串，坐标为字符串；官方encoder省略nil字段。不能将坏日期/坐标解析成nil再匹配，不能从cloud ID字符串拆出或推算内容哈希。
- 当前v3.4.2服务端没有旧版device-check映射接口。不能凭不同App的设备ID或本机localIdentifier推断服务器已有备份。
- 官方 `POST /api/sync/stream` 的 `AssetMetadataV1` 提供本人metadata JSONL；真实信封为 `{type,data,ack}`。读取不需要请求任何图片/视频。`reset`会修改会话进度，本功能不发送；也不提交ack或SyncComplete确认。

## 当前整合状态

匹配、PhotoKit current读取、本机SHA1查重、按账号原子持久化、设置入口和真实媒体路径现已整合。账号设置的“匹配本机照片与视频”首次由用户启用并授权；以后启动/回前台恢复关联，已有权限下自动刷新，照片库变化会使旧关联失效并合并重扫。没有后台备份、上传或生产变更。

普通图片的缩略图/预览/大图及普通视频优先使用已确认的同版本本机资源。本机miss、权限变化或本机超时回退原有Immich缓存/远端；取消、换号或端点代际变化直接停止。原片导出仍走明确原片通道；Live Photo本轮只支持本机静态帧，动态播放仍走既有路径。服务端独立编辑、RAW+JPEG或无法证明的资源不会猜测关联。

元数据流不可用、已有检查点或不完整时不发布其部分候选，仍可继续独立本机SHA1匹配，并显示降级警示。外置库依赖当前Fork已有的target库与内容指纹就绪；本次只在隔离合成库验证此条件，不推断或更改生产配置。

NAS全仓SwiftFormat检查通过；新的Swift编译/逻辑/路由测试尚未执行，不能据此宣称验收通过。协议与服务端证据分别见[元数据流](local-media-metadata-http-acceptance-20261124.md)、[普通资产查重](local-media-checksum-http-acceptance.md)及[外置库代表资产](local-media-external-http-acceptance.md)。真实PhotoKit权限/内容及设备显示播放仍需真机验收。

## 元数据读取基础

- `LibraryMutationClient.localMediaMetadata(cloudIDs:)`：通过现有无cookie/cache/redirect会话读取 `GET /sync/ack`，只在没有metadata检查点时读取完整metadata流；空输入不联网。只保留本轮本机cloud ID对应的mobile-app记录。
- `LocalMediaMetadataStreamDecoder`：逐字节处理UTF8/JSONL，限制单行/响应大小，保留重复候选供歧义判定。只有收到SyncComplete且HTTP正常EOF、没有残行后才返回候选；SyncReset、截断、未知协议、过界均失败，不返回部分结果。
- `LocalMediaMetadataStreamTests`：11个测试函数/17个参数化case，涵盖UTF8、精确opaque ID、重复候选、过滤、删除历史、EOF/残行、reset、坏协议、终止后多行、双重上限及元数据增量检查点。

以上是底层协议组件，现已接入上面的完整候选。Swift编译/测试尚未执行；独立分支基线424a22a的CI结果不适用于这些新代码。

## 整合行为与验收边界

1. PhotoKit只读身份/版本快照与cloud ID批量映射，以及精确nullable元组匹配。不同设备的localIdentifier不能共用，完整cloud ID在同Photos库映射。没有官方关联信息的NAS导入照片仍需可信checksum或后续明确的匹配证据；文件名/日期相似不能直接确认。
2. 对候选fresh读取所属账号、回收站/offline、媒体类型、checksum及Immich编辑状态，再发布绑定账号/端点/本机版本的映射；删除/修改/换号立即失效。
3. 在现有MediaLibraryController图片/视频路径优先尝试PhotoKit current版本，关闭原片网络获取；本机不可读再使用原远端路径，保持取消、缓存身份及原生播放器。Live Photo静态命中不等于动态配对也已确认。
4. 合成HTTP/逻辑断言须证明：匹配和fresh元数据读取窗口没有original/thumbnail/preview/video请求；实际本地渲染命中后媒体请求为零；本机缺失/权限撤销/版本变更可回退；跨账号迟到值拒绝；服务器已编辑显示正确版本。

真正PhotoKit权限、设备上可用媒体、视频/Live Photo播放、iPad与内存性能仍需设备验收。公开cloud ID映射可能涉及系统元数据网络，不能承诺设备零网络；目标是避免重复下载Immich媒体。

现有metadata检查点或SyncReset会禁用本轮元数据证明并显示警示，继续独立校验和路径；不会自动重置会话。后续持久增量关联必须在本地原子保存后再推进其独立metadata游标，并且不能伪造原片备份的确认。

回退本独立代码即可；没有服务端/API/schema/生产/照片写入，不删除任何媒体或用户恢复资料。
