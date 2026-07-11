# myFlClash fork 差异与上游同步记录

本文记录本仓库相对上游 FlClash 的本地特性，目标是在以后同步原项目更新时，能明确哪些改动需要保留、哪些文件容易冲突、同步后要验证什么。

## 当前基线

- 本地仓库：本项目工作区
- 当前分支：`macos-tray-low-power`
- 当前 `origin`：个人 fork 仓库
- 上游 remote：`upstream`，当前同步来源为本机检出的 `/Users/hwdd/Developer/ai/FlClash`
- 已同步上游标签：`v0.8.94`（`7e7f1f8 Fix macos performance issue`）

上游 v0.8.94 同时更新 core、依赖和 Linux 静默启动，并将 `tray_manager`、`flutter_distributor` 改为 Git 依赖。同步时保留本 fork 的节能、批量输入、构建标识及手动 macOS 构建能力。

## 已提交的 fork 特性

### macOS 低功耗与托盘刷新优化

相关提交：

- `296cb74 perf(macos): 降低流量刷新频率以减少 CPU/GPU 开销`
- `b644bef perf(macos): 避免重复更新菜单栏状态项`
- `df10cdc perf(macos): 禁用菜单栏状态项`

主要目的：

- 降低 macOS 使用 FlClash 时的 UI/菜单栏刷新负载。
- 避免托盘标题或状态项频繁刷新导致 `WindowServer` 占用升高。
- 当前分支最终选择在 macOS 完全禁用系统托盘：`tray` 仅在非 macOS 桌面端初始化，因此不会创建状态栏图标、菜单或动态网速标题。

重点文件：

- `lib/common/tray.dart`
- `lib/manager/tray_manager.dart`
- `lib/manager/window_manager.dart`
- `lib/common/window.dart`
- `lib/providers/action.dart`
- `lib/providers/app.dart`
- `lib/providers/state.dart`
- `lib/state.dart`
- `lib/providers/generated/*.g.dart`
- `docs/MACOS_LOW_POWER_PLAN.md`
- `docs/MACOS_LOW_POWER_PHASE2_PLAN.md`

同步上游时注意：

- 如果上游改了托盘、窗口、流量刷新、provider 生成文件，这些文件是高冲突区。
- 合并后重点验证 macOS 菜单栏不再频繁刷新，主进程和 `WindowServer` CPU 不应回到旧的高占用状态。
- 如果重新启用托盘标题，应先确认刷新频率和重复更新保护仍然有效。
- 上游 `chen08209/tray_manager#1` 通过原生 `NSStatusItem.button` 消除自定义视图重绘，但 PR 仍未合并；当前 Git 依赖的 `main` 不包含该 PR，因此本 fork 继续禁用 macOS 托盘。

### macOS GitHub Actions 手动构建

相关提交：

- `9dee594 ci(macos): 支持本机触发构建`

主要目的：

- 提供 `workflow_dispatch` 入口，用于手动触发 macOS 构建。
- 支持按架构选择 `amd64`、`arm64` 或 `all`。
- 提供本地触发脚本。

重点文件：

- `.github/workflows/macos-build.yaml`
- `scripts/trigger_macos_build.sh`

常用命令：

```bash
gh workflow run macos-build.yaml -f arch=arm64 -f env=pre
gh workflow run macos-build.yaml -f arch=arm64 -f env=stable
gh workflow run macos-build.yaml --ref <branch-or-tag> -f arch=arm64 -f env=pre
```

同步上游时注意：

- 上游如果更新 `.github/workflows/build.yaml` 或新增发布流程，不要直接删除 `macos-build.yaml`。
- `build.yaml` 当前用于 tag push 完整矩阵构建；单平台手动构建走 `macos-build.yaml`。

## v0.8.94 同步时保留的 fork 特性

### DNS 列表批量输入

主要目的：

- 在 `fake-ip-filter` 等列表配置中支持一次粘贴多个值。
- 新增列表项时按逗号、分号、空白、Tab、换行拆分。
- 自动跳过已存在项。

重点文件：

- `lib/widgets/input.dart`
- `lib/common/string.dart`
- `test/common/string_test.dart`

验证建议：

```bash
fvm dart format lib/common/string.dart lib/widgets/input.dart test/common/string_test.dart
fvm flutter test test/common/string_test.dart
```

上游同步还加入了列表项目长度限制与新的重排接口；批量拆分与去重逻辑已和这些更新合并保留。

### About 页个人构建标识

主要目的：

