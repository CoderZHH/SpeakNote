# 当前架构与项目结构

| 层 | 技术与职责 |
|---|---|
| 三个宿主 | `apple/Hosts/`，Mac WorkBench、iOS WorkBench、iOS 拍照助手 |
| 原生界面 | SwiftUI；系统 NavigationSplitView / NavigationStack / TabView、原生表单、媒体选择与预览 |
| 状态与业务 | Observation、Swift Concurrency；共享 WorkspaceStore / PhotoStore 与强类型命令 |
| 存储 | 系统 SQLite3；每份数据库一个 actor 串行事务，沿用既有表结构与版本升级 |
| 同步 | 保留 Swift CloudKit 和 Cloud Documents 实现，Mac 预览版仅使用本地数据 |
| 媒体与系统能力 | PhotosUI、ImageIO、Quick Look、AVKit、UserNotifications、ActivityKit / WidgetKit、Mac AppKit NSStatusItem / NSMenu |
| 账号后台 | 独立 `tools/chrome/`：Node + Playwright，仅管理本机 Chrome 会话 |
| 构建 | Xcode 26、Swift 6.2、Swift Package Manager；最低系统 26 |

共享包位于 `apple/Packages/WorkBenchKit/`：

- `Domain/`：模型、命令、快照及兼容存储格式。
- `Storage/`：SQLite、数据库升级、备份、迁移保护与写锁。
- `Business/`：任务、随手记、学习树、课程、专注、拍照等业务操作与 Store。
- `Sync/`：修改日志、同步确认、关联字段合并、冲突、删除标记与收件箱。
- `Services/`：CloudKit、Documents、通知、媒体、缩略图、Mac Chrome 调用。
- `Features/`：共用原生页面、设计参数、基础容器、行内编辑与控件。
- `Resources/`：当前 schema、示例课表、平台 Logo 和来源说明。
- `Tests/`：Swift 业务、存储、同步协议及系统服务测试和固定契约样本。

Mac 预览版用户数据默认存放于 Application Support，隔离测试可指定独立工作区。原生程序不依赖旧主应用源码或构建目录。数据库历史升级代码属于当前数据兼容能力，继续保留。

拍照助手只构造 PhotoStore 和共享服务，不实例化个人工作区数据库，也不开放个人导出或 Chrome 账号能力。

`WorkBenchActivity` 是同一本地 Swift Package 内的独立轻量产品，供 WorkBenchKit 与 iOS 实时活动扩展使用。扩展只读取 ActivityKit 下发的名称、累计时长和片段起点，不访问工作区数据库、附件、CloudKit 或 Chrome 会话。Mac 主窗口与菜单栏共用宿主持有的同一个 AppSession。
