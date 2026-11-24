# Live Photo音频异步所有权

此独立切片从 `2a712c2` 创建 `codex/feature-live-photo-audio-controller`，仅新增一个 `@MainActor @Observable` 控制器及专项测试。它复用现有 `ViewerAudioSessionControlling`，不修改系统音频配置、播放器宿主、Photos/Media、共享协议、服务端、原片或CI。

`LivePhotoPlaybackAudioController(session:)` 默认使用现有 `ViewerAudioSessionController()`，只公开只读 `ready: Bool`、`activate(validateContext:failure:) -> Task<Bool, Never>` 及同步 `deactivate()`。每次激活换独立UUID、取消旧Task并立即清ready；真正调用协议前和await成功/catch后都先核UUID、Task取消与宿主校验。当前成功才ready=true/返回true；当前失败才调用failure。旧完成直接false，不改变新状态，不停用新会话。Task收尾也检查UUID，避免failure回调同步激活下一轮时清掉新取消句柄。

宿主仍拥有播放token、manager代际、payload、held及声音偏好，并把这些条件放进 `validateContext`。松手、关闭声音、换播放或销毁应显式 `deactivate()`；它同步退休旧Task/ready，再调用既有协议停止。`activate`本身不额外停止会话。调用方await结果后仍需重新核对自己的播放token/上下文，再决定是否unmute；旧false不能被用于清除新轮状态，已经完成的旧true也不能当作永久授权。

测试含10函数/16case，调用真实产品控制器与实现真实协议的可控异步会话。会话使用 `CheckedContinuation`，故意不合作取消；测试先等真实协议入场，再手动完成旧/新响应，观察ready、返回Task、failure及实际deactivate次数。覆盖：当前成功/失败，旧success/旧failure在新激活已开始或已成功之后完成，初始/await后上下文失效，直接取消和显式停声，进入前取消，同步清ready，以及failure重入后新Task仍可取消。等待入场有5秒界限，fixture收尾在锁外释放全部continuation并拒绝迟到新挂起，不把缺失入场当作成功。

实际NAS检查：两文件SwiftFormat 0.64.5格式化/lint与Git whitespace检查、async协议/Sendable/continuation及Task代际路径静态复核。**NAS无Swift/Xcode，Swift编译与16case均未执行。** 未触系统AVAudioSession、实际声音、PHLivePhoto、媒体或生产网络；真实音频会话、宿主接线及设备播放仍待验证。独立分支不推送、不启动CI；回退移除新增控制器/测试/记录，不改变媒体或持久化资料。
