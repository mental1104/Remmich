# 备份与相簿同步开发整合

2026-11-25，codex/integrate-photo-backup-album-sync从最终搜索29d5bf7正常合入f13f7e3（包含PR11/e451），保留各独立分支。用户明确搜索开发100%、验收统一后置；本分支只整合开发，不启动新CI或宣称统一验收通过。

整合选择/排除、RAW+JPEG双原图语义、前台自动备份、持久停止、未尝试尾队列恢复、相簿响应兼容，以及首片已有owner目标的明确映射/预览/手动增量同步。服务器已有交集使用当前metadata关联，不读取Immich/iCloud原片来组织相簿。

仅change.log与fork-compatibility两处追加记录冲突，保留双方每一原行和顺序；产品源码无冲突。root实际检查：全部Remmich产品源码、Packages、Scripts、workflow、项目逐字等于f13；API/生成SDK、脚本、workflow、项目、全部UI与合成Live夹具逐字等于29d。相比f13仅四个测试文件继承29d的新修复，没有手改新增备份源码或测试。

NAS全workflow范围SwiftFormat0.64.5为0/390需改、1既有skip，diff通过。首次把--lint放多路径前导致参数拒绝，纠正为路径后标志后实际检查通过。新增Swift场景、编译、当前服务联调、设备/交互均未验证，留最终统一阶段。

相簿创建、编辑者目标、完整自动同步及OS后台仍是后续项。本分支未push/CI/合客户端dev/改父gitlink/生产，无服务端或官方mobile改动。回退不得删除恢复账本、原片，不能据代码回退宣称远端相簿关系撤销。
