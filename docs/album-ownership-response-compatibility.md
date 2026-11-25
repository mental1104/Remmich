# 相簿所有者响应兼容

当前官方v3.4.2及父仓库main/dev的AlbumResponse使用有序albumUsers；首项是owner，用户ID在user.id。server/src/dtos/album.dto.ts的schema/mapAlbum不返回ownerId，AlbumService的mapAlbumMetadata也只补时间与计数。controllers/access与main无差异，Fork DTO差异仅目录/标签等已有扩展。

直接管理客户端的ManagedAlbum此前必读ownerId，而列表、创建及封面更新都直接解码此类型。修改保持现有ownerId响应优先；该字段缺失或null时才核对首albumUsers的owner角色和非空ID，不从登录用户或后续成员补猜。新数组缺失、null、为空、首项非owner或字段类型错误时保持失败。此标量只用于已有原始owner投影，不代表完整成员权限；共享管理另据所有成员角色判断。

独立分支codex/fix-album-user-ownership-decoding从c902a8f创建，原传输、鉴权、HTTP方法/状态处理和管理写入逐字未改。旧ownerId附带不同旧成员形状的读取行为保留；不声明支持所有历史服务器协议。

新增4函数16声明场景：新首owner/多owner顺序2项、原ownerId优先4项、未确认新投影7项、真实客户端GET-list/POST-create/PATCH-cover3项。HTTP通过已有私有会话URLProtocol提供最小真实字段形状，核Bearer、路由和实发body；不是当前服务器原始HTTP回放。

NAS实际2文件SwiftFormat format/lint、git diff检查及独立Node审计通过；Node解析12个Swift JSON字面量，避免把坏JSON当作成员语义拒绝，并核全部传输/写方法与基线逐字一致。审计脚本保存在/volume2/codex-home/mental1104/tmp/remmich-album-owner-fixture-audit-20261125.cjs。NAS没有Swift，尚未编译或执行16场景、真实服务器HTTP及设备验收；源码契约定位不冒充运行重现。

不修改服务端API、官方SDK、数据库、当前888 CI、父gitlink或生产。不改变服务器相簿或媒体。回退只撤销本客户端兼容投影和回归，不触碰持久恢复资料。

## 目录相簿与分组回执

目录的ManagedDirectoryAlbum也曾强制解码ownerId，LibraryMutationClient.directoryAlbums()/setAlbumGroup()直接使用它，因此原始管理列表的修复并未覆盖这两条路径。独立分支codex/fix-directory-album-ownership-decoding从df816a5创建，复用ManagedAlbum(from:)从同一响应读取身份，再读取customGroupName，不复制第二套首owner规则。旧ownerId优先；null或缺失才从首成员取owner，后续owner不能补救首成员不符合合同的响应。

只读核对父仓库7653378的server/src/dtos/album.dto.ts:143、166及mapAlbum，main和当前Fork均返回有序albumUsers、不返回ownerId；相关main差异只增加标签字段。目录权限仍按既有owner标量策略，不能据此声称所有共享成员权限已支持。分组缺失/null的读取保持未分组语义；PATCH仍要求精确200、相同相簿ID、匹配分组和显式返回customGroupName字段，没有为了兼容身份而放松写确认。

新增3函数24声明场景：列表/设置/清除分组分别经过当前、显式null、旧版和旧字段优先4种响应，共12项；GET/PATCH分别拒绝5类未确认身份，共10项；缺分组字段可读但不能确认清分组，共2项。通过既有私有URLSession夹具运行真实客户端，并核实Bearer、路由、单字段PATCH正文/清分组null；仅响应为合成字段形状，不是真实服务器回放或HTTP验收。

NAS实际2文件SwiftFormat/lint、bash语法与diff检查通过。独立Node审计从Swift源码解析12个实际JSON片段，校对当前响应确实没有ownerId、第二个owner保持有序不同身份，并证明LibraryMutationClient、目录Store/Mutation和离线编译脚本与df816a5逐字相同。审计脚本位于/volume2/codex-home/mental1104/tmp/remmich-directory-owner-fixture-audit-20261125.cjs。Scripts/check-fork-contracts.sh已同时列出ManagedAlbum所在客户端与目录领域文件，无需新增编译输入；Xcode测试目录采用同步文件组，无需手改工程。NAS无Swift，24场景尚未编译执行；真实服务端及设备验收未验证。不push、不触发CI或合dev，不改父仓库/生产/持久恢复资料。
