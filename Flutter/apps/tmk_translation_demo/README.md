# tmk_translation_demo

TMK Translation SDK 的 Flutter 示例 App，用于验证 `tmk_translation_flutter` 插件在 Flutter 应用中的完整接入流程。

## 模块定位

```text
tmk_translation_demo
  → packages/tmk_translation_flutter
    → packages/tmk_translation_platform_interface
    → iOS/Android TMK Translation SDK
```

Demo App 只通过 `package:tmk_translation_flutter/tmk_translation_flutter.dart` 使用 SDK 能力，不直接调用原生 iOS/Android SDK。

## 主要能力

- 初始化 SDK 并展示在线/离线能力状态。
- 加载在线或离线语言列表。
- 支持收听模式和一对一模式。
- 支持在线和离线翻译模式的 UI 入口。
- 创建、启动、停止和释放翻译会话。
- 展示会话指标：房间号、场景、模式、采样率、采集声道、回放声道等。
- 订阅插件事件并渲染识别/翻译气泡。

## 关键代码

- `lib/main.dart`：Flutter 入口。
- `lib/src/app.dart`：MaterialApp 配置。
- `lib/src/screens/home_screen.dart`：首页、SDK 初始化、语言加载、模式选择。
- `lib/src/screens/session_screen.dart`：会话创建、启停、事件订阅和状态展示。
- `lib/src/screens/settings_screen.dart`：诊断、日志、网络环境等调试配置。
- `lib/src/conversation_bubbles.dart`：SDK 事件到气泡列表的聚合渲染管线。

## 运行到 iOS 设备

先确认设备：

```bash
flutter devices
```

运行到指定设备，例如 XR：

```bash
cd Flutter/apps/tmk_translation_demo
flutter run -d <device-id>
```

## 凭证配置

iOS 示例通过 `ios/Runner/Info.plist` 读取：

- `TMKSampleAppID` → `$(TMK_SAMPLE_APP_ID)`
- `TMKSampleAppSecret` → `$(TMK_SAMPLE_APP_SECRET)`

真实值应放在本地 xcconfig 或构建环境中，不要提交到仓库。

## 气泡渲染机制

SDK 返回的识别与翻译结果不会直接逐条渲染成气泡，而是先经过统一事件适配与气泡聚合。系统会按 `bubbleId` 和会话声道对结果进行归并，将同一轮对话中的 ASR 增量、MT 增量和最终结果合成为一个稳定的气泡快照，再映射成页面层的列表行数据。

整体链路为：`SDK Result -> Event Adapter -> Bubble Assembler -> Bubble Snapshot -> Row Model -> UI Cell`。其中 `Bubble Assembler` 负责处理 partial/final 合并、文本去重、增量覆盖、左右声道拆分，以及同一会话内源语言/目标语言内容的累积更新；UI 层只负责根据当前行数据和运行时状态渲染气泡。

收听模式按单声道会话组织，所有结果归并为左侧单列气泡；一对一对话按左右声道分别组织，同一 `bubbleId` 会结合声道信息拆成左右两类气泡，并保持固定的语言方向和显示位置。气泡正文由聚合后的快照驱动，气泡头部的元信息由运行时状态驱动，包括会话 ID、房间号、场景/模式、配置采样率、采集声道和回放声道等；当这些运行时指标变化时，当前可见气泡会同步刷新，保证展示信息与底层会话状态一致。
