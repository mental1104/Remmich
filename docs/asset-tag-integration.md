# 标签与颜色接入管理候选

独立 `codex/integrate-asset-tags-management` 从 `c3cafb6a9b4d3b7fea80ba6113b6c337d416fc83` 创建。该基线已保留核心29d、备份f13、日期、共享、公链075、伙伴756及阶段3编辑/iPad布局。只用 `cherry-pick -x` 接入 `36a8500 → ce09fe2` 和 `db35eb6 → 2aa483f`；旧 `40f190d` metadata祖先没有合入，不从旧工作树覆盖整份客户端。

真实入口为查看器“编辑与管理”中的 Tags 按钮；sheet直接构造 `AssetTagManagementView(assetID:controller:changed:)`，保留当前资源/认证/刷新回调。个人树创建/改名/删除、当前照片加减关系及选中标签颜色 keep/set/clear 均可达。颜色默认保留、设置用原生透明度选色器，清除只发明确null；实际副作用仍经原Store/manager/client的fresh确认和账号退休。

两次择取仅有 change.log 与 fork-compatibility 文档冲突，分别按双方原区块保留。产品源码没有冲突；自动合并仍逐方法核查：

- 去掉新增标签客户端区块后，整份 LibraryMutationClient 与 c3cafb6 逐字一致，原日期、共享、公链规范化、伙伴和备份方法保留。
- 去掉6行入口后，AssetManagementView 与 c3cafb6 完全一致，元数据、编辑器、相簿及原确认/回调保留。
- 标签/颜色7份源码与测试、标签说明共8文件均等于 db35eb6。metadata原测试前缀等于当前基线；HTTP夹具/取消握手等于标签源，同时保留根候选较晚的 assertMetadataBody Swift6拆宏修复。没有把旧断言覆盖回去。
- 手工离线编译清单只补两个新领域输入，现有项目/SDK/workflow/AppShell/索引/播放器/备份产品源未改。根文档所有非空原行按原序仍存在。

实际NAS检查：SwiftFormat0.64.5按完整workflow范围 lint，0/426文件需要改、1个既有skip；bash语法与diff检查通过。独立源码审计 `/volume2/codex-home/mental1104/tmp/remmich-tags-integration-source-audit-20261125.cjs` 核对上述字节边界、原文与真实入口。最初审计将较晚根断言helper与旧标签golden整段比较失败，随后按方法边界明确保留该根修复；未据此修改产品或断言。

此为开发整合，不是运行验收：NAS无swiftc，Swift编译、47+41声明场景、原生sheet/ColorPicker与真实服务/设备均留最后统一验收。没有新CI、push、父gitlink、实服务或生产操作。回退候选上的这两片保留其他基线功能；已确认的服务端标签/颜色不自动回滚。
