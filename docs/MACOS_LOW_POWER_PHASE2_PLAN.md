# macOS 低功耗第二阶段整改方案

## 背景

第一阶段整改已经围绕实时流量刷新做了最小化处理：

- 关闭托盘网速时，托盘标题状态不再订阅实时流量。
- 实时速度和累计流量拆分刷新。
- 根据仪表盘、窗口可见性、托盘设置降低部分刷新频率。

第二阶段不推翻第一阶段方案，而是在第一阶段验证后继续压低后台运行时的 CPU/GPU 开销。重点从“减少每秒刷新内容”推进到“减少每秒调度本身”和“确认真实热源”。

## 目标

- 进一步降低 macOS 后台运行时的持续唤醒。
- 避免窗口不可见时仍保留固定 1 秒主定时器。
- 为托盘网速提供更省电的低频刷新策略。
- 更准确地区分窗口可见、最小化、隐藏、前后台状态。
- 用采样数据确认温升主要来自 Flutter/UI/WindowServer 还是 core。

## 非目标

- 不重写 Flutter UI 架构。
- 不改 Go core / mihomo 转发逻辑，除非采样明确证明热源在 core。
- 不改变默认代理功能和连接稳定性。
- 不移除实时网速功能，只增加更低功耗的调度方式。

## 前置验证

第二阶段开始前，先用第一阶段构建产物做一次运行时采样，避免盲目扩大改动。

### 采样场景

至少覆盖以下场景：

| 场景 | 操作 | 观察重点 |
| --- | --- | --- |
| 托盘网速关闭，窗口隐藏 | 启动 core 后隐藏窗口 | FlClash / WindowServer CPU 是否下降 |
| 托盘网速开启，窗口隐藏 | 菜单栏显示网速 | NSStatusItem / CALayer 是否仍高频出现 |
| 仪表盘打开，包含网络速度 | 前台观察速度曲线 | 实时网速是否正常 |
| 非仪表盘页面 | 切到其他页面停留 | 是否仍有明显每秒 UI 重绘 |

### 建议命令

```bash
ps aux -r | head -25
sample <FlClash PID> 5 -file /tmp/flclash.sample.txt
sample <WindowServer PID> 5 -file /tmp/windowserver.sample.txt
```

### 判断标准

- 如果热点主要在 `NSStatusItem`、`CALayer`、`CoreGraphics`、Flutter raster/UI 线程，继续执行本方案。
- 如果热点主要在 core 进程、DNS、规则匹配、网络 socket，则第二阶段 UI 调度只能改善一部分，需要另开 core 侧排查。

## 整改方向

### 1. 将固定 1 秒主 Timer 改为动态 Timer

第一阶段仍保留 `_updateTimer = Timer.periodic(const Duration(seconds: 1), ...)`，只是每秒判断是否需要刷新。第二阶段应把“每秒判断”也降下来。

建议改为单次 Timer 递归调度：

```dart
void _scheduleNextRefresh() {
  final interval = _calculateNextRefreshInterval();
  _updateTimer?.cancel();
  _updateTimer = Timer(interval, () {
    _refreshRuntimeState();
    _scheduleNextRefresh();
  });
}
```

建议初始策略：

| 场景 | Timer 间隔 |
| --- | --- |
| 仪表盘可见且包含网络速度 | 1 秒 |
| 托盘网速开启，普通模式 | 1 秒 |
| 托盘网速开启，低功耗模式 | 3 秒 |
| 窗口可见但不需要实时速度 | 3-10 秒 |
| 窗口隐藏/最小化且托盘网速关闭 | 30 秒 |
| Core 停止 | 不调度 |

预期效果：

- 后台运行时减少 Dart isolate 定时唤醒。
- 降低 Riverpod 读状态、判断分支、异步调用排队的固定成本。

### 2. 增加托盘网速低功耗模式

托盘网速开启时，第一阶段仍保持 1 秒刷新，这是功能上合理但不一定省电。

建议增加一个设置项：

- `trayTrafficRefreshInterval`
- 或简化为 `lowPowerTrayTraffic`

推荐默认策略：

| 模式 | 托盘网速刷新 |
| --- | --- |
| 普通模式 | 1 秒 |
| 低功耗模式 | 3 秒 |
| 窗口隐藏且低功耗模式 | 5 秒 |

这个设置只影响菜单栏标题，不影响仪表盘打开时的实时速度图表。

### 3. 修正窗口状态模型

当前 `windowVisibleProvider` 只能表达一个粗略的可见状态。第二阶段建议拆成更明确的运行时状态：

```dart
enum WindowActivityState {
  foreground,
  backgroundVisible,
  minimized,
  hidden,
}
```

至少要区分：

- `foreground`：窗口聚焦，用户正在操作。
- `backgroundVisible`：窗口存在但未聚焦。
- `minimized`：最小化到 Dock。
- `hidden`：通过托盘或启动参数隐藏。

调度时按状态降频，而不是只依赖 `isVisible`。

### 4. 避免重复调用托盘标题 API

