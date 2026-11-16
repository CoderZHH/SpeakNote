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

## 发布 Mac 更新

Mac 版从 [SpeakNote 下载仓库](https://github.com/CoderZHH/SpeakNote-Releases) 读取 `appcast.xml`。更新包使用该仓库的 Release 附件，源码仓库无需公开。

1. 在 `project.yml` 提升 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，运行 `apple/generate-project.sh`。为 `WorkBenchMac` 生成通用 Release Archive，使用 Developer ID 签名并完成 Apple 公证。
2. 公证通过后，将公证凭证附到 `SpeakNote.app`，用 `ditto -c -k --sequesterRsrc --keepParent` 把应用打成 ZIP。先将 ZIP 发布到下载仓库的对应 Release。
3. 用与依赖版本匹配的 Sparkle 官方工具生成更新清单。发布签名密钥放在发布 Mac 的登录钥匙串，账户为 `io.github.coderzhh.speaknote.updates`。使用仅存放本次 ZIP 的临时目录生成清单。

```sh
generate_appcast --account io.github.coderzhh.speaknote.updates \
  --maximum-deltas 0 \
  --download-url-prefix 'https://github.com/CoderZHH/SpeakNote-Releases/releases/download/<tag>/' \
  /path/to/update-directory
```

确认清单中的版本、附件链接和签名后，把生成的 `appcast.xml` 更新到下载仓库 `main` 分支。使用前一版应用的「检查更新…」确认能够找到最新版。
