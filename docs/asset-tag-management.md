# 原生标签树与照片关系管理

这是 `codex/feature-asset-metadata-management` 上接续 `40f190d` 的独立标签提交，入口“编辑与管理 → Tags”。保留 Remmich SwiftUI/当前认证通道；没有修改搜索 SDK、服务端、官方 mobile、生产数据或今晚候选，也不触发 CI/push。

## 核对的官方合同

依据父 Fork `dev` `301d51044c41d7f67044c2e58d3bdb588737961c` 的 `tag.controller.ts`、`tag.dto.ts`、`tag.service.ts`、`tag.repository.ts`、`asset.util.ts`、`utils/access.ts` 及 Web TagEdit/TagCreate/AssetTag/DetailPanelTags；客户端上游仍 `672f02e`，未同步。

| 操作 | 方法/精确成功码 | 请求与影响 |
| --- | --- | --- |
| 个人树 | `GET /api/tags` 200 | 当前账号标签；保留 id/parentId/叶名 name/全路径 value，不从搜索候选或缓存取写状态 |
| 当前照片 | `GET /api/assets/:id` 200 | 必须同 ID 且 tags 数组真实出现；缺键/null 不当成无标签 |
| 创建 | `POST /api/tags` 201 | 只发单叶名 name、可选 parentId。根父级省略，不发 color 默认值，不通过斜线偷偷创建多级，也不自动关联照片 |
| 改名 | `PUT /api/tags/:id` 200 | 只发 name，保留父级/颜色；服务器递归更新后代完整路径，并同步受影响照片的 EXIF 标签和 sidecar 任务 |
| 删除标签 | `DELETE /api/tags/:id` 204 | 级联删除后代与全部照片标签关联；照片/视频原片保留。fresh 读后检查已知后代闭包均不再存在 |
| 加/减当前照片关联 | `PUT` / `DELETE /api/tags/:id/assets` 200 | 完整 body 只有 `{ids:[当前assetID]}`；必须唯一同 ID、success=true 且无错误。逐项 duplicate/no_permission/not_found/validation 明确不是成功，unknown 为未确认，不用 bulk count 代替身份回执 |

TagRead/Update/Delete/Asset 都要求标签 owner；新增关系还要求 asset.update。标签 owner 通过 TagDelete 可以移除本标签关系，但本原生页保守限制为当前资源 owner、未回收，符合 Web 详情入口；不扩大服务器权限或自动 elevated 登录。

## 操作与错误边界

页面真实重载“个人树 + 当前照片”，单命令审阅固定完整快照与账号/页面代际。确认后再次真实读取两者，变化则要求重新审阅，不发送写。每次只有一个创建/改名/删除/加减动作，没有混合批处理或隐式重试。

树写入精确核对创建/改名的 ID、name、parentId 和完整路径；改名回读还核对已知后代路径，删除按 parentId 闭包判断影响。所有回读同时核对照片关系能在当前树中对应。树/照片这两个 GET 不是原子读取，预检与写也不是 CAS，其他客户端的并发修改可能要求再次手动重载。

全局改名/删除与单照片关联有不同确认文案。删除明确展示已知后代数量与“所有照片关联移除、照片保留”；未知关联照片数量不编造。停止等待不声称回滚。写已确认但读后失败时保留保存事实，禁用下一次写；未知成功码、畸形回执、网络和取消只使当前账号读者失效，不重发。账号/端点/页面失效取消会话工作并撤销旧发布权；后台停止等待，恢复不自动写。

不使用 `PUT /tags/assets` 返回 count 的批量接口，不手工替换照片的完整标签集，不写 color:null、不实现重父级/标签颜色编辑，不修改其他媒体属性或 Live Photo 配对关系。服务端 EXIF/sidecar 路径是既有机制，HTTP 确认不等于所有后台 sidecar 已完成。

## 验证与后续

