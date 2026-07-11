# AGENTS.md

@/Users/hwdd/.codex/RTK.md

本文件是本仓库给 AI coding agent 的任务入口。当前仓库是用户基于上游 FlClash 维护的个人 fork，优先服务自用稳定性、可追溯构建和小范围改动。

## 工作原则

- 先读用户点名的文件、日志或配置，再扩展到相关模块。
- 保持改动小而可验证，不做无关重构，不主动提交或推送。
- 代码注释必须使用简体中文；没有必要时不要新增注释。
- 处理现有未提交改动时，只修改本任务相关文件，不回退用户或其他任务留下的改动。
- Commit message 使用简体中文 Conventional Commits，格式为 `<type>(<scope>): <description>`，scope 用小写英文目录或模块名。

## 当前仓库状态提示

- `pubspec.yaml` 当前版本为 `0.8.94+2026071102`，平台版本号仍按 Flutter 规则维护，不要把 commit id 写进 `+` 后的 build number。
- 个人构建标识采用“上游版本号 + 仓库名 + 短 commit id + dirty 标记”：`setup.dart` 会写入 `BUILD_SOURCE`、`BUILD_COMMIT`、`BUILD_DIRTY` 到 `env.json`，About 页通过 `lib/common/build_info.dart` 展示。
- `.fvmrc` 当前是 Flutter `3.44.4`；`pubspec.lock` 要求 Flutter `>=3.44.0`。不要使用旧版 Flutter 3.38.x/3.41.x，否则 `material_color_utilities` SDK pin 会导致依赖解析失败。
- macOS 低功耗计划位于 `docs/MACOS_LOW_POWER_PLAN.md` 和 `docs/MACOS_LOW_POWER_PHASE2_PLAN.md`，属于仓库文档，应随相关改动维护。

## 常用命令

```bash
# 依赖与运行
fvm flutter pub get
fvm flutter run

# 测试。模型、provider、widget 可能依赖 Flutter 类型，优先用 flutter test，不用 dart test
fvm flutter test
fvm flutter test test/common/string_test.dart
fvm flutter test test/models/
fvm flutter test test/providers/
fvm flutter test test/widgets/

# 代码生成：修改 freezed/json_serializable/Riverpod/Drift 相关文件后执行
fvm dart run build_runner build --delete-conflicting-outputs

# 格式化
fvm dart format <paths>
```

如果全局 `flutter`/`dart` 不可用，优先使用 `fvm`。如果 FVM 因 SDK cache 写入受限失败，需要请求提权后重试。

## 打包与构建

```bash
# 初始化子模块，Go core 在 core/Clash.Meta/
git submodule update --init --recursive

# 完整打包：Go core + Flutter + packaging
fvm dart setup.dart macos
fvm dart setup.dart linux
fvm dart setup.dart windows
fvm dart setup.dart android

# 仅构建 Go core
bash plugins/setup/buildkit/run_build_tool.sh macos
bash plugins/setup/buildkit/run_build_tool.sh linux
bash plugins/setup/buildkit/run_build_tool.sh windows
bash plugins/setup/buildkit/run_build_tool.sh android
```

`setup.dart` 会生成被 `.gitignore` 忽略的 `env.json`。Windows release 构建还会预构建 Go core，读取 `core_sha256.json`，并把 SHA256 同时用于 Flutter app 与 Rust helper 鉴权。

### GitHub Actions 手动构建

仓库有专门的 `macos-build.yaml` 手动 workflow。只触发 macOS arm64 构建：

```bash
# pre 环境
gh workflow run macos-build.yaml -f arch=arm64 -f env=pre

# stable 环境
gh workflow run macos-build.yaml -f arch=arm64 -f env=stable

# 指定分支或 tag
gh workflow run macos-build.yaml --ref <branch-or-tag> -f arch=arm64 -f env=pre
```

查看运行状态和下载产物：

```bash
gh run list --workflow macos-build.yaml --limit 5
gh run watch <run-id>
gh run download <run-id> -n artifact-macos-arm64
```

