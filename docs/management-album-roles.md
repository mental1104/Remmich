# 相簿管理的完整角色入口

独立 `codex/fix-management-album-roles` 从已整合阶段3/4/5的 `e531aab` 创建，修复该候选源码核对中明确记录的最后一处权限漏入口。不更改服务端、官方API/生成SDK、备份或上传方法。

合同来自父仓库dev `a62bf61`：`server/src/utils/access.ts` 的AlbumUpdate、AlbumAssetCreate、AlbumAssetDelete允许任一owner或editor，AlbumDelete只允许任一owner。`album.service.ts:142/164` 的customGroupName与改名、封面共用AlbumUpdate；移出成员仍由服务端逐项权限最终裁决。Fork个人组→大组映射只要求当前用户可见该组，不要求owner/editor。

ManagedAlbum保留原ownerId展示投影及旧16场景兼容，但新增独立ManagedAlbumAccess；ManagedDirectoryAlbum同源传递access。HTTP显式albumUsers一旦存在，即使null/损坏也不退回legacy ownerId授权。完整成员必须唯一UUID、全部为已知owner/editor/viewer、至少一个owner，并明确找到当前用户；缺角色、未来角色、重复/无效身份均只读。只有完全没有成员字段的旧响应，才允许明确legacyowner最小兼容。没有存储默认值导致新字段被解码忽略。

| 实际入口 | owner（含非首位） | editor | viewer/未知 |
| --- | --- | --- | --- |
| 相簿管理列表、改名、封面、批量成员 | 可见并按动作开放 | 可改属性/成员 | 列表可见，管理菜单只读 |
| 删除整个相簿 | 可删除，保留照片 | 禁止 | 禁止 |
| 目录中的相簿customGroupName | 可修改 | 可修改 | 禁止 |
| 单张照片加入/移出相簿目标 | 可选 | 可选 | 不列为可写目标 |
| 个人组→大组映射 | 保持原规则 | 保持原规则 | 保持原可见组规则 |

三个真实UI入口不再用首owner标量筛选。AlbumManagementView显示当前全部可见相簿，按钮按动作分开；单张AssetManagementView目标及传入批量页的目标使用成员写许可；目录View/Store用属性许可。共享成员、公链creator和伙伴权限逻辑没有被替换。

新增管理专用managementAlbum GET强制200与相同UUID。已确认动作经performAlbumManagement再次fresh读取角色，随后最多一个原写请求；批量相簿动作每项重新预检，目录move同样如此。取消、换号和路由变更复用原client会话取消/manager代际，未知结果不自动重发。原renameAlbum/deleteAlbum/setAlbumCover/add/remove/setAlbumGroup及所有上传、备份、标签、metadata、公链/伙伴方法保持字节不变。脚本显式编译输入只新增ManagedAlbumAccess源。

必要回归新增6函数32声明场景：12个DTO权限边界；10个真实manager/client/私有URLSession动作；3个fresh降权；3个真实目录Store成功/撤权；1个viewer个人映射；3个真实在途预检的取消/换号/路由退休。原Directory/Batch只有实际新增预检的HTTP剧本与精确请求序列跟随变更，其他动作、逐项回执与原解码40场景保留。测试代码已写，NAS没有swiftc，未执行Swift/HTTP/设备验收。

实际NAS证据：13文件scoped格式、全workflow范围SwiftFormat0.64.5 lint为0/454、1个既有skip，bash语法与diff通过。独立源码审计 `/volume2/codex-home/mental1104/tmp/remmich-managed-album-roles-audit-20261125.cjs` 从真实Swift测试源解析23个JSON模板，核对19份备份源、原client方法与共享HTTP夹具字节保留以及三个真实入口；这不是Swift测试运行。没有新CI、push、dev合并、父gitlink或生产写入。回退本片恢复旧入口限制，不撤销用户已在服务端明确执行的相簿操作。
