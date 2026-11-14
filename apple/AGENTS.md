# Apple 原生界面约定

修改界面前阅读 `layout.md` 和 `Packages/WorkBenchKit/Sources/WorkBenchKit/Features/WorkbenchDesign.swift`。

- 页面留白、列表边距、字号角色、颜色、行高、圆角和表单宽度使用共享设计参数。不要在业务页面添加平台专用的负边距补丁。
- 组合页面使用 `workspacePage()`；独立业务列表使用 `WorkspaceList`。若外层页面已经负责留白，内部列表用 `inset: 0`，避免重复 padding。
- 业务内容不直接使用裸 `List`。`AppRoot` 的原生侧栏属于系统导航角色，保留系统样式。
- 小型新建面板使用 `WorkspaceEntrySheet` 和 `workspaceInput()`；复杂 Mac 表单使用 `workspaceSheetForm(height:)`，不能依靠单个 Form 行推算弹窗大小。
- 任务、随手记和集合继续复用行内编辑、备注、关联与 Store。不要为了样式重新写一套保存逻辑。
- 执行 `apple/check-design-system.sh` 检查容器接入。新增合理例外时说明布局角色并同步更新规范和检查规则。
- 布局修改需要核对空内容、长文字、窄窗口、列表边缘与键盘出现时的操作。编译或单测通过不等于完成视觉验收；工具无法读取时如实记录限制。