不要用 `build.yaml` 做单平台手动构建；它当前只在 `v*` tag push 时触发完整矩阵构建。

## 关键架构

- Flutter 多平台客户端，Go ClashMeta/mihomo core 在 `core/`。
- Android 使用 lib mode：Go core 编成 `libclash.so`，Dart 侧经 FFI 调用，入口在 `lib/core/lib.dart`。
- Desktop 使用 core mode：Go core 独立进程，Dart 侧通过 socket 通信，入口在 `lib/core/service.dart`。
- `lib/core/controller.dart` 是 `CoreHandlerInterface` 的单例 facade，测试可用 `CoreController.test(mock)` 注入 mock，结束后调用 `CoreController.resetInstance()`。
- Riverpod provider 主要在 `lib/providers/`：`config.dart` 持久配置，`state.dart` 派生状态，`action.dart` 业务动作，`app.dart` 运行时 UI 状态。
- Drift 数据库在 `lib/database/`，生成文件在 `lib/database/generated/`，schema 变更后补对应 `test/database/`。

## DNS 与 Fake-IP 相关入口

- DNS 设置 UI 在 `lib/views/config/dns.dart`。
- 覆写 DNS 开关是 `overrideDnsProvider`，最终由 `patchClashConfigProvider` 参与生成配置。
- `fake-ip-filter` 是 `List<String>`，当前列表编辑入口是 `ListInputPage`。
- 本 fork 已支持在列表新增时批量粘贴，按逗号、分号、空白、Tab、换行拆分，并跳过重复项。相关代码在 `lib/widgets/input.dart` 和 `lib/common/string.dart`。
- 判断 fake-ip 行为时注意：`fake-ip-filter` 只决定 DNS 是否返回真实 IP，不等价于规则一定直连，最终路由仍取决于 Clash/mihomo 规则。

## About 与构建信息

- About 页在 `lib/views/about.dart`。
- 构建信息常量在 `lib/common/build_info.dart`。
- 运行 `setup.dart` 打包时，构建标识来自：
  - `BUILD_SOURCE`: 当前仓库目录名，通常是 `myFlClash`
  - `BUILD_COMMIT`: `git rev-parse --short HEAD`
  - `BUILD_DIRTY`: `git status --porcelain --untracked-files=no` 是否有输出
- dirty 判断只看已跟踪文件，避免未跟踪的本地计划文档污染构建标识。

## 本地插件和平台模块

- `plugins/setup`：构建 harness，无 Dart API，负责触发 Go/Rust 构建。
- `plugins/proxy`：系统代理配置。
- `plugins/rust_api`：Flutter Rust Bridge FFI，named pipe/local socket 通信。
- `tray_manager` 与 `flutter_distributor` 已改为 `pubspec.yaml` 中的 Git 依赖，不再保留本地 `plugins/` 子模块。
- `plugins/wifi_ssid`、`plugins/window_ext`：平台能力；`plugins/setup` 负责打包构建。
- 本 fork 在 macOS 明确禁用系统托盘：`lib/common/tray.dart` 的 `tray` 仅在非 macOS 桌面端初始化。不要在没有先验证原生托盘重绘开销的情况下重新启用。
- Windows helper 在 `services/helper/`，release 用 token 鉴权，debug 下跳过 token 校验。

## 验证策略

- 小 UI/配置改动至少跑相关单测或格式化；如果环境阻塞，明确写出命令和阻塞原因。
- 修改列表/字符串工具时优先补 `test/common/`。
- 修改 provider/action/core 行为时优先补 `test/providers/` 或 `test/core/`。
- 修改模型、数据库、生成代码相关文件时运行 build_runner，并检查生成文件 diff 是否只包含预期变化。

## 本地化

- ARB 文件在 `arb/`，生成输出在 `lib/l10n/`。
- Widget 中优先用 `context.appLocalizations.key`。
- controller/provider 等非 Widget 代码使用 `currentAppLocalizations.key`。
