# RAW+JPEG 公开 HTTP 隔离验收

本轮实际执行18个业务请求，验证两份有效合成原片的上传、部分存在、判重、fresh详情与四次原片下载。结果通过，但没有执行Swift Worker、SQLite恢复或Photos；不将本轮HTTP证据替代新增36个客户端场景。

## 对象与边界

- 固定缓存镜像 `sha256:7310097df26f44abf163771913abd5cbfd5d6b93018a8adb66d2238b723ca223`，没有pull或构建。继承OCI标签不是应用Git提交收据，不能将其当作当前dev源码构建。
- 新project `remmich-raw-jpeg-20261125-ifb8p3`，独立PostgreSQL、Valkey和媒体目录，独立internal网络 `10.245.25.128/28`，无宿主端口及外部网络。创建后、启动前实际检查所有挂载仅位于本任务目录。
- 通过新server容器loopback curl执行公开HTTP/multipart；首个管理员与数据库凭据均为本轮随机合成值，以0600临时文件保存，不复用生产配置、账户或照片。仅新测试库首次启动迁移。
- 夹具由数学RGGB渐变生成CFA DNG，按[Adobe DNG规范](https://helpx.adobe.com/content/dam/help/en/photoshop/pdf/DNG_Spec_1_7_1_0.pdf)使用早期兼容标签。独立FFprobe识别 `bayer_rggb16le`，FFmpeg实际解码为9216字节RGB，并由同一RAW生成及验证JPEG；不是改扩展名或文本假媒体，也不声称完整Adobe SDK认证。工具容器均network none。

## 实际结果

| 行为 | 实际观察 |
| --- | --- |
| 上传 | DNG6768字节、JPEG348字节，以octet-stream及原文件名真实multipart上传，无deviceAssetId/deviceId |
| 部分存在 | 先仅DNG成功；precheck为DNG重复、JPEG可接受，随后补齐JPEG |
| fresh确认 | 五次IMAGE详情均匹配UUID、owner、非trash、原始规范Base64 SHA1及明确isOffline=false |
| 双重复 | 两轮precheck均返回两份对应的相同远端ID，未把第二份忽略 |
| 原片 | 四次GET original?edited=false下载与各自源文件逐字节相同，SHA256相同 |
| 既有关联 | 有效合成H264 MOV先上传，JPEG初次上传关联该motion；双图确认后关联保持，未发送PUT/PATCH/DELETE |
| 回收 | 本项目三个容器和唯一标签网络均移除，六份明文凭据回收；源、结果及独立测试bind数据保留 |

| 文件 | 字节 | 源与下载相同的SHA256 |
| --- | ---: | --- |
| original.dng | 6768 | a03d0b7407eaec78b987cb6b68132dfe7ef0ffa4960e11032b36d2a3d2ae62bd |
| original.jpg | 348 | 0dd1a2bc52891c2ebf7d2d83bfc552b5dc6ad5f3574619f0e6e72660fb7d8948 |

## 证据与限制

持久任务目录为 `/volume2/codex-home/mental1104/tmp/remmich-raw-jpeg-http-20261125.Ifb8P3/`。`build-fixtures.cjs`、`validate-fixtures.cjs`及独立HTTP/审计脚本保留；`evidence/`含原始body/headers、fixture-validation、summary、http-results、partial、mount/network边界、service.log、cleanup和independent-audit。独立审计重读全部18响应、五次fresh与四次下载，并再次核对项目不存在及脱敏。

首次离线工具调用因NAS不支持Docker CPU CFS配额而在运行前失败，已保留记录；随后只使用原内存限制及FFmpeg线程限制，未改宿主内核。服务原日志保留新库初始化警告及建表前system_metadata查询错误。Compose进度在工具stderr，空stdout日志不作为启动/回收凭据，实际边界及清理JSON另存。

未验证Swift客户端实际调用、断网后的客户端冷恢复、PhotoKit双原图选择、iCloud、设备、当前dev镜像及RAW派生图完整处理。回退代码时保留格式3和部分回执，不能删除已上传原片或用旧空队列覆盖恢复资料。
