# 日期派生确认与定向时间线刷新

从独立metadata切片45db8a0续建 `codex/feature-metadata-date-timeline-refresh`，不改51e5候选、dev、API/SDK、生产或原片。本工作按“日期投影确认”和“旧/新桶索引接线”两个提交审查，保留现有接受代际与bootstrap语义。

## 已核源码与本地查询

- 官方单项PUT先写EXIF并排SidecarWrite，后续MetadataExtraction才在同次asset更新中改fileCreatedAt和localDateTime。日期-only PUT甚至可能不推进asset.updatedAt；其他普通字段也可推进它，因此HTTP200/updatedAt不能证明日期派生完成。
- fileCreatedAt是真实拍摄瞬间；localDateTime是用UTC ISO编码的服务器墙上时间。bucket的localOffsetHours来自二者差值。SDK的单详情capturedAt另映射localDateTime，不能误用它替代真实fileCreatedAt。
- canonical索引正常增量只选最新batch和数量变化桶。集合缓存另有older review，不能推导canonical历史同桶排序已经覆盖。公开Fork taskStatuses没有绑定本次PUT的完成token，不将其当可移植完成凭证。
- 完全本地内存SQLite查询实际通过：EXIF-only保持旧分桶；当前月移2019-06后旧月消失；同2019-06改日后计数不变但顺序改变，正常增量不选该月；另覆盖同墙换offset必须看fileCreatedAt、同instant换offset必须看localDateTime。它不是PostgreSQL/Swift/HTTP验收。

只读源码快照与查询结果：`/volume2/codex-home/mental1104/tmp/remmich-date-server-evidence-20261125.DonpnN/report.txt`、`query-results.json`。父源码固定7d5db7、客户端45db8a0；不复用生产图库或数据库。

## 第一提交：只确认当前投影

新模型要求fresh GET中的EXIF日期、真实fileCreatedAt与预期瞬间一致，localDateTime与服务器实际区名在该瞬间的秒级offset一致。IANA历史秒偏移保留；未知/缺失区名保持未确认，不从GPS或设备区猜测。只核此刻投影，不声称任务队列结束、未来不会再改，亦不突破stack/可见性过滤。

已确认日期写入后，最多3次fresh GET、间隔1秒；未就绪或失败明确保留未确认说明，不再PUT、不无限轮询。页面提供手动只读重试，取消/退出/换号/仅换端点都阻止迟到投影。日期检查时阻止另一项确认覆盖正在核对的状态。

专用需求仅暂存在当前管理账号的assetID→投影Map，通过现有revision通知；不是持久任务队列。能力默认关闭，第二提交接入真实接受索引后才启用，孤立管理宿主不会假称已通知时间线。归档/隐藏/锁定资源只说明不在主时间线，不将其手动插入canonical索引。

第一提交新增纯投影9函数48声明场景，以及实际Store/manager/client/URLSession路径的6个合成只读场景：EXIF-only不发布、有限成功/耗尽、取消/页面/账号/端点退休；原38元数据场景保留。Swift未执行，不能把声明计数或本地SQLite查询当作应用通过。

## 验证与后续

本轮证据目录：`/volume2/codex-home/mental1104/tmp/remmich-date-refresh-20261125.gcCTku`。NAS仅能执行SwiftFormat、shell/静态字节与差异检查，缺少Swift/Xcode；编译、Swift测试、服务异步HTTP、设备及最终日期排序未验。第二提交仍须用真实SQLite/同步器覆盖历史同桶、跨月、活跃同步保留后续需求及账号/端点迟到。

回退需依次撤销索引接线和本投影确认；不改数据库结构，不自动回滚服务器已保存日期，也不进行生产重扫。
