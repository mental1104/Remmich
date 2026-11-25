# 无mobile-app字段的本地字节匹配

本独立片从 `b79bfa23083103a3ff0cddecf53831f755922550` 创建，分支 `codex/feature-local-media-checksum-matching`。新增本机current字节SHA1读取与官方只读precheck，不修改MediaLibraryController、匹配Controller、Worker、SQLite、既有metadata stream或上传方法。root/controller分支接线后才是用户可用的自动匹配，本片不独立宣称UI已完成。

## 接口与语义

- `LocalPhotoChecksumReading.checksum(for: LocalPhotoSnapshot, validateContext:)` 返回 `.verified(LocalPhotoChecksumProof)` 或 `.insufficient(reason)`；权限/版本变化、Task/context取消抛错。
- proof保留source完整快照、唯一resource描述、digest；digest含小写40字符 `sha1Hex`、同20字节的 `sha1Base64`、实际正数 `byteCount`。它证明本轮本地字节，不是备份完成、远端唯一性或手机清理凭据。
- `LibraryMutationClient.lookupLocalMediaChecksums([LocalMediaChecksumQuery])` 只POST `/api/assets/bulk-upload-check`，body只有nonce ID与SHA1；最多64项是客户端限额，当前服务DTO本身未声明该max。响应必须精确200、每个nonce唯一完整回执；按请求顺序返回 `.noMatch` / `.existing(UUID)` / `.trashed(UUID)`。accept不会进入upload；重复/缺失/额外ID、缺省或null isTrashed、非法asset UUID、矛盾动作字段均失败，不返回部分结果或自动重试。
- lookup没有owner/offline/type/edited完整信息；调用方仍须fresh详情、当前账号/版本及Photos可用性校验后，才能选择本地显示。其他类型或trashed结果不能成为关联成功。

## Photos current与网络边界

先核官方 `mobile/ios/Runner/Sync/PHAssetExtensions.swift` / `PHAssetResourceExtensions.swift`：官方会使用私有KVC isCurrent，本片不复制。Apple仅说明 [fullSizePhoto](https://developer.apple.com/documentation/photos/phassetresourcetype/fullsizephoto) / [fullSizeVideo](https://developer.apple.com/documentation/photos/phassetresourcetype/fullsizevideo) 提供modified版本，不能从任一同类型资源名称推断就是current。

因此首版只为明确未调整、唯一 `.photo` 或 `.video`、已知修改版本、无alternate/RAW/fullsize/adjustment资源的本机对象给proof。编辑、RAW+JPEG、歧义、LivePhoto整对未证明、版本缺失等明确不足；不会退回原片哈希冒充编辑后的current。resource UTI经公开UTType分类，未知格式不猜。

`PhotoKitCurrentResourceChecksumReader`不调用Cloud ID映射，不读私有isCurrent/locallyAvailable，不弹授权请求。expected与前后完整快照比较时仅忽略cloudIdentity映射值，修改日期、资源、尺寸、类型、adjustment/位置等其余字段精确一致。授权状态、Task和账号context在异步边界前后核验；这些检查不是PhotoKit事务/CAS，展示读取仍需root的即时版本校验。

真实字节使用 `PHAssetResourceManager.requestData` 回调逐块计算CryptoKit Insecure.SHA1，不累计整张照片/视频、不写临时原片。`isNetworkAccessAllowed=false`固定；[Apple公开合同](https://developer.apple.com/documentation/photos/phassetresourcerequestoptions/isnetworkaccessallowed)表明非本机资源会返回需要网络的错误，不应改true重试。Mutex保证摘要、continuation与请求ID安装/取消只完成一次；cancel早于ID返回时，安装后仍取消实际系统请求。cloud-only变为 `.notLocallyAvailable`，没有部分摘要。

## Live Photo静态展示补充（fromf92b1e8）

原始首版的Live整组拒绝仍不等于可以证明motion。本次仅把严格未编辑的Live **still照片**纳入现有SHA1读取：hasAdjustments必须false、adjustmentTime必须nil，修改版本已知且资源完整对齐；恰好一个originalPhoto且公开UTType分类为非RAW image，加一个pairedVideo且为video。任何adjusted/alternate/RAW/未知/额外/重复或缺失成员都拒绝，不从多资源中猜current。仅photo或仅paired的不完整Live继续返回unsupportedMedia；普通image/video原政策不变。

selection只返回photo。LocalPhotoChecksumProof.source保留完整两个资源描述用于前后版本核对，但digest **只覆盖still字节**；它不是pairedVideo摘要、远端配对确认、Live整组或备份证明。动态播放仍须独立的motion证明以及root对远端配对和两成员fresh详情的校验，不得把PHAsset(image/photoLive)交给forVideo或从静态命中直接播放。

PhotoKitCurrentResourceChecksumReader复用原来的expected完整snapshot、授权、账号context和前后source对比；paired描述变化也会使still证明作废。真实字节入口对Live再显式要求adjustmentTimestamp nil且选中photo/image，随后仍调用同一个network=false ResourceManager分块SHA1，不读取pairedVideo、Immich媒体或下载iCloud。没有改Controller/Media/LiveView/服务端/上传/SQLite/CI。

新增LocalLiveStillChecksumTests共6函数28声明场景：两种资源顺序的政策与真实reader→真实SHA1Stream正例、禁止motion冒充still proof、15种不安全shape在字节前拒绝、7种paired/photo/版本/编辑/权限/context变化和partial-data后network-required不足。旧26项reader测试仅澄清不完整Live的注释，原拒绝断言保留。四个相关Swift文件格式/lint、diff、独立Node37字节SHA1/Base64参考及普通媒体政策不变静态核对通过；NAS无Swift/Xcode，新增28场景执行、真实PhotoKit Live still及设备播放仍未验证，不能以此声称整组已匹配。

## NAS服务适配边界（既有）

当前父Fork的bulk precheck复用 `getByChecksums`，内容/backup指纹兼容仅在现有iPhone backup配置有效、目标library在线/未删且指纹就绪时参与；clientChecksum代表排序可优先返回。新客户端不改配置、不写/分配指纹、不使用SDK存在作为已验证证据。普通已有SHA1资产即使没有mobile-app也可由本机摘要查询；外部库配置/代表指纹不齐会未命中，必须在设置进度中可观察，不能当备份确认或悄悄上传。

## 验证状态

新增51个声明场景：26个current资源政策/真实reader/真实分块SHA1、公开network-required错误、版本/权限/context变化及两个request ID取消窗口；25个实际URLSession nonce映射/完整body、accept未命中、trash、19类错误回执、64/65边界、取消/换号/换端点。纯合成bytes和独立Node SHA1/Base64参考，不读取私人照片；HTTP会话拦截所有host，不落真实网络。取消测试有提前失败唤醒、清理和一分钟上限，不靠sleep猜时序。

NAS实际完成7个Swift文件SwiftFormat0.64.5格式/lint、shell语法、独立SHA1/Base64与3份固定JSON语法、diff检查。**无Swift/Xcode，编译/51场景执行、真实PhotoKit callback/云端only、设备本地播放、当前外部NAS库指纹命中均未验证**。root负责统一macOS链与Controller/媒体接线；本片不push/发CI/部署生产。后续真实服务黑盒证据另行提交，不以合成URLSession场景充当实际服务成功。

回退此独立客户端提交不改变任何远端资源或上传队列；没有持久hash/关联迁移。本机字节proof在源变更/账号撤销后必须失效。
