# 精确不可读候选的本地匹配边界

从 `51e5d1099a60f90f3111e1d69d975b33fdecb24a` 建立独立分支 `codex/fix-local-match-inaccessible-candidates`。当前扫描的两个 fresh GET 入口会把已删除或无读取权限的候选当作整个扫描失败；本修补只把可精确识别的候选拒绝转为未匹配，继续扫描其它本机照片。旧的 conditional404 分支没有合入。

## 已核对的服务合同

- 父仓库 `server/src/utils/access.ts:48–51`：资产不存在或无 `asset.read` 权限时抛400，正文 message 为 `Not found or no asset.read access`。
- `server/src/services/asset.service.ts:67–80`：权限通过后 `getById` 已消失时抛400，message 为 `Asset not found`。
- `server/src/middleware/global-exception.filter.ts:42–62`：保留状态和 message，移除 Nest 注入的 error/statusCode，响应 MIME 为 application/json。
- 历史真实隔离服务证据固定缓存镜像 revision `c15f4ca09a26ae1dc905e351dedc79579f63960a`，归档 `/tmp/remmich-local-match-http-20261124-b5qlPg/evidence/`。`match-owner-before-delete-detail-denied` 与 `match-other-detail-denied` 的原始 body 都只有 `{"message":"Not found or no asset.read access"}`，headers 都为400/application-json。它们证明无读取权限合同；不冒充本轮执行过自己的永久删除竞态。

回收站状态仍可200并带 `isTrashed:true`，由既有领域验证拒绝。一般400还可能是 UUID/参数错误，401/403和服务器错误也不能自动当未匹配。

## 最小客户端行为

仅 `LibraryMutationClient.localMediaAsset` 读取合法 UUID 候选时，要求同时满足400、application/json MIME、精确单字段 string-message 对象及上述两条 message，才抛 `LocalMediaCandidateError.inaccessible`。未知/额外/错类型字段、坏 JSON、非 JSON MIME、不同状态或不同权限文案均保留原失败。

Controller 的 metadata 与 checksum 两条 fresh 路径在解释成功或错误之前都重验取消、账号、scope 和本机权限。该 typed 拒绝撤销旧同 ID 关联；metadata 路径仍可以本机完整 SHA1 找到另一有效副本，两个入口都继续后续照片。只有最终完成的确认集合写入现有原子 JSON。取消/换号/端点/权限失效不变成未匹配，不保存假完成。通用 `request`/`checked`/`send`、普通管理读取和写入没有修改。

## 新增回归与实际检查

`LocalMediaInaccessibleCandidateHTTPTests` 写了5个函数、39个参数化场景，通过实际 Controller、LibraryMutationClient、URLSession、metadata JSONL/官方 precheck 和真实原子文件/cold restore。仅 PhotoKit 清单/摘要和 HTTP 来源为替身：

| 场景 | 必须观察的结果 |
| --- | --- |
| 两入口 × 两条精确拒绝 | 首候选旧关联撤销，第二候选确认，1 unmatched，持久文件与冷恢复仅保留第二项 |
| metadata 拒绝后独立 checksum 副本 | 新副本按 checksum 确认，下一项继续，旧 ID 不复活 |
| 两入口 × 12种其它响应 | 普通400、401/403/404/500/503、其它权限、message数组、额外字段、坏JSON、坏200、错MIME全部失败，不继续第二项或删除旧关联 |
| 两入口 × 4种 HTTP 在途退休 | 实际等待点取消/换号/换端点/撤权限，旧响应不得修改关联或最终文件 |
| 管理 GET 与 PUT | 相同精确拒绝正文仍抛原 HTTP400，确认不改变通用语义 |

每条扫描测试独立核对完整实发请求序列和 Bearer；媒体/上传/ACK写/reset请求必须为0。扩展既有 HTTP fixture 的可选响应闭包只用于回传产品随机 nonce，默认固定 JSON 和原 MIME 行为保留。

本机实际完成：SwiftFormat0.64.5 全树 lint 为0/374需修改、1原有skip；`git diff --check` 与合同脚本 shell 语法通过。Node 只核静态边界及两份原始HTTP回执：通用传输与基线逐字相同、两 fresh 点先验 context、回归声明与冷恢复断言存在。已尝试运行合同脚本，因 `swiftc: command not found` 退出127；**Swift编译、39场景运行、PhotoKit/真机和新服务HTTP实验都未验证**。未更改正在运行的51e5 CI、工作流、SDK、服务端、生产、原片或迁移，未push/合dev。

回退时一起撤销这组客户端、测试和文档补丁，保留现有账号恢复文件和原片；没有格式或数据库迁移。