新增 47 个真实 Store→manager→client→URLSession 合成场景：根/子创建、根/叶改名及后代回读、全树删除、加/减关系；各写方法精确状态/ID/父级/路径与完整 body；非成功成员/重复回执/错误成功码；fresh GET 错资源、缺键/null、重复树/v5 UUID、HTTP/所有权/回收站；审阅后变化、保存后读失败；三阶段取消和账号/端点切换。复用的测试会话拦截所有 host，Bearer/body/无 Cookie 均检查；业务提前失败唤醒观察者，超时/取消清理释放门，并等待实际被 hold 的 HTTP 响应任务结束，无时序 sleep。

NAS 已做 SwiftFormat 0.64.5 限定格式化/lint、shell 语法、15 个固定合成 JSON/模板检查及 diff 空白检查。**没有 Swift/Xcode，47 场景未编译/未执行；服务黑盒、数据库级联/sidecar、iPhone/iPad UI 与官方客户端共存未验**。前一元数据片 33 场景也仍待独立 macOS 验证。

原标签切片之外的阶段 4 内容包括日期 targeted refresh、共享相簿、重父级（官方 UpdateTag 无该父级字段）和跨照片批量标签等，各独立分支状态另记。标签颜色的后续实现见下节；现有搜索标签候选在正常 fresh 读取时获得服务器新树，不宣称所有已打开筛选器已完成同步验收。

回退本客户端提交可移除入口；已经完成的标签改名/删除和关系变更不会自动恢复。删除树没有客户端自动撤销；恢复需用户根据实际服务器状态重新建立标签/关联，不能仅切回客户端版本。

## 独立后续：标签颜色

`codex/feature-asset-tag-colors` 从 `36a8500` 接续，不重复标签树/关系或混入其旧 metadata 祖先。当前父 `4af6a3a3c` 的官方/main TagUpdate/controller/service 合同一致：`PUT /tags/:id` 精确 200；仅发送 color 即保留原 value，不触发改名的资产 EXIF/sidecar 路径。

选中标签后新增默认“保留”的颜色意愿及原生 ColorPicker，支持透明度。设置支持官方 RGB/RGBA/RRGGBB/RRGGBBAA 并规范为六/八位 sRGB；无法表示的选色不开放提交。保留省略键且无写动作，设置只发字符串，清除只发 `color:null`。改色另有确认，说明该标签所有显示位置都会变化，名称、层级、其他颜色与照片关系保留。

官方 mapTag 将数据库无颜色映射成 undefined，因此合法清除回执/后读可省略 color。新解码保留 hasColorField 区分缺键与显式 null，错误类型不降级成 nil；此已证响应映射不构成用户清除意愿。回执核 ID/name/value/parentId/createdAt，fresh 目录和照片后读再核颜色、其他标签及完整关系。复用原单命令预检/精确写/回读/账号与页面退休；未知结果重新读取，不自动重试。

新增 9 函数/41 声明场景：颜色长度/alpha、三态 JSON、缺键/null/错误类型；真实 Store→manager→会话内 URLSession 的七请求闭环；预检改变、错误状态/身份/定义/颜色及额外关系影响；三个真实 HTTP 门内取消/换号。原 47 场景及 HTTP 夹具未改。NAS 实际 7 文件 SwiftFormat0.64.5 lint、bash/diff 和 Node 审计通过，后者解析 13 个实际 Swift JSON 片段、核 8 个独立 RGBA 向量与 9/41 声明矩阵，逐字核原传输/生命周期/测试和夹具未改。脚本 `/volume2/codex-home/mental1104/tmp/remmich-tag-color-source-audit-20261125.cjs` 只审源码，不是 Swift/HTTP 运行。

颜色开发功能已接入口；Swift 编译、41 场景、原生选色器/透明度及真实服务/设备统一留到最后验收。本轮无新 CI/push/实服务验收/生产操作。回退本后续保留原标签管理，不自动撤销已确认的服务端颜色，无本机数据格式迁移。
