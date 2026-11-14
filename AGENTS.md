# 随口记

这是 Apple 原生项目，主程序使用 SwiftUI、共享 Swift 业务包和系统 SQLite3；最低支持 macOS 26 / iOS 26。工程入口为 `apple/Suikouji.xcodeproj`。

- 原生修改遵循 `apple/AGENTS.md` 与 `apple/layout.md`。不再引入旧 Web、Tauri 或 Rust 主应用。
- `tools/chrome/` 是唯一独立 JavaScript 工具，只负责 Mac Chrome 账号会话，不承担工作区业务。
- `data/` 内的数据库、附件、账号会话与历史备份是用户数据。保留原路径、身份、关联和同步元数据；测试使用隔离目录。
- 构建 Mac 预览版无需个人签名资料。签名资料和服务凭据不可提交。
- 常用验证：`apple/check-design-system.sh`、`swift test --package-path apple/Packages/WorkBenchKit`、`npm test --prefix tools/chrome`。根据实际修改选择必要的构建和回归，并如实记录真机/云端验收限制。
