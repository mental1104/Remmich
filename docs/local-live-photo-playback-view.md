# 本机Live Photo播放表面

此切片从 `44dbafd` 独立创建 `codex/feature-local-live-photo-playback`。只新增 `LocalLivePhotoPlaybackView.swift` 与focused测试；不改现有远端 `LivePhotoPlaybackView`、Media、reader、共享领域文件、服务端或CI。它尚未接入用户实际Viewer，接线由主代理另做。

调用方传入真实 `PHLivePhoto`、`assetID`、`contextGeneration: UUID`、`isHeld`、`soundEnabled` 和 `playbackEnded: @MainActor (String, UUID) -> Void`；可选 `playbackBegan` 同签名。generation由宿主提供，回调总带其绑定身份。调用方仍必须验证当前账号/路由/页面、权限、Photos源版本、服务端配对及回退资格；这个表面不请求资源、不解释配对、更不能作为备份完成凭据。

实现复用现有 `LivePhotoPlaybackState`：准备完成且未按住不会自动start；新长按只发一次 `.full`，自然结束后仍按住保持结束状态，松手再长按才重播。声音仅更新 `isMuted`。iOS表面使用 `UIView.contentMode = .scaleAspectFit`；禁用原生播放手势和触摸，让既有外层长按拥有交互。

payload对象、asset或context变化会先撤销旧delegate/token，再stop/clear旧Photos对象并安装新 `PHLivePhotoView`。每次start另建relay，事件同时核native view、token、full style及当前播放状态；旧relay、hint、其他view、重复begin/end以及销毁后的事件不能进入当前宿主回调。松手/销毁停止不会虚构自然结束事件。

Apple主证：

- [PHLivePhotoView](https://developer.apple.com/documentation/photosui/phlivephotoview)：iOS继承UIView，提供 `livePhoto`、`isMuted`、`playbackGestureRecognizer` 与手动播放接口。
- [PHLivePhotoViewDelegate](https://developer.apple.com/documentation/photosui/phlivephotoviewdelegate)：公开 `@MainActor` delegate及canBegin/willBegin/didEnd签名。
- [full](https://developer.apple.com/documentation/photosui/phlivephotoviewplaybackstyle/full)：完整动态/音频内容及开始结束过渡。
- [stopPlayback](https://developer.apple.com/documentation/photosui/phlivephotoview/stopplayback())：公开停止接口；本组件不实现私有seek或资源拼装。

专项测试含10函数/14case：未按住/静音偏好、一次hold只播一次、新hold重播、先撤delegate再stop的同步结束门禁、同view旧relay、asset/context/native替换、hint/其他view、播放中声音改变、真实容器布局和Representable销毁入口。测试调用真实Coordinator/Container及delegate方法；PhotosUI子类只记录公开start/stop命令，未创建 `PHLivePhoto()`、未请求Photos、未下载媒体，也未把命令计数称作实际播放成功。payload正例无法在NAS合成，因此实际payload替换分支和系统自然播放/声音仍待真实PHLivePhoto验证。

实际NAS检查：两文件SwiftFormat 0.64.5格式化及lint、Git whitespace检查、静态Apple签名和旧事件路径复核。NAS无Swift/Xcode，Swift编译及14case均**未执行**；模拟器/真实iPhone、当前Photos编辑内容、合法Live Photo配对、按住/松手动画、系统音频与宿主回退均**未验收**。本提交不推送、不启动CI、不改变当前候选；回退仅撤销新增文件/文档，未触及相机原片或已保存恢复资料。
