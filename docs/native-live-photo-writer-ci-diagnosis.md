# PR9 合成 Live Photo 多轨供给诊断

固定源：`73dda3df890057a754d7a0f6dfece379c48213a2`，run `45544821063`。本修复从该提交新建独立 `codex/fix-native-live-writer-feed`；不修改当前受测分支、phone/UI、workflow、业务 Swift 或生产环境，没有推送或触发 CI。

## 实际证据

- 已独立下载 artifact `remmich-pr-app-test-evidence` / `14991986413`，ZIP SHA256 为 `86edc3cfc76d0dff363e0b5daaf6f5580f5aceb1274ad13a783c6bbde2f43ad9`，与 Actions 返回 digest 一致。证据位于 NAS `/volume2/codex-home/mental1104/tmp/remmich-pr9-app-73dda3d-45544821063.as2Tke/`，原 ZIP、原日志、xcresult 均保留。
- 原 `RemmichPRTests.log:1971–1973` 唯一失败是 `LocalLivePhotoRoutingTests.genuineNativeObjectRequiresStableFinalPair`，在工厂 `make → writeMovie` 生成 MOV 阶段抛出 `Writer readiness timeout`，耗时30.774秒。业务 fresh-pair/native 路由断言尚未开始；不是编译错误或该测试的2分钟时限到期。
- 原日志7065摘要为982 tests / 126 suites / 1 issue。对 xcresult 的 Zstandard 对象只读解压，根 IssueSummary 和 Thrown Error 均确认同一工厂错误，报告源位置为工厂121行。根 metrics 为1489参数化执行、failed1、skipped0，不能混同为982个函数/参数化执行。`decoded/index.json` 保留命中对象及偏移；2118对象解压成功，81其他对象未解码，不冒称完整xcresult结构解析。
- 同一次 run 的 `publicFileRequestBuildsGenuineNativePhoto` 随后实际成功，日志6251–6280保留完整320×240、3秒、1.5秒marker、真实PHLivePhoto资源收据，耗时1.750秒。成功路径同样有Fig -12900诊断，不能仅凭该码推断codec已失败。
- 73相对888仅改准备脚本/文档；73与已通过fed的业务、测试、API Swift树相同。因此本次触发是准备修复提交，但没有证据表明它引入了writer算法回归；没有运行新的对照构建。

## owning source 与最小修改

原工厂逐轨执行 `ready(audio) → append/finish → ready(metadata) → append/finish → ready(video)`。任何前轨需等待后轨先收到样本时，后轨在ready也永远得不到供给机会。旧三个等待点共用同一错误文本，而且把 writer 不再writing也报告为timeout，故本次旧证据不能进一步确定audio、metadata还是video先背压。

新工厂仍用真实 AVAssetWriter 的三轨输入和原样 H264/PCM/timed marker、90帧、尺寸、时长、UUID与文件/native校验。单MainActor每轮给所有ready轨一次供给机会，只有全部无进展才以原5ms等待让出执行器；不在某个轨的ready上阻塞其他轨。每轨全部样本提交后只finish一次，再进入原endSession/finishWriter。所有等待沿用原movie共享30秒预算，没有重试、加时、skip、替换PHLivePhoto或放宽断言。

错误现在区分 writer停止与真正期限到期，包含每轨已提交/总样本数、writer状态及NSError域码。原defer仍在错误/取消时cancelWriting；原失败目录/收据保留，成功lease仍由原测试清理。

新增2个测试函数/5个声明场景：跨轨ready依赖验证实际供给函数不会饿死后面的生产者，并分别核对writer停止/期限诊断。该端口仅在Tests内，所有回调留MainActor，不跨Sendable边界共享AVFoundation对象；它不替代两个既有真实native正例。

## 已验证与未验证

NAS SwiftFormat0.64.5工作流同范围 lint 为0/373需改、1个既有skip；diff检查、业务/CI源无变化和原真实native断言保留的静态核对通过。新增测试与修改工厂没有在Swift/Xcode上运行；不能由静态结果宣布本次CoreSimulator等待已在真实平台解决，也不能宣布PR9通过。

实施25/25 + NAS静态25/25 + Swift运行0/25 + 集成0/25 =50/100。回退只需撤回本Tests工厂/回归/文档切片；不涉及图库、API、原片或恢复资料。
