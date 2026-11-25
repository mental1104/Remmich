# 相簿公开链接管理

独立分支codex/feature-album-public-links从38f40e8创建，保留8786762成员共享、c20e300日期刷新及df816a5所有者兼容内容，不修改这些旧工作区。上游仍672f02e，无同步。本片只接官方相簿公开链接，不包含单资源链接内容增删、邮件邀请或公开访问者登录。

只读核对父仓库7653378及main的server/src/controllers/shared-link.controller.ts、dtos/shared-link.dto.ts、services/shared-link.service.ts和repositories/shared-link.repository.ts，四文件无main/dev差异：

| 请求 | 成功状态 | 身份和用途 |
| --- | --- | --- |
| GET shared-links?albumId=UUID | 200 | 仅返回当前认证用户自己创建的相簿链接，不代表其他成员链接不存在 |
| GET shared-links/:id | 200 | 仅当前链接创建者可读取；fresh详情提供所属相簿 |
| POST shared-links | 201 | ALBUM+albumId；AlbumShare实际允许相簿owner/editor |
| PATCH shared-links/:id | 200 | 按link.userId限制当前创建者；不额外要求仍有相簿owner/editor角色 |
| DELETE shared-links/:id | 204 | 当前创建者撤销一个链接，照片/相簿保留；后续成功列表缺席才确认 |

官方完整选项为description、password、slug、expiresAt、allowUpload、allowDownload、showMetadata。expiresAt=null表示无到期时间；损坏日期或缺失nullable字段不会默认成永久/无密码。新建以及用户主动关闭元数据时联动禁止下载；已有showMetadata=false/allowDownload=true是PATCH允许的合法状态，仅修改描述必须原样保留。表单显示实际既有值，允许用户明确关闭下载；不在打开页面时替用户改权限。新建默认不允许上传，界面明确可开启；实际请求仍显式发送选项，不依赖服务端默认值。

POST/PATCH的repository.getSharedLinks不join相簿，回执可以没有album；不能拿请求中的albumId补造成功。创建先fresh相簿角色和本人链接集合，已有链接修改/撤销先fresh链接，写入后读取详情并核对UUID/创建者/类型/所属相簿/创建时间/密钥/完整选项，再读取本人过滤列表。撤销以fresh成功列表确实缺少目标确认，不把403/404当成功。顺序读取不是服务端原子事务；并发变化或未知结果保持未确认，要求重新读取，不自动重试。

特别保留服务端实际规范化：创建时空描述/slug按null处理；隐藏元数据时下载为false；日期编码到官方毫秒ISO精度。PATCH当前对省略slug也会写null，所以本页保留、修改、清除均显式提交全部七项，不能靠省略字段表达保留。旧密码只在当前页面内存中用于原样保持和fresh比较，不预填SecureField、不打印、不持久化。本页没有生成或记录任何真实链接/密码；文档、测试中的值全部为合成值。

入口为Albums→相簿管理→相簿公开链接，采用现有SwiftUI NavigationStack/Form及manager/client。只展示保护状态和创建/到期日期，不展示密钥。地址仅在用户主动复制时，以当前连接API地址去掉末尾api并保留反向代理前缀，再按组件编码slug或key；不自动访问链接、不写密码到剪贴板、不声称当前连接地址一定可公网访问。既有Library Shared Links浏览卡与SDK未改。

页面退出、后台、账号或端点变化均取消旧读写、清页面敏感快照。确认绑定相簿、完整基线及页面/账号代际，每个await后重核；旧计划不能重放到下一上下文。已发出的同账号未知写入只通知读者失效，不声称已回滚或自动重发。

新增12函数57声明场景，使用真实Store→manager→客户端→私有URLSession：原11函数56场景保留，并补描述单字段修改时隐藏元数据/允许下载仍保留的实际七请求流程。原覆盖为创建owner/editor2项、已有链接viewer/未知角色三种选项编辑6项、撤销缺席/仍在/权限失败3项、只读角色创建拒绝2项、fresh预检变化4项、精确状态和选项回执5项、fresh详情/列表错误6项、nullable/日期/类型及重复列表5项、四阶段×四种退休16项、安全复制与账号隔离4项，以及旧GET/POST/PUT默认夹具路径3项。POST/PATCH响应故意省略album，不能将本地请求作为成功证明。Swift夹具字节是合成协议边界，尚未运行；独立真实服务HTTP另记下方。

既有ChecksumLookupHTTPFixture只新增默认空的query字段及显式查询匹配分支；默认无query仍执行原URL构造表达式。原actor、私有随机host、URLProtocol注册范围、取消和响应退出握手逐字保留，不引入全局注册或第二套门框架。Scripts/check-fork-contracts.sh只增加新领域模型输入，workflow/触发器不变。

原612e0c3切片已通过NAS7个Swift文件格式/lint、bash语法、diff以及6个实际JSON/5组选项的边界审计。本次从612e0c3派生codex/fix-public-link-option-preservation，只修POST/PATCH规范化、表单既有设置保留及一条Store回归；原11函数逐字保留，修改范围5个Swift文件。Swift编译、57场景运行、sheet确认/剪贴板/设备行为仍未验证，按用户最新要求列入最终统一验收。

2026-11-25独立curl容器→固定缓存服务镜像已实际完成82次HTTP/546断言：创建/修改/清除七项设置、创建者降为viewer后的管理、guest密码/expiry/撤销、fresh列表与空相簿保留；证据根/volume2/codex-home/mental1104/tmp/remmich-album-public-link-http-20261125.ZNTX7F。该轮确认POST隐藏元数据时强制禁下载、PATCH保留合法既有组合；不等于执行本片Swift。镜像sha256:7310097df26f44abf163771913abd5cbfd5d6b93018a8adb66d2238b723ca223的OCI base-images标签不证明当前App dev构建。有效密码保护key直接访问合成空相簿详情仍200，不能宣称所有媒体端点统一受密码门；未上传/下载原片，访问flag仅证持久化。全部临时容器/网络/凭据/DB及WAL已清理，原始脱敏证据保留。

没有push、CI运行、合dev、API/SDK/server/父gitlink/生产或持久资料改动。回退仅撤销客户端本片；已由用户真实创建的服务端链接需用户另行明确撤销，不能用代码回退冒充服务端回滚。
