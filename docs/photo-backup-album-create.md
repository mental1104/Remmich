# 相簿同步第二片：明确创建空相簿并映射

后续第三片扩展已有共享editor目标；本次201的恢复仍只认本人owner，见[编辑者目标](photo-backup-album-editors.md)。以下保留第二片原范围与未运行声明。

2026-11-25，`codex/feature-photo-backup-album-create`，基于首片f13f7e35f6a8472ba858d5516258abb0780e179d。上游672f02e和父服务端官方v3.4.2基线未变，未同步、修改或部署服务端/官方mobile/API/生成SDK/workflow。

备份表单每个已保存包含相簿现在可以单独输入名称，先预览再确认创建。预览持久保存意图并显示当前同名目标数，不发POST；确认明确说明会另建空相簿、替换本地映射，保留原相簿及成员。创建成功后仍须另外预览/确认照片补入。原有成员补入和创建共用一个confirmationDialog，避免两个宿主互相覆盖。

官方拥有方为父仓库 `server/src/controllers/album.controller.ts:40`、`server/src/services/album.service.ts:98` 与 `server/src/dtos/album.dto.ts`：`POST /albums`受album.create保护，返回201；请求为 `{albumName, assetIds: []}`，不添加用户/成员，也没有服务端幂等键。名字不唯一，服务先创建再映射响应。因此列表出现唯一同名新项、时间接近或本地随机意图UUID均不能证明是本次创建，不能由此认领或重发。

| 持久阶段 | 行为与恢复 |
|---|---|
| prepared | 用户明确名称预览已保存，尚未发送；可取消为abandoned或确认一次 |
| sending | POST前checkpoint；取消、换号或崩溃后保留，冷读呈现unknown，不重发 |
| received | 精确201，完整当前owner/name/UUID已核，先持久保存该UUID，再fresh GET同一目标 |
| mapped | 本次201 UUID经fresh GET owner/name核实并保存映射；也可由用户明确选已有目标来结束未知意图，receiptID是否存在保留其区别 |
| unknown | 无可证明的本次201身份时只GET刷新列表供明确选择；禁止再次POST或另开该本地相簿的创建意图 |
| rejected | 明确400/401/403响应；保留失败记录，修正后必须新预览、新确认才另发请求 |
| abandoned | 只允许未发送prepared意图取消；不能用取消未知意图绕过防重放 |

received的fresh核查失败保留201 UUID，后续只读恢复可完成映射。网络丢失、非201成功状态、坏201正文一律未知；即使只出现一本新相簿，也不猜测它属于本次POST。未知无UUID且没有可选目标时，本片保留未决状态，无法自动证明相簿不存在，也不自动重建；这是官方无幂等键合同的恢复边界，不声称已实现重复创建预防的服务端幂等性。

同一相簿账本头新增创建意图。首次意图将辅助头由v1升v2，保留v1读取；账号schema版本、上传日志/回执和逐项相簿操作表不变。v2必须有creations字段；拒绝版本降级、丢意图、更换原身份/名称/201 UUID、删除已映射事实，以及sending/unknown回退prepared。首片旧代码明确拒绝v2，不能忽略意图后覆盖恢复资料。member热检查点也验证v2头，但不修改创建事实。

全部创建/恢复继续通过现有manager忙门和唯一Coordinator，逐await核同一账号/端点、Photos权限、页面epoch及无备份草稿/运行/配置写入；每次创建/恢复重新读取保存包含/排除并确认相簿可访问。后台/关页/Photos变化取消不生成迟到映射。没有原片/预览读取、隐式iCloud请求、自动POST、改名、删除或成员移除。已存在交集、Live still及RAW双主体规则沿用首片。

新增7函数/10声明场景，全文件19函数/41声明场景，**均未执行Swift**。使用真实Controller/SQLite/管理client/URLSession，HTTP服务仍是本地合成URLProtocol端口：同名先预览零POST、真实201字节与fresh新UUID、单独补入成员、received冷恢复GET-only、提交后断线/错误200/坏201无认领无重POST、真实已提交POST门中取消/切B、403后新意图、v1/v2与防重放保史、取消未发送预览。不是实际服务端HTTP或Photos/设备验收。

实际NAS检查：SwiftFormat0.64.5按现有workflow全范围0/390需改、1既有skip；Git diff空白及原SDK/workflow/project/scheme/脚本/Worker/上传Journal保持检查通过。离线契约脚本实际尝试退出127，原因swiftc缺失。Swift6/Xcode/UI/新回归、实际HTTP与系统行为留最终统一验收；源码开发100%，验证关口25实现+25静态+0运行+0集成=50/100。无push/CI/dev合并/父库或生产变动。

回退保留账号SQLite恢复资料和已创建远端空相簿。回退到只认v1的首片会使v2组织功能明确不可读，不能通过删头、降级格式或丢意图“修复”；其他上传队列不受此辅助头影响。代码回退不撤销相簿创建/映射已有关系，也不自动删除未知结果中的相簿。编辑者目标、无双回执RAW交集、自动组织触发、网络自动恢复及OS后台仍是后续范围。
