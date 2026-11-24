# iPad 编辑器交互切片

接续 `ee01628` 可视编辑和 `be0a181` 媒体来源隔离。本切片只修改 Editing 领域/页面及其测试，不触碰共享 AppShell、查看器、相簿、备份或浏览模块，也不修改服务端、API、生产或 CI。

## 行为

- 同一拖动持续期间，窗口尺寸/图片 aspect-fit 区域变化的首个事件只重新建立锚点，后续按新比例继续；移动与四角缩放都不重复累计旧屏幕位移。外部精确输入/辅助功能调整会使旧锚点失效，不能被旧事件覆盖。
- 触摸/指针点击选框后，硬件方向键移动一像素，Shift 为十像素，Option 改变右下边（宽高），Shift+Option 为十像素缩放。键盘操作始终使用原图像素并限制合法范围，Cmd/Control 组合交给其余页面。取消、确认、旋转的既有快捷键保留。
- 选框成为一个可聚焦元素，VoiceOver 读取 X/Y/宽/高像素；上下调整缩放范围，命名操作可向四个方向移动一像素。装饰角柄不再成为无操作的辅助功能焦点；44 点可拖区域和指针悬停仍保留。精确 Stepper 是另一个可操作入口。
- 大辅助字号强制上下排列取景与结果，不因 iPad 宽度足够就缩窄文字。较窄多任务窗口沿用纵向滚动；几何改变不改草稿像素、账户或资源版本。

使用 Apple 官方 [onKeyPress(keys:phases:action:)](https://developer.apple.com/documentation/swiftui/view/onkeypress(keys:phases:action:)) 和焦点 API。该 API 仅在获得焦点时接收硬件键盘事件，不能宣称页面在任何焦点状态都抢占方向键。[onMoveCommand](https://developer.apple.com/documentation/swiftui/view/onmovecommand(perform:)) 的当前可用平台只有 macOS/tvOS，所以此 iPad 功能没有调用它。

## 验证边界

新增领域测试覆盖移动与四个角在缩放窗口中的连续性、外部调整/重置后旧锚点拒绝、空视口/NaN 输入、原图一/十像素移动、缩放固定左上点和边界。它们调用实际 Canvas 使用的 `AssetEditCropDragSession` 与像素方向操作；没有伪装成 UIKit 手势或 VoiceOver 硬件验收。

NAS 已跑四个受影响 Swift 文件的 SwiftFormat 0.64.5 scoped lint 和 diff 检查。NAS 无 Swift/Xcode，以上测试、硬件焦点、指针、VoiceOver、Dynamic Type 与实际 Stage Manager/横竖屏交互仍未执行，等待统一 macOS CI 与 iPhone 15 Pro/iPad Pro 2022 11 英寸验收。阶段 3 的全应用多任务/键盘/指针与查看器异步编辑刷新仍未完成。

回退本切片只改变输入方式和拖动连续性，保留原图、已保存编辑和离线资源，不需要数据回滚。
