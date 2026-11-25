# 相簿同步第一片：已有自有目标的手动增量补入

后续已在独立第二片接入明确预览/确认的空相簿创建、精确201身份持久恢复及辅助头v2防重放，见[创建闭环](photo-backup-album-create.md)。下文保留f13第一片的范围和检查，不将新Swift声明场景计为已运行。

2026-11-25，独立分支 `codex/feature-photo-backup-album-sync`，基于 `e45100a7fd42055e5b34b99ae01d55eaddc3111d`。未同步上游；客户端上游基线仍为672f02e，服务端拥有方为父仓库dev的官方v3.4.2加既有Fork功能。本片不改变服务端、官方mobile、API/生成SDK、workflow、签名或父gitlink，也不代表整个相簿同步目标已经完成。

## 可独立验收的用户路径

账户设置的现有备份入口现在显示“相簿同步 · 手动增量补入”。首次读取队列时读取当前账号映射与可用自有相簿；读取失败可使用现有“重新读取备份队列”入口重读。每个已保存的本地包含相簿明确选择已有远端UUID目标；同名目标同时显示UUID前缀，不自动选第一个、不自动创建。失效目标保留原UUID选项并明确提示，须重读或明确解除/改选后继续，不让Picker隐式退到别本相簿。先预览，再明确确认立即补入；用户可以停止。

- 候选统一使用最近成功扫描保存的包含/排除规则，排除优先；一张照片在两本包含相簿中时保留两条组织关系。权限变化、包含或排除相簿不可访问会停止，不把丢失排除集合解释为空。
- 未保存的包含、排除和iCloud草稿不得用于组织，也不被组织操作覆盖。组织没有原片导出器/上传Worker调用；不请求Photos授权，不修改已保存iCloud意愿，也不读取iCloud/Immich原片或预览来补证明。
- 普通照片、视频和Live主体使用已启用的真实本机匹配Controller。允许没有本机字节摘要的metadata关联，必须重核当前Photos版本、当前mobile-app字段、账号/owner、完整远端版本与canonical SHA1。此SHA1是远端身份依据，不能因此宣称本机原片已经备份。
- 服务器已有交集无需存在上传任务。没有有效关联的普通媒体显示待匹配；不靠旧上传UUID猜测、不自动启动原片匹配/上传。Live只组织still，不把paired motion作为相簿主体加入。
- RAW+JPEG本片仅使用同一完整源版本下已完成任务的两份原图回执；逐份核对当前owner/type/在线/回收站/SHA1及成员关系。两份必须在本轮都fresh确认才记整组完成。缺双回执的既有RAW交集仍待后续扩展，不降级为单图成功。
- 既有目标不改名；不删除相簿/照片，不从目标移除旧成员，不镜像设备删除。编辑者目标、POST创建、自动触发和OS后台不在本片。

## 既有HTTP合同与真实接线

`PhotoBackupView → PhotoBackupAlbumSyncSection/Controller → LibraryManagementController.perform → PhotoBackupRunCoordinator → SQLite/LibraryMutationClient`。同一备份Coordinator和管理忙门限制并发；Controller在每次await后检查同一页面epoch、账号/端点代际、权限及保存配置门禁。Photos变化、进入非active、关闭页面或换号取消旧工作，旧结果不能发布到新账号。

| 方法 / 路由 | 本片使用与确认方式 |
|---|---|
| `GET /albums`，200 | 现有相簿解码；仅展示当前owner，名称不作为身份 |
| `GET /albums/:id`，200 | 开始/恢复和写后fresh核对同一UUID及当前owner |
| `GET /assets/:id`，200 | fresh详情，不读媒体；拒绝锁定、错误owner/type/摘要、离线和回收站 |
| `GET /assets/:id/metadata/mobile-app`，200 | 官方asset.read端点；完整key/value/updatedAt，重新比较当前Photos metadata；不使用全库stream/ACK |
| `GET /albums?assetId=...`，200 | 只传assetId；服务端会忽略其他筛选，客户端显式比较返回目标UUID |
| `PUT /albums/:id/assets`，200 | 官方album.asset.create和asset.share；每次只发送一个主体ID，解析该ID的success/duplicate/no_permission |

