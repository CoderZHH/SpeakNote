# 随口记

原生 Mac 工作台。把任务和随手记放进「今日」，用项目组织进度，在日历安排时间并开启专注。学习与课程也可以单独使用。界面以简体中文为主。

这个仓库目前用于首版开发，尚未提供正式安装包。预览版需要 macOS 26 和 Xcode 26。

1. 打开 `apple/Suikouji.xcodeproj`，选择 `WorkBenchMac` 和本机 Mac。
2. 点击 Run。首次启动会创建空工作区，默认数据目录为 `~/Library/Application Support/WorkBench Preview/`。
3. 如需试用示例内容，在「设置 → 导入备份」选择 [示例工作区](docs/examples/workbench-demo-data.json)。也可在课程页单独载入示例课表。

首次启动可选择连接微信助手。扫码并使用自己的 DeepSeek API Key 验证后，试着从微信发一条待办。也可以稍后从侧栏的「微信助手」继续。接收消息时需要保持 WorkBench 打开。预览版使用本机存储，未启用 iCloud。

在设置中可以导出或导入工作区记录。JSON 导出不包含附件文件，如需保存附件，请退出 App 后备份整个数据目录。

查看[开发说明](apple/README.md)、[架构](docs/architecture.md)和[第三方组件说明](THIRD_PARTY_NOTICES.md)。
