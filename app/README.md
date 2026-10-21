# Storage Watch（存储空间看板 · macOS App）

菜单栏常驻的 Mac 空间账本。SwiftUI 外壳 + 本机 Python 采集引擎（`../engine/monitor.py`），
数据只保存在本机 `~/Library/Application Support/StorageWatch`。

## 构建

```bash
cd app
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk bash build-app.sh
open "build/Storage Watch.app"
```

只需 Command Line Tools（无需完整 Xcode），最低系统 macOS 13，目标架构 Apple Silicon。

运行前提：系统 Python 3.10+，或 `/opt/homebrew/bin/python3` / `/usr/local/bin/python3` 之一。
app 不内嵌 Python 运行时，以保持体积轻量（当前约 3 MB）。

## 架构

```text
app/Sources/StorageWatch/
  StorageWatchApp.swift   入口：MenuBarExtra 状态栏、启动流程、应用生命周期
  WindowController.swift  按需创建/复用主窗口（MenuBarExtra app 没有默认主窗口）
  Engine.swift            拉起 Python 引擎子进程，对接其回环 HTTP API
  Store.swift             轮询引擎状态，向 UI 暴露看板数据
  Models.swift            API 数据模型与格式化
  MenuPanelView.swift     状态栏下拉面板（Magpie 风格：可用空间 + Top 变化 + 快捷操作）
  MainWindowView.swift    主窗口：指标卡 / 趋势图（Swift Charts）/ 目录变化表 / 工具模块
  SettingsView.swift      原生设置（监控目录、间隔、阈值、通知）与检查更新
  Plugins.swift           FeaturePlugin 协议与注册表——新功能（缓存清理等）在此注册
  UpdateChecker.swift     GitHub Releases 更新检查（发布前把 repository 改成实际仓库）
engine/monitor.py         采集引擎（标准库，无第三方依赖）
```

## 扩展新功能

1. 新建 `struct MyPlugin: FeaturePlugin`，实现 `makeView()`。
2. 在 `Plugins.swift` 的 `PluginRegistry.all` 注册。
3. 需要采集数据时，可给 `engine/monitor.py` 增加 `/api/...` 端点，`Engine.get/post` 已通用。

## 生命周期

app 启动时拉起采集引擎并传入 `--parent-pid`；app 退出后引擎自动停止，
不会留下后台常驻进程。历史记录保留在 Application Support，下次启动继续沿用。

## 更新机制

设置 → 关于与更新 → 检查更新：读取 GitHub Releases 最新 tag，与
`CFBundleShortVersionString` 做语义化版本比较，有新版本时打开发布页。
后续可无缝换成 Sparkle。

发布新版本时：

```bash
# 更新 Resources/Info.plist 的 CFBundleShortVersionString 与 CFBundleVersion
./build-app.sh
ditto -c -k --keepParent "build/Storage Watch.app" "build/StorageWatch-0.2.0.zip"
gh release create v0.2.0 "build/StorageWatch-0.2.0.zip" --generate-notes
```
