# 本机字节SHA1匹配HTTP验收

本记录保留当时普通上传范围；随后补充的[外置库验收](local-media-external-http-acceptance.md)独立验证了target库指纹就绪后的代表资产合同。

2026-11-24，独立验收客户端commit `288ed847af50709557ccb5bff4744fc207bb4a13` 所依赖的官方bulk precheck合同。实际HTTP通过独立curl客户端容器，未运行Swift/PhotoKit，不能代替本地优先UI、播放或设备验收。

结论：**同owner的普通已上传资产，即使完全没有mobile-app元数据，也可由本机已知字节SHA1得到精确duplicate/assetId/isTrashed回执。** 当前NAS外部库的content/backup/client指纹兼容路径尚未在本轮配置/运行验证，不能用普通上传证据宣称该路径已通过。

## 对象与隔离

- 实际服务：已缓存受信镜像 `sha256:7310097df26f44abf163771913abd5cbfd5d6b93018a8adb66d2238b723ca223`，revision `c15f4ca09a26ae1dc905e351dedc79579f63960a`。不是当前父dev源码的重新构建或部署。
- 唯一project `remmich-checksum-20261124-zn7hgq`，全新PG、Valkey、媒体目录、两个合成用户；四容器仅接同一internal网络 `10.245.24.112/28`，没有宿主端口、生产卷或外网。逐容器inspect和网络证据均保存。
- 准备阶段：4个真实合成照片/视频multipart上传，另一个合成照片仅留客户端未上传；每项独立核JPEG边界或movie ftyp、源bytes/SHA1/Base64/SHA256、fresh owner/type/checksum和空metadata。将其中一个己方资产移入回收站。没有写mobile-app或其他metadata。
- 安全证据归档：`/tmp/remmich-checksum-http-20261124-vENQWd/report.md`；旁边保留合成样本、原始HTTP headers/body、完整请求账本、断言、日志、边界与cleanup记录。

## 请求与结果

实际44个HTTP：19准备请求、3个匹配窗口共22请求、3个未鉴权请求。92个记录断言中90通过，保留2个最初探测假设与实际服务相反的失败；更正后的实际行为单独断言，未删失败、未改旧回执。必需的有效输入匹配/owner/媒体读取边界没有发现失败。

| 实际场景 | 真实结果 |
|---|---|
| owner无mobile-app的照片/视频SHA1 | POST `/api/assets/bulk-upload-check` 精确200；每nonce有`reject/duplicate`、对应assetId、明确`isTrashed:false` |
| owner已回收站的照片 | 200 duplicate，明确`isTrashed:true`，不能当正常关联 |
| 未上传bytes、仅另一owner拥有的bytes | 200 `accept`，仅id/action；未上传任何新媒体 |
| 两owner各自查询/详情 | 只查到自己的duplicate；另一owner详情400；无Bearer的bulk/detail/ack均401 |
| 相同SHA1、不同nonce；64项同SHA1未命中 | 每项完整回执，顺序对应；不会合并丢失某个本机对象 |
| 同nonce重复发送 | 服务照原输入返回两项相同nonce；客户端独立禁止这种输入并拒绝不唯一响应 |
| SHA1十六进制、同20字节Base64 | 两种值均200命中相同资产；新客户端只发送严格小写40位hex |
| 空assets探测 | **500**，正文`Failed to check bulk upload`；最初预期空200错误，失败已保留。客户端空批次直接返回[]，不会发送 |
| 非法checksum探测 | **200 accept**；最初预期400错误，失败已保留。客户端LocalPhotoByteDigest边界会拒绝非法digest，不能依赖此镜像校验 |
| 前后GET `/api/sync/ack` | 三窗口均[]且逐字不变，没有ACK/reset/同步进度更改 |

每个只读窗口白名单只有POST bulk-upload-check、GET资产详情、GET sync/ack。全44请求中**零original/thumbnail/preview媒体下载、零metadata写、零ACK/reset**；唯一媒体传输是准备阶段四个合成上传。GET详情明确核owner/type/Base64SHA1、false offline/edited、trash及null LivePhoto关联字段。详情checksum与独立源字节摘要相等是元数据证据，没有因此伪称下载原片比对或设备资源已可用。

## 版本与未验边界

源码对照：父Fork `asset.repository.getByChecksums` 在现有iPhone backup配置有效时才让指定目标库coalesce(backupChecksum,contentChecksum)参与，代表排序可优先clientChecksum。`asset-response.dto`公开checksum却是在线clientChecksum或旧checksum，**不会直接下发contentChecksum**。因此外部库可能precheck命中、fresh checksum仍不足以与本地bytes相等；本片没有设置配置/指纹、没有暗写clientChecksum、没有放宽fresh检查。

本轮未验证：当前父源码服务构建、外部库扫描/指纹准备及其checksum形状、真实Photos current/云端only/取消回调、Swift51声明场景执行、自动匹配Controller、iPhone/iPad本地显示或视频播放、生产/官方客户端共存。SHA1查询只是候选关联，不是备份完成、远端唯一性或手机清理凭据。

## 回收

服务日志先归档脱敏，再compose down完成。核实本project容器/网络及tools残留均0、没有匿名卷；只删除本次新DB/Valkey/media/client-data和临时env/账号/Bearer文件。92个证据文件扫描5个临时秘密均无泄露。没有检查或修改生产容器、网络、env、凭据、媒体或图库。
