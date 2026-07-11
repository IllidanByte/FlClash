# macOS 低功耗统计整改方案

## 背景

本分支用于维护个人使用的 macOS 低功耗补丁。当前目标不是移除流量统计，而是降低实时网速刷新和 UI 重绘带来的持续 CPU/GPU 开销。

已确认的主要问题链路：

- Core 启动后，`SetupAction._handleStart()` 每秒触发一次状态刷新。
- `CommonAction.updateTraffic()` 每秒同时调用 `getTraffic()` 和 `getTotalTraffic()`。
- `trafficsProvider` 和 `totalTrafficProvider` 更新后，会通知订阅它们的 UI。
- 托盘标题、仪表盘网络速度、流量用量等组件可能因此每秒重绘。
- macOS 上托盘标题更新会进入 `NSStatusItem` / `CALayer` / `CoreGraphics` 重绘链路，可能造成明显发热。

## 目标

- 保留累计流量统计能力。
- 降低不必要的实时网速刷新。
- 窗口隐藏、非仪表盘页面、未开启托盘网速时尽量低频刷新。
- 避免关闭托盘网速后仍然让托盘订阅每秒流量变化。
- 尽量保持改动小，方便后续同步 upstream 或提交 PR。

## 非目标

- 不重写为 macOS 原生客户端。
- 不移除 Flutter。
- 不改 Go core / mihomo 转发逻辑。
- 不破坏仪表盘打开时的实时网速显示。

## 整改原则

### 1. 实时速度和累计流量拆分

当前 `updateTraffic()` 同时更新实时速度和累计流量：

- `getTraffic()`：实时上传/下载速度，适合高频刷新。
- `getTotalTraffic()`：累计上传/下载流量，不需要每秒刷新。

建议拆成：

```dart
updateSpeedTraffic(); // 高频，按需调用
updateTotalTraffic(); // 低频，保留累计统计
```

### 2. 托盘网速关闭时完全脱离实时流量

当 `showTrayTitle == false` 时：

- `trayTitleStateProvider` 不应 watch `trafficsProvider`。
- 托盘标题只需要保持空字符串。
- 每秒流量更新不应触发托盘标题状态变化。

这是最小且优先级最高的修复点。

### 3. 实时速度按需刷新

`getTraffic()` 只应在下列场景保持 1 秒刷新：

- 当前页面是仪表盘，并且仪表盘包含 `DashboardWidget.networkSpeed`。
- 托盘网速统计开启，即 `showTrayTitle == true`。
- 其他明确需要实时速度的页面或组件可见。

其他场景可以停止实时速度刷新，或降频到 10 秒。

### 4. 累计流量低频刷新

`getTotalTraffic()` 仍然保留，但按场景降频：

- 仪表盘可见：每 2-3 秒。
- 非仪表盘页面：每 10 秒。
- 窗口隐藏或最小化：每 30 秒。
- Core 停止：不刷新。

### 5. UI 不可见时不做高频 UI 状态更新

窗口隐藏、最小化、后台运行时：

- 不需要每秒更新网络速度曲线。
- 不需要每秒刷新托盘标题，除非用户显式开启托盘网速。
- 累计流量可以低频更新，保证统计不丢失。

## 推荐实施顺序

### 第一步：托盘标题最小修复

当 `showTrayTitle == false` 时，让 `trayTitleStateProvider` 返回固定空流量状态，不再订阅 `trafficsProvider`。

预期效果：

- 关闭托盘网速后，实时流量变化不再触发托盘标题更新。
- 降低 macOS `NSStatusItem` 重绘频率。
- 改动小，适合单独提交。

### 第二步：拆分实时速度和累计流量

把 `CommonAction.updateTraffic()` 拆成两个方法：

- `updateSpeedTraffic()`
- `updateTotalTraffic()`

预期效果：

- 后续可以分别控制刷新频率。
- 避免为了累计流量统计而强制每秒刷新实时速度。

### 第三步：按页面和设置动态调度刷新

根据以下状态决定刷新频率：

- 当前页面是否为 `PageLabel.dashboard`。
- 仪表盘是否包含 `DashboardWidget.networkSpeed`。
- 是否开启 `showTrayTitle`。
- 窗口是否隐藏或最小化。

建议初始策略：

| 场景 | 实时速度 | 累计流量 |
| --- | --- | --- |
| 仪表盘可见且包含网络速度 | 1 秒 | 2-3 秒 |
| 仪表盘可见但不含网络速度 | 不刷新或 10 秒 | 2-3 秒 |
| 非仪表盘页面 | 不刷新或 10 秒 | 10 秒 |
| 窗口隐藏/最小化 | 仅托盘网速开启时 1 秒，否则不刷新 | 30 秒 |
| Core 停止 | 不刷新 | 不刷新 |

### 第四步：避免重复写入相同 UI 状态

如果新旧流量值相同，或托盘标题文本相同，不再写入 provider 或调用托盘 API。

预期效果：

- 降低 Riverpod 通知次数。
- 降低 Flutter rebuild 和 macOS 桥接调用次数。

## 验证方法

### 功能验证

- Core 启动后，代理功能正常。
- 仪表盘流量用量仍能增长。
- 打开网络速度面板时，速度曲线正常刷新。
- 关闭托盘网速后，菜单栏不显示速度。
- 重新开启托盘网速后，菜单栏速度恢复。

### 性能验证

在 macOS 上使用以下方式对比补丁前后：

```bash
ps aux -r | head -25
sample <FlClash PID> 5 -file /tmp/flclash.sample.txt
```

重点观察：

- `FlClash` 主进程 CPU 是否下降。
- `WindowServer` CPU 是否下降。
- `sample` 中 `NSStatusItem` / `CALayer renderInContext` / `CoreGraphics` 热点是否减少。
- 关闭托盘网速、窗口隐藏时温度是否明显降低。

## 构建说明

不能使用 Linux Docker 构建 macOS App。Flutter macOS 产物依赖 Xcode 和 macOS SDK，需要在 macOS 主机或 GitHub Actions macOS runner 上构建。

推荐个人版构建方式：

- 使用 fork 仓库的 GitHub Actions。
- 配置 `workflow_dispatch` 手动触发。
- 使用 `macos-latest` runner。
- 产物上传为 Actions artifact。

## 分支建议

- 个人低功耗分支：`macos-tray-low-power`
- 若后续准备 PR，建议拆成多个小提交：
  - `fix(macos): 关闭托盘网速时停止订阅流量`
  - `perf(macos): 拆分实时速度和累计流量刷新`
  - `perf(macos): 后台运行时降低流量刷新频率`