拥有方证据：父仓库 `server/src/controllers/album.controller.ts`、`asset.controller.ts`，`server/src/services/album.service.ts:50/181`、`asset.service.ts:459`，及既有DTO。未引入服务器补丁或改写这些合同。HTTP200、duplicate或未知发送结果均不单独代表完成；须写后重新读取目标、资产与实际成员。

## 持久恢复边界

同一账号SQLite增加lazy辅助表 `photo_backup_album_sync_headers` 和 `photo_backup_album_sync_operations`。头版本1记录namespace与明确映射；逐逻辑源/本地相簿/目标操作行保存完整源、角色、证据与逐项历史确认。没有改变账号schema版本、原上传日志/任务表或备份完成状态。

发送PUT前保存sending；取消/换号后不写迟到成功。冷读把sending呈现为unknown，保持磁盘恢复事实；下次必须明确预览/确认，并先fresh核实际成员，再补缺失关系。RAW第一份成功第二份失败时保留独立回执，下一次仍重核两份；历史双确认不能在只重核第一份时提前记整组confirmed。

计划事务拒绝丢弃旧操作或更换其源/目标/证明；热检查点只更新已有同身份的一行。坏JSON、未来格式、跨namespace或磁盘失败停止，不能用空计划覆盖恢复资料。组织失败与上传完成分开，已完成上传不会因相簿权限或连接失败被改为失败。

## 回归与实际验证

新增 `PhotoBackupAlbumSyncTests.swift`：12个函数，31个声明场景，**均未执行Swift**。测试使用真实本机匹配Controller的离线冷恢复、当前在线GET证明、真实组织Controller/Coordinator/SQLite/管理client及私有URLSession/URLProtocol；Photos边界与HTTP服务是合成端口。它们不是NAS真实HTTP服务器黑盒或设备验收。

覆盖服务器已有照片/视频两种provenance且零上传任务、同名显式目标、两本地相簿共享成员、排除、Live still、RAW部分回执与冷恢复、历史双确认在JPEG真实GET门等待中取消、duplicate/提交后失联/200但未入组、发送后取消与切换另一账号、预览后metadata/版本/owner/摘要/源/目标/锁定/离线/回收站变化、草稿/权限和账本身份保护。HTTP门按真正请求到达打开，不以sleep证明已发送；所有业务Task、观察Task和服务门统一释放并等待退出。异常未启动Task明确失败，不能空跑通过。

本轮实际NAS结果：

- SwiftFormat0.64.5按现有workflow全范围检查：0/390文件需改、1既有skip；Git diff空白检查通过。
- 核对Xcode同步目录包含新增app/test源，现有显式离线编译列表没有新增未列入类型：成员HTTP回执定义留在已列入的 `LibraryMutationClient.swift`。project、schemes、SDK、workflow和脚本保持基线内容。
- `bash Scripts/check-fork-contracts.sh`实际尝试退出127：`swiftc: command not found`。没有将失败写为通过。
- 对Controller/Coordinator/取消和编译输入做了只读同伴窄审，未发现确定阻断；未覆盖全部测试，也不是运行证明。

四关口：实现25/25、可用静态25/25、Swift运行0/25、集成0/25，首片50/100。Swift6/Xcode、Photos/权限/设备行为、实际服务端联调及后续整合CI尚未验证。本分支无push、CI、主分支合并、父库或生产操作。

回退仅撤销本片源/UI/辅助表读写，不删除SQLite恢复文件或原备份回执。旧客户端忽略新增辅助表；已实际加入的远端关系仍存在，代码回退不等于撤销服务端成员关系。目标自动创建的未知结果、防重复POST、编辑者目标、无双原图回执的RAW匹配及自动/完整相簿同步仍是后续项。
