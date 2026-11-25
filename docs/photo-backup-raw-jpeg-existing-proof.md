# 已有RAW+JPEG交集的完整组织证明

本分支从98109d61c36d0732f8848455f94c296bc0ca8481独立开发，只择取primaryChecksum单依赖9c0e01a为ae08005，没有合入其921编辑者/自动driver祖先。入口仍是现有备份页→相簿同步→已保存包含/排除与明确目标→预览→确认；实际Controller.prepare/candidate/synchronize已消费新证明，不是未接线工具类。服务端、官方mobile、API/生成SDK、workflow及生产不变。

没有完整双上传回执的RAW+JPEG，现在使用以下只读链：

1. 已保存相簿扫描给出完整rawJPEG源。真实Photos读取全部公开资源/修改时间/调整信息/权限，必须恰一photo和alternatePhoto、公开UTI明确各一RAW和JPEG、无编辑/额外/Live动态资源。角色不依靠枚举顺序或文件名推断。
2. 两份资源各自经已有`PhotoKitLocalResourceRequests`/真实SHA1流完整读完，固定`isNetworkAccessAllowed=false`，没有allowCloud参数、临时原片导出或上传。每份读取后重新比较完整公开源/资源观察及授权。任一不足、版本/权限/账号变化或取消都不能给出部分证明。
3. 现有`POST /assets/bulk-upload-check`用两个独立随机nonce和各自SHA1 hex查找；accept只表示无匹配，trashed不能组织，必须两个不同existing UUID。正文不携带Photos标识、原文件、metadata或上传字段。
4. 现有`GET /assets/:id`分别fresh读取完整安全子集，核对精确ID、同认证owner、IMAGE、明确在线/未回收站、timeline/archive白名单、原片规范SHA1与有限版本。这里用`ManagedAsset.visibility`排除locked/未知/hidden，不能拿缺visibility的旧`LocalMediaRemoteAsset`子集声称检查过。最后再核本机完整观察与原授权范围。
5. `.rawJPEGChecksum`保存两角色/UUID/原SHA1/远端版本，明确不是上传完成回执。确认组织前重跑双本机hash和远端证明，并与预览固定对象一致；现有逐成员fresh关系确认与独立检查点负责真正补入。一个成功另一个失败仍保留部分恢复事实，不能提前整组完成。

原先同源completed RAW/JPEG双回执路径保持，不强制重复本机读取。普通照片、视频、Live仍可用既有fresh关联；没有关联时，只接受同源completed任务中本次上传已算得的primaryID+canonical primaryChecksum，旧nil不能靠UUID猜测。Live只组织still，动态回执/配对和上传完成状态不变。已保存iCloud备份意愿不授权本功能下载云资源；没有从Immich下载原片/预览补证的代码路径。

这些Photos/HTTP/SQLite读取不是跨系统事务。无CAS接口无法消除两次远端读取或核查与关系写之间的外部并发窗口；确认前/逐成员写前后核查只确认可观察状态，不宣称原子配对或全组原子成员事务。Proof不授权清理手机，也不把metadata单图关系提高成双原图备份完成。

辅助组织账本升级v3，保留v1/v2的映射、操作与创建事实；账号schema、上传Header/任务表不变。v3显式包含`creations`和`automaticEnabled`bool，默认false；v1/v2不能装新RAW proof或普通originalReceipt fallback。旧981只认v1/v2且不知道新enum case，必须拒绝v3，不能忽略后保存。当前冷读/计划/热检查点拒绝缺字段、未来格式、丢历史和换身份。创建/恢复先升当前格式，避免并发保存自动偏好导致201身份检查点被降级门拦下。

`setPhotoBackupAlbumSyncAutomaticEnabled`是唯一偏好写入口：事务fresh读取保留全部事实，只upsert header，不重写任何operation或打断上传Coordinator。普通计划事务保留磁盘fresh flag，旧计划不能覆盖刚开的/关的意愿。`prepare(... automatic:true)`再次核保存意愿，只消费新源或安全未尝试queued零确认；failed/unknown/sending/cancelled/confirmed/partial历史必须人工明确恢复。自动driver/Processing租约由另一个独立切片接入，本片只提供共享字段/安全核心。每run完成源索引/不安全历史Set与RAW源memoization避免逐源扫描整段历史或同源多映射重复hash。

新增11函数44声明场景，连同原19函数41场景为30/85，全部未执行Swift。回归实际使用Controller/Coordinator/账号SQLite/client/私有URLSession；Photos系统口是合成公开观察/分块回调，但生产`LocalPhotoResourceSHA1Stream`真正计算abc/def的SHA1。独立服务金值不从待测proof反推。涵盖双源/双UUID、坏状态/版本/摘要、云端不足/编辑/字节/版本变更、每await权限/上下文、实际JPEG GET退休、预览后重证、普通旧nil与Live、自动历史门、SQLite触发器证实header-only和坏JSON字节保全。它们不是实际PhotoKit授权库或NAS公开服务HTTP验收。

NAS实际完成7-file SwiftFormat0.64.5格式/lint、diff、保护源/明确API/JSON/golden SHA1/旧reader格式与测试声明审计。Swift/Xcode不存在，未运行这85场景、真设备/服务、CI或额外验收轮次。此源码功能已实现，编译/运行/联调留在用户最后统一验收；本片四证据关实现25+静态25+运行0+集成0，不能冒称已验收。未push/合dev/修改父pin/生产或私人原片。

回退须保留v3-aware读取器或明确恢复工具及完整SQLite恢复资料，不能删头、降级或丢创建/部分事实来迁就旧代码。代码回退不撤销已补入的服务端关系；原上传任务与媒体继续保留。