- 保留 `pubspec.yaml` 的平台兼容版本号，例如 `0.8.94+2026071102`。
- App 内显示个人 fork 构建标识：`myFlClash 0.8.94`、`build: <commit>-dirty`、`source: myFlClash`。
- 避免把 commit id 写进 Flutter build number，降低 Android/iOS/macOS 打包兼容风险。

重点文件：

- `setup.dart`
- `lib/common/build_info.dart`
- `lib/common/common.dart`
- `lib/views/about.dart`

同步上游时注意：

- `setup.dart` 已写入 `BUILD_SOURCE`、`BUILD_COMMIT`、`BUILD_DIRTY` 到 `env.json`。
- dirty 判断使用 `git status --porcelain --untracked-files=no`，只看已跟踪文件，避免未跟踪计划文档污染构建标识。
- 如果上游重构 About 页或打包脚本，要保留这三个 dart define 的注入和展示。

### AGENTS 项目任务入口

主要目的：

- 将本 fork 的开发约定、命令、构建标识、DNS/fake-ip 入口、GitHub Actions 手动构建命令写入 `AGENTS.md`。
- 后续 AI agent 进入仓库时先从任务入口读取当前约定。

重点文件：

- `AGENTS.md`

同步上游时注意：

- 上游通常不会关心本 fork 的 `AGENTS.md`。同步时优先保留本仓库版本。
- 如果上游也新增类似 agent 指令文件，需要人工合并，不要直接覆盖本文件。

### fork 差异文档

主要目的：

- 本文件用于记录本 fork 的特性和同步策略。
- `.gitignore` 已不再忽略 `docs/`，确保本文档可以纳入版本控制。

重点文件：

- `.gitignore`
- `docs/fork-delta.md`

## 上游同步建议流程

首次配置原项目 remote：

```bash
git remote add upstream https://github.com/chen08209/FlClash.git
git fetch --no-recurse-submodules upstream --tags
```

同步前先确认当前本地改动：

```bash
git status --short
git log --oneline --decorate --graph --max-count=20 --all
```

建议把本 fork 特性整理成清晰提交后再同步上游。同步时可以选择 rebase 或 merge：

```bash
git fetch --no-recurse-submodules upstream --tags
git rebase v0.8.94
```

如果当前分支需要保留分叉历史，也可以：

```bash
git fetch --no-recurse-submodules upstream --tags
git merge v0.8.94
```

同步后重点验证：

```bash
fvm dart format setup.dart lib/common/build_info.dart lib/common/string.dart lib/widgets/input.dart lib/views/about.dart test/common/string_test.dart
fvm flutter test test/common/string_test.dart
```

同步上游后，优先按 `pubspec.yaml` / `pubspec.lock` 的 SDK 约束更新 FVM。v0.8.94 使用 `material_color_utilities ^0.13.0`，本 fork 已将 `.fvmrc` 和 macOS workflow 对齐到 Flutter 3.44.4；不要使用旧版 Flutter 3.38.x/3.41.x。

## 高冲突区域清单

- `.github/workflows/`：上游发布流程与本 fork 单平台手动构建可能冲突。
- `setup.dart`：上游打包逻辑与本 fork 构建标识注入可能冲突。
- `lib/views/about.dart`：上游 About UI 与本 fork 构建信息展示可能冲突。
- `lib/widgets/input.dart`、`lib/common/string.dart`：上游列表输入或字符串工具改动可能影响批量输入。
- `lib/common/tray.dart`、`lib/manager/tray_manager.dart`：macOS 托盘低功耗特性核心区域；当前 macOS 禁用托盘，若未来恢复必须先验证 Git 版 `tray_manager` 的原生重绘行为。
- `lib/providers/generated/`：同步后如果 provider 注解或 Riverpod 版本变化，需要重新生成并检查 diff。

## 保留特性检查表

- [x] 上游 v0.8.94 已同步，并保留本 fork 的节能与批量输入代码。
- [x] macOS 系统托盘已禁用，避免 `NSStatusItem` 重绘链路造成高 CPU / 发热。
- [x] 低功耗计划文档已归档到 `docs/`。
- [ ] macOS 使用时菜单栏/托盘刷新不会导致明显 CPU 或 `WindowServer` 占用升高。
- [ ] GitHub Actions 可以手动触发 macOS arm64 构建。
- [ ] `fake-ip-filter` 列表新增时可以批量粘贴并拆分多个域名。
- [ ] About 页显示 `myFlClash <上游版本>`、`build: <短 commit>`、`source: myFlClash`。
- [ ] `AGENTS.md` 仍包含本 fork 的开发约定和构建命令。
