# iPad 相簿总览标题栏

本切片来自 `795fd39`，独立分支 `codex/feature-ipad-library-layout`，工作区 `remmich-parallel-ipad-layout`。它不修改今晚候选、Viewer、AssetManagementView、Library 路由、API、备份、数据库、生产或 CI；没有 push 或合入候选。

## 已核实的缺口

原 AlbumsView 虽然有随 Dynamic Type 缩放的 headerRowHeight，但 AlbumScopeControl 本身仍固定 44 点高，且原生 UISegmentedControl 没有更新字号。搜索与菜单分别占左右 44 点，scope 中间再各让 12 点；窗口变窄或字号增大时只能压缩分段标题。控制页没有 Cmd-F / Escape 搜索操作。

## 当前行为

- 使用当前缩放字体实测 All/Shared 所需宽度；可放下时仍保留原单行布局，中间不够时 scope 与搜索/菜单分为两行。连整行也放不下的极端字号使用原生 scope 菜单。
- 同一 UISegmentedControl 实例留在原控件树，换宽度/字号只更新 frame/font；菜单回退时隐藏并禁用该实例。选择、查询、排序和相簿卡片身份均仍由 AlbumsView 原状态持有，不因分行重置。
- 内容顶部留白、滚动指示与原有重排锚定都使用同一标题栏总高度。分行时展开/关闭搜索不改变行数和顶部留白，scope 保持单独可操作的一行。
- Cmd-F 打开或聚焦搜索，重复操作保留查询；展开后有独立 Escape 关闭按钮。原搜索关闭/滑动语义保持，操作不产生网络写入。
- 命令仅在当前可见相簿根页生效：其他 tab、导航子页、查看器、管理弹层、后台或 scope 动画不接收背后命令。搜索、scope 和菜单保留原生玻璃外观，并有指针悬停反馈和至少44点高的命中区域。

仅提取 AlbumScopeControl 与新 AlbumOverviewHeader/几何 helper。未修改卡片/列表的排序、缩放转场、相簿打开路径、大组分组和管理操作。

## 验证

新测试矩阵包含内宽 240/288/361/744/802/992/1162 点与 13/20/32/46 点真实 UIFont 测量，检查可见控件不重叠、位于标题栏范围内、触摸区域、单行/分行/菜单回退和无效临时几何。另有实际 UIKit 宿主测试，直接显示产品 Header 并改变传入的可用内容宽度/SwiftUI Dynamic Type，检查同一个 UISegmentedControl、字体/高度更新及外部选择保留；没有调整 UIWindow 尺寸或驱动 AlbumsView 的外层几何，不代替真实窗口重排验收。原生 valueChanged 还校验被上层拒绝的选择不会显示为已切换。不使用假截图或私人相簿。

NAS 实际检查：5 个受影响 Swift 文件 SwiftFormat0.64.5 scoped lint 和 diff 检查通过；直接源文本对照确认过滤、展开/关闭搜索、scope 切换、相簿激活和排序/列表切换业务成员未变，原 State/FocusState 声明保留。NAS 无 Swift/Xcode：新增测试、实际 Cmd-F/Escape、iPad 分屏/Stage Manager/横竖屏、VoiceOver 与指针交互仍未运行。后续统一 CI 和设备验收必须核对这些项目，不从纯几何检查宣称界面已通过。

Apple [keyboardShortcut](https://developer.apple.com/documentation/swiftui/view/keyboardshortcut(_:modifiers:)) 在当前前台 scene 的视图层级中解析命令，因此保留页面也必须显式禁用快捷键；[UISegmentedControl](https://developer.apple.com/documentation/uikit/uisegmentedcontrol) 保留原生 target-action 与选择表现，文字属性只改本实例，不设置全局 appearance。

回退本客户端切片只恢复标题栏布局与输入方式，无原片、服务器数据、账号或缓存迁移。全应用 iPad 适配与设备验收仍未完成。

## 独立后续：真实 UIKit 容器尺寸回归

分支 `codex/test-ipad-album-container-resize` 从 `89fc8e5` 接续，不改原布局分支。旧 32 个声明场景及断言完整保留；新增 1 个函数、2 个选择初值场景，使用真实 `UIWindow`、父控制器与四边 Auto Layout 约束挂载同一产品 Header。窗口在 1000×700、320×640、900×480 及原尺寸间变化；宽度来自实际 GeometryReader，不再注入 `state.width`，字号/size class 来自 UIKit traits，不直接注入 SwiftUI Dynamic Type 环境。

测试等待真实宿主 bounds、控件字体及命名坐标空间回执，再检查搜索/菜单 frame 在容器内且不相交、可见分段尺寸与其他入口不重叠、分行后高度变化、查询/选择保留及同一 UISegmentedControl 身份。产品行高/文字测量与原三层 padding 只提取到窄复用点，没有复制第二套布局算法。内容 clearance 与实际 padding 后 Header 高度比较；**没有驱动完整 AlbumsView 滚动、指示器或转场，不能把这一项称作完整内容布局验收。**

窗口位于普通窗口层级下方，不调用 makeKey；测试检查原 key window 保留，正常结束、抛错及取消都经 defer 清理，关闭动作可重复且断开 child/root 引用。公开 [traitOverrides](https://developer.apple.com/documentation/uikit/uiviewcontroller/traitoverrides-1z1cc) 和 [UIMutableTraits](https://developer.apple.com/documentation/uikit/uimutabletraits-13ja5) 在 iOS 17 起可用，未使用已弃用的 setOverrideTraitCollection 或私有 UIKit 字段。

NAS 实际通过 5 文件 SwiftFormat 0.64.5 lint（0/5）、diff 与独立 Node 源码边界审计。审计逐字确认原布局算法、Header 控件树、分段 target-action 及 AlbumsView 除窄复用之外的状态/排序/查询/导航/滚动路径未改，也核对 32+2 声明矩阵与真实 window/constraints/traits 调用存在；审计脚本为 `/volume2/codex-home/mental1104/tmp/remmich-album-window-source-audit-20261125.cjs`。同行只读未发现确定 Swift6/清理阻断。这些均不是编译或 UIKit 执行证据。

NAS 无 Swift/Xcode，新增两项、旧 32 项及真实窗口 resize 断言仍未执行。iPhone 15 Pro / iPad Pro 2022 11 英寸物理旋转、Stage Manager、键盘/指针、VoiceOver、搜索关闭及全页遮挡/滚动交互仍未验收。没有 push、CI、合 dev 或生产操作。
