# 相簿所有者响应兼容

当前官方v3.4.2及父仓库main/dev的AlbumResponse使用有序albumUsers；首项是owner，用户ID在user.id。server/src/dtos/album.dto.ts的schema/mapAlbum不返回ownerId，AlbumService的mapAlbumMetadata也只补时间与计数。controllers/access与main无差异，Fork DTO差异仅目录/标签等已有扩展。

直接管理客户端的ManagedAlbum此前必读ownerId，而列表、创建及封面更新都直接解码此类型。修改保持现有ownerId响应优先；该字段缺失或null时才核对首albumUsers的owner角色和非空ID，不从登录用户或后续成员补猜。新数组缺失、null、为空、首项非owner或字段类型错误时保持失败。此标量只用于已有原始owner投影，不代表完整成员权限；共享管理另据所有成员角色判断。

独立分支codex/fix-album-user-ownership-decoding从c902a8f创建，原传输、鉴权、HTTP方法/状态处理和管理写入逐字未改。旧ownerId附带不同旧成员形状的读取行为保留；不声明支持所有历史服务器协议。

新增4函数16声明场景：新首owner/多owner顺序2项、原ownerId优先4项、未确认新投影7项、真实客户端GET-list/POST-create/PATCH-cover3项。HTTP通过已有私有会话URLProtocol提供最小真实字段形状，核Bearer、路由和实发body；不是当前服务器原始HTTP回放。

NAS实际2文件SwiftFormat format/lint、git diff检查及独立Node审计通过；Node解析12个Swift JSON字面量，避免把坏JSON当作成员语义拒绝，并核全部传输/写方法与基线逐字一致。审计脚本保存在/volume2/codex-home/mental1104/tmp/remmich-album-owner-fixture-audit-20261125.cjs。NAS没有Swift，尚未编译或执行16场景、真实服务器HTTP及设备验收；源码契约定位不冒充运行重现。

不修改服务端API、官方SDK、数据库、当前888 CI、父gitlink或生产。不改变服务器相簿或媒体。回退只撤销本客户端兼容投影和回归，不触碰持久恢复资料。
