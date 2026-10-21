# Storage Watch · 存储空间看板

菜单栏常驻的 macOS 空间账本：每小时记录一次目录占用，用趋势图和增减排行回答  
「今天哪个目录突然变大了」。不打开文件内容、不上传任何数据、不自动删除文件。

**原生 SwiftUI 界面 + 本地 Python 采集引擎**，最低 macOS 13，无需安装第三方依赖。

## 功能

- **菜单栏常驻**：可选显示可用空间或今日变化，点开即看磁盘占用、趋势和增长最快的目录。
- **目录变化排行**：对比上次、今天或最近 7 天；按路径搜索，一键在 Finder 中显示。
- **趋势图**：24 小时 / 7 天 / 30 天的可用空间曲线，全部基于真实记录，不虚构休眠期间的数据。
- **原生设置**：监控目录、记录间隔、保留层级、增长提醒阈值、macOS 通知。
- **隐私优先**：只读取文件元数据；采集引擎只监听 `127.0.0.1`，写操作需要一次性令牌。
- **可扩展**：`Plugins.swift` 预留功能模块接口（缓存清理、大文件速览等）；`UpdateChecker.swift` 已接好 GitHub Releases 更新检查。

## 安装

需要 macOS 13+ 与 Python 3.10+（用于采集引擎）。

```bash
cd app
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk bash build-app.sh
open "build/Storage Watch.app"
```

把 `Storage Watch.app` 拖进「应用程序」即可。首次启动会在菜单栏出现图标并建立第一份基线。

## 数据

历史记录保存在 `~/Library/Application Support/StorageWatch/history.sqlite3`。  
退出 app 后采集引擎会一起停止，不会留下后台常驻进程。

从旧版网页看板升级时，把旧的 `data/history.sqlite3` 复制到上述目录即可沿用历史。

## 目录结构

```text
app/                        SwiftUI app（Swift Package，无需 Xcode 工程）
app/Sources/StorageWatch/   界面、引擎管理、数据模型、插件与更新接口
engine/monitor.py           扫描、SQLite、历史比较、定时器、本地 HTTP API
tests/                      采集与 API 的关键行为测试
```

## 开发

```bash
cd app && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk swift build
python3 -m unittest discover -s tests -v
```

测试覆盖扫描统计、权限丢失、硬链接、层级限制、历史保留和 API 安全边界。

## 权限说明

macOS 保护 Mail、Messages 及部分系统目录。如需扩大覆盖，可在  
「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中加入运行采集引擎的 **Python.app**。  
工具不会提权到 root，也不会为了"完整"而绕过系统权限。

## 统计口径

- 目录大小按 `st_blocks × 512` 估算，不解析 APFS 克隆/共享块。
- 不跟随符号链接，不进入其他挂载卷；硬链接只计一次。
- 目录不可读时标为"不完整"，不会把权限变化误判为删除或增长。
- 父目录包含子目录，排行中的父与子变化不可相加。

## 许可

发布到 GitHub 前补充 LICENSE。
