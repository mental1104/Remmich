# 固定888的iPhone模拟器准备失败

- 客户端固定源码：`888e944ef4304ec1f5187139663749ffd8e8ab84`；run `45538155086`已终态failure。
- 本轮直接读取phone artifact `14990080198`的本地原始日志和device.json；设备为iPhone17e模拟器、iOS27.2，选定UDID为CD90C719-F4A8-40D6-9AC3-51BE522C2705，记录选择时状态Shutdown。
- 原始xcodebuild.log只有以下三行，没有调用xcodebuild或执行任何iPhone UI用例。不能称为搜索业务断言失败；也没有日志足以证明CoreSimulator内部卡住的原因。

~~~text
Simulator preparation: xcrun simctl boot CD90C719-F4A8-40D6-9AC3-51BE522C2705
Simulator preparation: xcrun simctl bootstatus CD90C719-F4A8-40D6-9AC3-51BE522C2705 -b
Simulator preparation timed out after 180 seconds.
~~~

修复位于独立`codex/fix-ci-phone-boot-timeout`，直接从888创建，不含SavedUI418或其它功能祖先。原脚本只允许CI命名tablet在首次bootstatus被脚本判定超时时恢复一次；这次将同一规则扩展到已由IPHONE_SIMULATOR_ID验证和选定的命名phone。仅重启当前选定UDID，不换设备、不删除runtime、不全局清理。

恢复顺序仍是已有受限shutdown→boot→bootstatus，第二次失败或任一恢复命令失败按原退出码结束，不进入第三轮。首次超时和恢复信息保留在追加日志中。原生simctl返回124不能冒充脚本超时；普通Mac、显式UDID、初始boot失败及其它非超时失败不恢复。实际xcodebuild/UI仅执行一次，失败码不被准备恢复吞掉。

没有更改单步默认180秒等待、1–600合法范围、job预算、runner、触发器、工作流、两个scheme、Swift业务或原五测32断言。没有混入新的保存面板类选择器。root已核同轮其它步骤成功；本切片只针对上述phone准备证据，不反向推断其余结果或宣称新CI已过。

## 本轮实际验证

- `bash -n`两个脚本与`git diff --check`通过。
- 实际运行原准备脚本的固定simctl/xcodebuild桩：**37/37通过，exit0**。保留原27个场景；旧phone不恢复场景按新合同检查“只恢复一次，第二次超时仍124”，新增10个phone边界场景。
- 明确断言首次超时可恢复、第二次超时/原生错误失败、原生124/普通错误不恢复、非CI/显式UUID不恢复、初始boot及恢复shutdown/boot失败原码、准备恢复后UI仍失败且不重试；检查精确调用序列、同UDID、无其它设备动作、挂起子进程已回收。既有tablet及串行设备行为仍通过。
- 原始证据、命令日志、完整argv、退出码、子进程记录和静态审计保留于`/volume2/codex-home/mental1104/tmp/remmich-ci-phone-startup-20261125/`。
- NAS桩没有执行Xcode或真实模拟器。实际macOS恢复效果及后续完整CI仍未验证，不能从37项通过推断phone UI已运行。

本切片四关口为实现25/25、可用静态/NAS检查25/25、macOS执行0/25、集成0/25（50/100）。未推送、触发CI、合dev或改父仓库/生产；后续由root统一更新PR9并单独验证。回退只需撤销本脚本/桩改动，恢复tablet-only行为，无媒体或数据恢复事项。
