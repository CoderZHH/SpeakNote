# Mac Chrome 账号工具

这是原生 WorkBench 的独立辅助工具，只负责账号后台的 Chrome 会话。工作区、拍照、SQLite 与 CloudKit 业务均由 Swift 实现。

## 目录

- `src/server.mjs`：仅本机 Unix socket 协议，支持健康检查、打开、关闭、重置和退出。
- `src/account-session-manager.mjs`：每账号串行队列、窗口复用及独立持久化资料。
- `src/account-session-config.mjs`：固定平台地址、资料目录与 socket 路径规则。
- `vendor/`：唯一依赖 Playwright Core 的固定离线包，LICENSE / NOTICE 随包保留。
- `prepare.mjs`：从官方独立 Node.js 与离线包准备 Mac 资源，不依赖旧主应用或前端构建。
- `Helper-Info.plist` / `Helper.entitlements`：后台辅助 bundle 和 Node JIT 权限。

## 准备与测试

使用官方独立 Node.js 24.11+；`.nvmrc` 固定当前使用的 24.11.1。Node 授权文件必须随发行版提供。通过 `WORKBENCH_NODE_BINARY`、`WORKBENCH_NODE_LICENSE` 可显式指定运行时与授权文件。

```sh
apple/prepare-chrome.sh
npm ci --prefix tools/chrome --ignore-scripts --offline
npm test --prefix tools/chrome
npm run test:packaged --prefix tools/chrome
npm run test:integration --prefix tools/chrome
```

准备过程仅从本地固定包生成 `apple/Resources/ChromeRuntime/`，不下载浏览器，不安装扩展。集成测试使用临时目录和本机合成页面，仅检查隔离、Cookie/LocalStorage/IndexedDB 持久化、重复点击复用和定向重置，不访问已有账号或平台登录。

Mac 预览版不集成此工具。工程可独立编译和运行，无需 Node/npm。

## 数据边界

继续使用原账号 ID、目录哈希、socket 路径和 `data/account-sessions/`，不复制、转换或上传 Cookie。`WORKBENCH_SESSION_ROOT` 可用于隔离测试。Swift 发起请求，Node 独立管理 Chrome 进程；退出 WorkBench 不会删除会话。