第一阶段已经减少了 provider 通知，但还应确认 native 托盘 API 调用也去重。

建议在托盘层缓存上一次标题：

```dart
String? _lastTrayTitle;

Future<void> updateTrayTitle(...) async {
  final nextTitle = showTrayTitle ? traffic.trayTitle : '';
  if (nextTitle == _lastTrayTitle) return;
  _lastTrayTitle = nextTitle;
  await trayManager.setTitle(nextTitle);
}
```

预期效果：

- 即使上游状态变化，也避免相同标题反复进入 macOS native 重绘链路。
- 降低 `NSStatusItem` / `CALayer` 相关调用频率。

### 5. 给运行时调度增加轻量日志或调试计数

为了验证第二阶段是否真的降频，可以只在 debug 或开发构建中增加计数：

- `speedTrafficRefreshCount`
- `totalTrafficRefreshCount`
- `trayTitleUpdateCount`
- `currentRefreshInterval`

这些计数不进入正式 UI，可以通过日志或调试面板观察。

## 推荐实施顺序

### 当前验证记录

验证时间：2026-07-06 08:32-08:35

验证环境：

- 已安装第一阶段低功耗构建产物。
- 未开启菜单栏显示网速。
- 分别验证 `Cmd+M` 最小化和隐藏窗口两种状态。

采样文件：

- `Cmd+M` 最小化：`/tmp/flclash-cmdm.sample.txt`
- 隐藏窗口：`/tmp/flclash-hidden.sample.txt`

验证结论：

- `Cmd+M` 是最小化，不等同于隐藏窗口。
- `Cmd+M` 状态下，FlClash 主进程仍约 40-47% CPU，FlClashCore 约 2-3% CPU。
- 隐藏窗口后，FlClash 主进程仍约 40%+ CPU，FlClashCore 仍约 2-3% CPU。
- 样本热点集中在 macOS 菜单栏状态项绘制链路，包括：
  - `NSStatusItemScene updateSettings`
  - `NSSceneStatusItem _setSelectedContentFrame`
  - `NSStatusItemReplicantShadowView drawRect`
  - `NSStatusItem _redrawReplicantSnapshot`
  - `CALayer renderInContext`
  - `CoreGraphics CGContextDrawImage`
- 因此当前热源主要在 FlClash 主进程的菜单栏状态项 / AppKit / CoreGraphics 绘制链路，不是 FlClashCore 转发链路。

基于这次验证，第二阶段实施顺序调整为：

1. 优先避免重复调用菜单栏状态项 API，包括 `setTitle('')`、`setIcon`、`setToolTip`、`setContextMenu`。
2. 确认 `showTrayTitle == false` 时不会因其他 tray 状态变化反复写入空标题。
3. 再做动态 Timer 调度。
4. 最后细化窗口状态模型。

### 第二阶段第一轮改动后验证记录

验证时间：2026-07-06 09:20-09:22

当前代码状态：

- 当前分支：`macos-tray-low-power`
- 已提交并推送：`b644bef perf(macos): 避免重复更新菜单栏状态项`
- 该提交已经做了 Dart 侧托盘调用去重，包括 `setIcon`、`setToolTip`、`setTitle`、`setContextMenu`。
- `docs/MACOS_LOW_POWER_PLAN.md` 和 `docs/MACOS_LOW_POWER_PHASE2_PLAN.md` 是本 fork 的低功耗方案/交接文档，应随相关改动提交维护。

当前运行状态：

- 用户已安装 `b644bef` 之后 GitHub Actions 构建出的 macOS 产物。
- FlClash 当前处于隐藏窗口状态。
- 菜单栏显示网速未开启。

进程快照：

- 采样前 `ps aux -r` 显示：
  - `FlClash` PID `49559`：约 `78.6% CPU`
  - `WindowServer` PID `407`：约 `49.9% CPU`
  - `FlClashCore` PID `49615`：约 `3.2% CPU`
- 采样后 `ps aux -r` 显示：
  - `FlClash` PID `49559`：约 `76.0% CPU`
  - `WindowServer` PID `407`：约 `52.0% CPU`
  - `FlClashCore` PID `49615`：约 `0.8% CPU`

重采样文件：

- FlClash 主进程：`/tmp/flclash-hidden-resample-20260706-0920.sample.txt`
- WindowServer：尝试采样失败，`sample` 提示需要 `sudo` 权限。

重采样热点：

- 10 秒采样中，FlClash 主线程共 `6519` 个样本。
- 热点仍集中在 AppKit / QuartzCore / CoreGraphics 的菜单栏状态项绘制链路：
  - `CA::Transaction::commit()`
  - `CA::Context::commit_transaction(...)`
  - `CA::Layer::display_if_needed(...)`
  - `NSStatusBarButtonCell drawWithFrame:inView:`
  - `NSSceneStatusItem _setSelectedContentFrame:options:`
  - `NSStatusItemScene updateSettings:transition:`
  - `NSStatusItemReplicantShadowView drawRect:`
  - `CGContextDrawImage`
  - `RIPLayerGaussianBlur`

验证结论：

