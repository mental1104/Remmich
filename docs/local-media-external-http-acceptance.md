# NAS外部库本机字节匹配HTTP验收

2026-11-24，本轮补足普通上传验收不能证明的外部库合同：**target库内容指纹就绪后，官方bulk precheck返回可公开checksum验证的代表资产，现有客户端可以保留严格fresh校验。** 在这组实际条件下，没有出现“bulk选中的asset fresh checksum与本地字节不等”的问题，不需要为此放宽检查或新增API。指纹尚未准备时明确未命中。

安全原始证据：`/tmp/remmich-external-match-http-20261124-9GUDyN/report.md`，包含逐HTTP账本/headers/body、三窗口完整观察、指纹终态、服务重建前后日志、隔离与cleanup收据、纯合成JPEG/MP4。

## 运行对象

- 唯一新project `remmich-external-20261124-0baqql`；全新PG/Valkey/两个合成用户、媒体与配置，四容器仅连internal `10.245.24.128/28`，无宿主端口或外网。逐对象核挂载全部位于本任务新目录。
- 受信缓存镜像 `sha256:7310097df26f44abf163771913abd5cbfd5d6b93018a8adb66d2238b723ca223`，revision `c15f4ca09a26ae1dc905e351dedc79579f63960a`。未构建/发布镜像，不等同当前父dev源码运行验证。
- 两个完全同字节的合成JPEG副本和一个合成MP4，库扫描挂载为只读；MP4在扫描前由离线tools容器从旧合成seed生成，seed随后移出扫描目录。三份文件合计1830字节，没有真实媒体、上传或原片下载。
- 公开API创建own external library，importPath仅`/synthetic-external`，validate成功后scan204；通过真实search发现3个指定资产，不直接插入数据库。
- 初始无target配置且fingerprint scan关闭。随后只重建本project的server一次，加载新API生成的target library UUID/root；保持`UPLOADS_ENABLED=false`、`FINGERPRINT_SCAN=false`。用公开管理员Fork控制面显式启动一次limit10指纹批次，不让普通扫描代替前后对照。

## 真实前后结果

| 时点/对象 | bulk precheck | fresh公开checksum | 解释 |
|---|---|---|---|
| 指纹准备前，3个external asset | 每个nonce精确200 `accept` | 三者均与源字节SHA1不同 | 只有路径checksum不够匹配本机字节 |
| target已加载、批次未启动 | progress `enabled:true,total:3,ready:0,pending:3,state:idle` | 未在此中间点重做bulk窗口 | config受理本身没有被当成指纹已就绪 |
| 实际指纹终态 | `state:completed,total:3,ready:3,pending:0`，batch完成3、bytes1830、reason complete | 后续fresh才比较 | GET终态代替“已入队”假成功 |
| JPEG代表副本 | 200 reject/duplicate/isTrashed:false，两个同SHA1 nonce均返回同一代表assetId | 精确等独立源SHA1的20字节Base64 | 现严格checksum/owner/类型/在线检查可通过 |
| JPEG非代表副本 | 该ID不会被bulk选中；相同内容查询返回上面代表 | 自己GET仍为路径checksum，与本机字节不同 | “任意副本GET可不等”真实存在，“被选中代表不等”本轮没有发生 |
| MP4 | 返回自己的assetId、明确false trash | 精确等本机字节SHA1Base64 | 不只验证静态图片 |
| 重新读取完整窗口 | representative ID、公开checksum、updatedAt均稳定 | 同上一窗口 | 3个原文件SHA256和字节数仍与准备前一致 |

源码机制与观察一致：`schema/functions/fork-iphone-checksum.ts` 的既有数据库触发器覆盖contentChecksum落库，为同owner+library内容副本分配唯一clientChecksum代表；`getByChecksums`把有clientChecksum者排在最后，service映射于是优先选代表；公开mapper发在线clientChecksum或旧checksum。**本轮没有直接查询/写入contentChecksum/clientChecksum列**；就绪由公开progress证明，代表分配效果由bulk返回ID与fresh公开checksum共同证明，内部机制另以源码对照说明。

## 账本、权限与边界

53个真实HTTP，3个只读匹配窗口共33请求。134条记录断言132通过；2个夹具假设错误保持在账本并单独更正：公开DTO不含isExternal（改核实际libraryId/owner/online），以及初次substring审计误把只读POST search/metadata当成metadata写。没有删除失败、重发准备写入或把更正前失败伪装通过；有效匹配合同未发现失败。

每窗口只POST bulk-upload-check、GET资产详情/metadata及sync/ack；metadata均为空，没有mobile-app依赖。其他owner查询同SHA1得到accept、读己方详情400；无鉴权bulk/detail/管理员progress均401。三窗口ack前后全部[]且逐字相同。整个实验0资产上传、0Immich媒体下载、0metadata写、0ACK/reset、0直接SQL写；写操作限测试账号/library准备、scan与一次明确指纹命令。所有数据均属于本次隔离环境。

公开GET和search均**省略isExternal字段**，但libraryId/owner/type/checksum/updatedAt/online/trash/edited明确存在；客户端不能要求不存在字段或默认造true。本轮不通过生产配置推断NAS真实当前ready状态，也不把指纹关联当成备份成功或安全清理。

未验证：当前父源码服务构建、真实生产target配置和指纹就绪范围、服务代表在线/删除晋升故障矩阵、Swift51声明场景执行、真实Photos current/授权/云端only及取消、Controller和iPhone/iPad自动匹配后显示/播放。此次只验证正常target库已就绪时的官方只读匹配闭环。

## 回收

日志先保存脱敏，compose down等待终态；确认项目容器/网络及离线tools残留均0，无匿名卷。仅本次新PG/Valkey/media/client-data及env/账号/Bearer文件已删除；113个证据文件扫描5个临时秘密无泄露。没有读取或修改任何生产容器、网络、env、凭据或图库。
