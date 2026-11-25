# 管理与浏览开发候选整合

基线为 `c3cafb6`，已含核心29d、备份f13、日期/共享/公链075/伙伴756、可视编辑与iPad布局。标签仅追溯择取 `36a8500 → ce09fe2`、`db35eb6 → 2aa483f`，保留旧metadata祖先不进入的边界。随后正常合并 `51ccb1b → 4f5c25d` 与 `7dfffd3 → 455ab5f`：前者未合链只有24e人物fresh、982共享测试会话merge、ed0随机、51co-owner待整理；后者只有d5官方stack、2dc场景、7dSteam。没有取旧WIP或背景备份分支。

源码没有冲突。历史文档逐块保留双方原文，不覆盖整份文件。独立只读审计实际核对52份交付源码/测试/说明与原片逐字相同，616份其他根文件字节不变；共享三个源按方法边界复核：SDK客户端仅组合全owner投影与Stack/Scene方法，AppSession仅新增Photos sceneSource，Repo保留伙伴policy/持久GET退休/原GET路径及全owner映射，再添加独立Stack写lane与Scene只读lane。原DEBUG宿主入口保持唯一，Steam复用既有同源筛选；随机只在自己的冻结Selection显式sourceOrder，普通Viewer默认chronological不变。

Library真实入口同时包含 Random photos、Pending albums、Photo stacks、Scene groups、Steam screenshots。主Photos由原TimelineStore/Repo注入场景读取，分组只使用完整月份证据，不替换原catalog或Viewer原资源。查看器仍能进入现有编辑与照片管理，标签与颜色入口不成为孤立工具。阶段3的原图/裁剪/旋转/镜像/对照、iPad相簿布局和窗口连续性保留原实现，本次没有新增产品交互。

## 阶段4源码核对与明确缺口

| 原目标 | 当前真实用户入口与关键源 | 开发状态/边界 |
| --- | --- | --- |
| 单张与批量照片管理 | Viewer管理 → AssetManagementView；Albums右上管理 → AlbumManagementView → BatchAssetManagementView/Store | 收藏、归档、回收站/恢复、描述、加入/移出相簿已接；批量只对已加载的明确选择逐项留回执，未知停止，不永久删除。相簿管理仍有下面的角色漏入口。 |
| 相簿与封面 | AlbumManagementView创建/重命名/删除、Manage photos and cover → 单选封面 | 功能已接，但列表仍只看ManagedAlbum首owner投影；非首co-owner/editor被漏选，不能据此宣称全部权限完成。删除应仅任一owner，编辑者不能删除。 |
| 目录写入 | Manage categories and groups → AlbumDirectoryManagementView/Store，AlbumDirectoryMutation | 自有大组增改删及个人组归属已接；个人归属作用于全部可见组。相簿customGroupName目前View/Store只看首owner，是确定待补权限入口。 |
| 日期/位置/评分/标签含色 | Viewer管理 → Date, location and rating/Tags；AssetMetadataView/Store、AssetTagManagementView/Store/ColorEditor | 日期与固定偏移、成对坐标、评分keep/set/clear、个人标签树与本照片关系、颜色keep/set/clear已接；日期/坐标清空沿已核服务端限制明确不提供。日期派生与本机列表确认分开。 |
| 共享角色/已有账户 | 相簿管理 → 成员与共享权限 → AlbumSharingView/Store | 完整有序albumUsers角色，owner/editor管理，viewer只读/合法退出，首owner角色/最后owner保护；已有GET/users账户逐人添加，不存在邮箱邀请/接受API。此路径不依赖首owner标量。 |
| 公开链接 | 相簿管理 → 相簿公开链接 → AlbumPublicLinkView/Store | 列表、创建、选项修改/密码和slug保留设置清除、到期、上传/下载/元数据、复制、撤销已接；创建AlbumShare，已有链接按creator，POST/PATCH规范化已保075。 |
| 伙伴 | 账户 → 伙伴关系与时间线 → PartnerSharingView/Store | 双向读取、已有账户新增/撤销本人outgoing、incoming时间线选项已接；持久policy+accepted generation/bookend确保同计数旧月不复用，明确只读刷新重试。 |

上述相簿权限缺口已向主Agent报告，并作为独立后续修复，不在本次纯整合中静默修改。证据读取的是父仓库dev `a62bf61`：`server/src/utils/access.ts:263` 的AlbumUpdate和AlbumAssetCreate允许任一owner或editor，AlbumDelete只允许任一owner；`album.service.ts:142/164` 将customGroupName交同一AlbumUpdate。个人目录映射 `album-category.repository.ts:95` 只要求可见album_user，不能误收紧为owner。客户端限制点为AlbumManagementView:120、AlbumDirectoryManagementView:77/Store:93、AssetManagementView:145；三个入口需要完整成员角色，而不能复用首owner展示投影。

实际NAS检查：完整workflow范围SwiftFormat0.64.5 lint为0/451、1个既有skip；三个相关shell的bash语法、工作区/暂存diff检查通过。只读审计文件为 `/volume2/codex-home/mental1104/tmp/remmich-management-browsing-integration-audit-20261125.cjs`。NAS没有swiftc；Swift编译、测试执行、真实HTTP、设备/系统交互均未在本片运行，按用户决定统一后置。没有新CI、push、dev合并、父gitlink、服务端/生成SDK/生产操作；正常merge保留原提交，回退不删除journal或声称撤销既有服务器写入。
