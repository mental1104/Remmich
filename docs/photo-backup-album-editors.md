# 相簿同步第三片：已有共享编辑者目标

2026-11-25，`codex/feature-photo-backup-album-editors`，基于98109d61c36d0732f8848455f94c296bc0ca8481。无上游同步；仅扩大明确选择的合法目标，不修改官方API、SDK、共享成员、资产拥有者或后台行为。

官方 `server/src/services/album.service.ts:181` 在 `PUT /albums/:id/assets` 前要求album.asset.create，并对资产要求asset.share；`server/src/utils/access.ts:144/253` 与 `server/src/repositories/access.repository.ts:100` 允许owner/editor，viewer不能加入。列表和详情的 `albumUsers[].user.id/role` 是当前本人权限依据；DTO说明的“第二项本人”不能代替实际UUID查找。已有共享成员投影遵循同一字段合同，本片只读取UUID/role最小子集，避免为备份组织引入姓名/邮箱及整套共享管理类型。

- 当前GET目标列表显示已核owner/editor，必须仍由用户明确选UUID；同名不自动映射。共享相簿只增加本人已确认资产的缺失关系，不能把其他所有者资产或锁定资源交给分享。
- 有完整members时要求首owner与原身份一致、成员UUID唯一、角色已知；按本人UUID查owner/editor。缺本人、viewer、未来角色、重复身份或损坏投影不提升权限，不因legacy ownerId回退。
- 旧服务端无members的响应仅保留明确本人owner能力，不能猜共享editor。原ManagedAlbum解码和其他管理调用不变，窄权限投影留在原手写client文件，显式离线编译输入仍完整。
- 设置映射、预览、每次成员操作及写后均重新GET详情核本人权限。确认前失权阻止PUT；实际PUT后失权不记整组成功，保留未知结果，恢复权限后先fresh成员再补缺失，不重加已有关系。
- 创建恢复继续显式 `ownerOnly:true`，不能将“当前可以编辑”提升为本次201创建owner身份。原201回执保留且只GET，不重POST。

新增4函数/11声明场景，全文件23函数/52场景，均未Swift执行。真实Controller/SQLite/client/URLSession到合成HTTP覆盖本人第三项editor、legacy本人owner、viewer/缺本人/未来/重复/legacy他人、确认前或PUT后撤权与恢复、既有成员读取后撤权不沿用历史确认、创建收到201后仅剩editor。服务端合成端口也拒绝无写角色的PUT，不能通过客户端状态伪造服务已写。没有真实服务端或设备验收。

实际NAS：现有workflow全范围SwiftFormat0.64.5为0/390需改、1既有skip，diff空白和受保护源检查通过。离线契约脚本实际尝试退出127：swiftc缺失。Swift6/Xcode/UI/新增回归与实际HTTP留最终统一验收。开发100%；验证四关25+25+0+0=50/100。无push/CI/dev合并/父库/生产操作。

回退只恢复owner目标限制；保留v2创建恢复资料、原相簿映射/成员及上传回执，不删除实际加入的关系。无双回执RAW交集、自动相簿触发、自动网络恢复及系统备份接线继续推进，不将此片当作完整阶段完成。
