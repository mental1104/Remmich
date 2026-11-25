# 保存搜索面板的下一串行验证候选

最新本地跟进：8d9b2e9已正常合入核心修复bda，只有两份记录冲突且双方原行保留。保存面板的精确label、错误及HTTP JSON等待也改为查询端一次匹配全部label条件，再以原10秒只等exists；保存条件同名替换不能只等名称，而要等新query/favorite/media。独立audit-remmich-saved-panel-waits-20261125.cjs验证3场景、31断言/解包语句和41用户动作保持；应用/SDK/脚本/原核心UI与genuine夹具源保持bda。全工作流范围376文件格式过、1skip，diff过；Swift和新增UI尚未运行。此跟进仅本地提交，PR10保持草稿，等待核心链收口再发布/就绪；以下是原f791集成快照。

从手机准备修复73dda3df890057a754d7a0f6dfece379c48213a2正常合并保存面板418752c3deb05bf66c063e3aa5dd5c36efe2e02b，保留两父历史。仅change.log和fork-compatibility.md冲突，已独立验证双方全部原行按原序保留。没有混入备份、日期、共享、官方堆叠或Scene切片。

Swift、Packages、project、schemes及workflow与418逐字节相同。相对73，脚本只追加面板UI类选择及断言；首次准备超时同UDID一次恢复、180秒默认、UI只执行一次及原退出码均保留。原五项SearchAcceptanceUITests完整不变，未来每设备选择八项。

| 关口 | 本候选实际证据 |
| --- | --- |
| 用户路径 | 创建、改名、复用；替换/删除取消与确认；409保留草稿，明确Reload才能重试 |
| 请求路径 | 真实View/Panel/Store/Manager/Client及Repository/SDK编码，仅HTTP响应为隔离夹具 |
| Swift格式 | workflow同范围，SwiftFormat0.64.5实际0/376文件需改、1既有skip |
| Shell | Bash/diff及合并后实际脚本成功；38条通过计数包含37独立准备场景和1条附加双selector断言 |
| 保持项 | 两文档原行完整；业务源与418相同，原五测/workflow/schemes未改 |
| Swift/Xcode/UI | NAS无Apple工具链；新三项及八项联合双设备运行未验证 |

首次默认/tmp调用中，桩xcrun被拒绝直接执行，首场景退出4，原始console.log保留。仅使用测试支持的任务TMPDIR后重跑，全部检查通过；未改宿主权限或断言，不推断具体挂载原因。证据为任务目录remmich-search-final-preparation-20261125.log及-attempt2.log和其案例目录；文档合并核对脚本为resolve-remmich-search-docs-20261125.cjs。

PR9只验证73，旧fed/888收据不能证明本候选。先等待当前链收口，再由root让下一草稿进入CI，不并行启动第二条macOS构建链。没有服务端、官方客户端、API/schema、数据库、签名安装、生产部署或父gitlink推广；回退本UI/DEBUG/AX/selector切片不改照片或服务端保存条件。
