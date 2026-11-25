# 前台备份的网络恢复

独立 `codex/feature-backup-network-recovery` 从总候选 `e6d521a` 创建。原实现中，自动Worker有失败或未知结果就保存关闭前台开关；网络验证保留同endpoint时也不通知备份，因此连接恢复不能继续。此片复用原网络/路由与唯一备份Coordinator，不新增监视器、上传器、timer或写重放队列。

备份页新增“网络恢复后核查连接失败项（本账户）”，是独立同意，默认关闭。它不自动开启前台或系统后台规则，不保存页面相簿/iCloud草稿。只有前台自动规则已开启、用户明确启用该选项后，短暂连接失败才保留前台规则并等待下一次已验证事件；其他失败保留原关闭/人工检查语义。关闭重核或手动停止不会删除回执，也不能撤销可能已经收到的上传。

事件仍来自AppSession原NWPathMonitor → debounce → RouteEvaluationGate。首次噪声不作为恢复；实际路径变化生成绑定当前账户scope的token。await后要求原session、当前path、satisfied状态、前台和真实已验证route全部一致，才通知同代际Controller；保留同endpoint也通知。后台路径变化不启动Worker，前台重新验证后才可交付。scene尚inactive时只暂存当前上下文，原active生命周期消费，旧inactive任务不能抢走事件。

每轮消费自己的token；相同token不重复运行。若旧HTTP在途期间新token到达，旧轮失败只清自己消费的请求，保留较新事件做一轮重核。再次失败且没有更新token就等待；普通Photos/管理通知不能把等待状态变成失败重试循环。

重核在原Coordinator内再次读取当前SQLite日志、保存包含/排除集合、已有Photos授权及完整当前源。只有失败原因为network、修改日期已知且有限、源版本与扫描精确相等、同localID只有一项未完成历史的任务才能排队。取消、其他永久/未知/已尝试暂停历史、排除、缺相簿、草稿和源变化均不能借此恢复。原始/Live/RAW+JPEG回执完整保留；入队后仍由原Worker重新导出、计算SHA1、precheck、确认上传/重复回执及必要fresh配对，不凭旧UUID完成，也不直接重POST。

Worker唯一执行变化是错误分类：timedOut、cannotFindHost、cannotConnectToHost、dnsLookupFailed、networkConnectionLost、notConnectedToInternet属于短暂连接；认证/客户端证书属于permission，取消/TLS/坏URL/文件等其他传输错误保留不确定人工检查。超时可能发生在服务器已接收之后，因此也必须走完整重核。HTTP503等未知服务响应仍不因本选项自动重排。

日志头新增可选 `foregroundNetworkRecoveryEnabled`，旧v1/v2/v3缺省nil关闭，存储属性没有默认值遮蔽解码。新字段只增加明确同意的可选能力，旧读取器忽略它会失去重核，不会扩大保存范围；原版本、排除、RAW双图及独立系统后台同意保留。无数据库迁移，原上传/判重/API/官方客户端合同不变。

已写10函数31声明回归，使用生产Controller/Coordinator/Worker/SQLite/客户端与私有URLSession路径：普通照片及Live Photo的POST接收后超时、部分motion回执冷恢复、重新SHA1查重/fresh而没有第二次原片POST；每事件一轮；明确设置不立即重试；新token在真实held HTTP失败期间到达；inactive等待；默认off/权限/草稿/源变/账号/端点；永久传输分类和原AppSession同endpoint/失败/后台链。只有PhotoKit源/字节与HTTP对端是合成，不声明真实媒体或设备成功。**NAS无swiftc，以上Swift回归尚未执行，统一验收后置。**

实际NAS检查为7份改动/新增Swift scoped格式、完整workflow范围SwiftFormat0.64.5 lint 0/455、1个既有skip，bash语法与diff通过。独立源码审计 `/volume2/codex-home/mental1104/tmp/remmich-backup-network-source-audit-20261125.cjs` 实际解析4个HTTP/旧Header JSON模板、独立核两份合成SHA1，并确认Worker除分类外整份原文、手动/BG/ResumeMode、原AppSession测试与其他UI源保留；Media/AppShell及自动相簿driver文件没有修改。同行静态审查发现并复核了较新token不丢失路径，不能替代Swift运行。

没有新CI、push、dev合并、父gitlink、实服务/生产或私人媒体操作。回退此片保留日志与回执；旧自动计划会继续阻止已尝试未知任务自动运行，不将回退视为撤销服务器已收到的文件。