- 重采样结果与前一次采样方向一致，前一次采样并非明显误判。
- Dart 侧托盘 API 去重没有消除当前隐藏状态下的高 CPU。
- 目前可以确认热源落在 macOS 菜单栏 status item 绘制链路，而不是 FlClashCore。
- 仅凭现有采样还不能严格区分：
  - 是“只要存在菜单栏图标就会触发高频绘制”；
  - 还是“当前 `tray_manager` 的 Swift status item 实现方式触发高频绘制”。
- 原因是两者都会进入同一组 AppKit 调用栈：`NSStatusItemScene`、`NSSceneStatusItem`、`NSStatusItemReplicantShadowView`、`CALayer`、`CoreGraphics`。

后续接手建议：

1. 先做最小对照实验：macOS 下完全不创建菜单栏图标。
   - 如果 FlClash 主进程和 WindowServer CPU 明显下降，说明 status item 链路就是主要根因。
   - 这个实验会暂时牺牲菜单栏入口，隐藏窗口后需要通过 Dock、应用切换器或重新打开应用恢复窗口。
2. 再做第二个对照实验：保留菜单栏图标，但将 Swift 实现改成最原生的 icon-only status item。
   - 如果这个版本下降，说明问题不是菜单栏图标本身，而是当前 Swift 自定义实现方式。
3. 若两个实验都不能明显下降，再回到动态 Timer、窗口状态模型和其他 UI 调度继续排查。

### 第一步：补采样和基线记录

先记录第一阶段产物在典型场景下的 CPU、温度、采样热点。

产物：

- `/tmp/flclash.sample.txt`
- `/tmp/windowserver.sample.txt`
- 一份简短对比记录，说明热点主要在哪一层。

### 第二步：托盘标题 native 调用去重

这是第二阶段里最小、安全、收益明确的改动。

预期效果：

- 避免相同标题重复写入菜单栏。
- 即使调度暂时仍是 1 秒，也能减少 native 重绘入口。

### 第三步：增加托盘低功耗刷新模式

先只影响托盘标题刷新，不改变仪表盘实时网速。

建议默认不开启，先作为个人低功耗分支配置使用。

### 第四步：动态 Timer 调度

在前两步稳定后，再替换固定 1 秒 `Timer.periodic`。

注意点：

- Core 启动、停止、重启时必须正确取消旧 Timer。
- 页面切换、托盘设置变化、窗口状态变化时，需要重新计算下一次调度。
- 避免同时存在多个 Timer。

### 第五步：窗口状态模型细化

如果动态 Timer 仍依赖粗略状态导致效果不稳定，再细化窗口状态模型。

这一步涉及面更大，建议单独提交。

## 验证方法

### 功能验证

- Core 启动、停止、重启正常。
- 仪表盘打开时网络速度正常刷新。
- 托盘网速普通模式仍按 1 秒刷新。
- 托盘网速低功耗模式按 3-5 秒刷新。
- 窗口隐藏后累计流量仍会低频增长。
- 切回仪表盘后实时速度能恢复。

### 性能验证

对比第一阶段和第二阶段：

```bash
ps aux -r | head -25
sample <FlClash PID> 5 -file /tmp/flclash.phase2.sample.txt
sample <WindowServer PID> 5 -file /tmp/windowserver.phase2.sample.txt
```

重点观察：

- FlClash 主进程 CPU 是否下降。
- WindowServer CPU 是否下降。
- `NSStatusItem` / `CALayer` / `CoreGraphics` 热点是否减少。
- 窗口隐藏、托盘网速关闭时是否不再出现稳定 1 秒唤醒。
- 托盘低功耗模式下温度是否比 1 秒刷新更低。

## 风险和回滚

### 风险

- 动态 Timer 写错可能导致流量不刷新或重复刷新。
- 页面切换后未重新调度，可能导致仪表盘网速恢复慢。
- 窗口状态事件在不同 macOS 版本上行为不完全一致。
- 托盘低频刷新可能让用户感觉菜单栏速度不够实时。

### 回滚方式

- 保留第一阶段的 `updateSpeedTraffic()` / `updateTotalTraffic()` 拆分结构。
- 动态 Timer 如果不稳定，可以回退到第一阶段的固定 1 秒 Timer + 内部分频。
- 托盘低功耗模式应作为独立配置，关闭后恢复原 1 秒行为。

## 建议提交拆分

- `perf(macos): 避免重复更新托盘标题`
- `feat(macos): 增加托盘网速低功耗模式`
- `perf(macos): 使用动态定时器调度流量刷新`
- `refactor(macos): 细化窗口运行状态`

## 结论

第二阶段的核心不是继续堆更多判断，而是把后台运行时的固定 1 秒唤醒消掉，并确认 macOS native 托盘标题更新没有被相同内容重复触发。

如果采样证明热源主要在 UI、WindowServer 或菜单栏重绘链路，本方案预计能继续降低 FlClash 后台运行时的温度和功耗。如果采样证明热源主要在 core，则应保留本方案作为 UI 侧优化，同时另开 core 侧排查。
