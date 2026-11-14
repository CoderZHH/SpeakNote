# 原生工程

使用 Xcode 26 与 Swift 6.2。打开 `SpeakNote.xcodeproj`，选择 `WorkBenchMac` 并运行，产物为 `SpeakNote.app`。编译 Mac 预览版不需要个人签名资料、CloudKit 容器、Node 或 Chrome。

需要隔离测试时，给 Mac 预览版设置 `WORKBENCH_WORKSPACE_ROOT` 指向空测试目录。App 会在该目录下新建 `data/`。

从仓库根目录运行：

```sh
apple/check-design-system.sh
python3 apple/check-project.py
swift test --package-path apple/Packages/WorkBenchKit
```

调整工程结构后，使用 XcodeGen 2.44 或更新版本运行 `apple/generate-project.sh` 并提交生成后的工程。界面规则见 [layout.md](layout.md)。
