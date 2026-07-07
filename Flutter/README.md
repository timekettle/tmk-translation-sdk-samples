# Flutter 模块架构说明

本目录承载 TMK Translation SDK 的 Flutter 接入示例，整体采用 Flutter 官方推荐的插件分层：应用层只依赖 Flutter 插件 API，平台接口层定义稳定契约，插件实现层负责通过 MethodChannel/EventChannel 适配 iOS/Android 原生 SDK。

## 目录结构

```text
Flutter/
├── apps/
│   └── tmk_translation_demo/              # Flutter 示例 App
└── packages/
    ├── tmk_translation_flutter/           # Flutter 插件实现包
    └── tmk_translation_platform_interface/# 平台接口与数据模型包
```

## 模块职责

### `apps/tmk_translation_demo`

示例 App，展示 SDK 在 Flutter 侧的典型使用方式：

- 初始化 SDK、读取和应用调试配置。
- 加载在线/离线语言列表。
- 创建收听或一对一会话。
- 启停翻译会话、下载离线模型、切换一对一播放声道。
- 订阅插件事件并将 ASR/MT 结果聚合为会话气泡。

应用层入口是 `lib/main.dart` 和 `lib/src/app.dart`，核心页面在 `lib/src/screens/`，气泡聚合逻辑在 `lib/src/conversation_bubbles.dart`。

### `packages/tmk_translation_platform_interface`

平台接口包，负责定义 Flutter 侧稳定契约，不包含具体原生 SDK 调用。

它的作用是：

- 定义 `TmkTranslationPlatform` 抽象接口。
- 定义 Dart 数据模型和枚举，例如 `TmkSettingsDraft`、`TmkRuntimeStatus`、`TmkSessionConfig`、`TmkPluginEvent`。
- 通过 `plugin_platform_interface` 保护平台实现注册，避免非授权实现绕过接口约束。
- 作为 App、插件实现、测试替身之间共享的 API 边界。

这个包应该保持轻量、稳定、无平台代码。新增 Flutter API 时通常先在这里扩展接口和模型，再由具体插件实现补齐。

### `packages/tmk_translation_flutter`

Flutter 插件实现包，是 Dart API 与 iOS/Android 原生 TMK SDK 之间的桥接层。

它包含两部分：

1. Dart facade 和 channel 实现
   - `lib/src/tmk_translation_flutter.dart` 提供业务方调用的静态 API。
   - `lib/src/method_channel_tmk_translation_platform.dart` 实现 `TmkTranslationPlatform`，通过 MethodChannel 调用原生方法，通过 EventChannel 接收原生事件。

2. 原生平台实现
   - iOS: `ios/Classes/TmkTranslationFlutterPlugin.swift`
   - Android: `android/src/main/kotlin/co/timekettle/translation/flutter/TmkTranslationFlutterPlugin.kt`

原生实现负责：

- 注册 Flutter method/event channel。
- 初始化 TMK Translation SDK。
- 从 Flutter 入参或平台配置中解析 AppID/AppSecret。
- 处理鉴权、语言列表、运行状态、诊断日志等通用能力。
- 管理翻译 session 的生命周期。
- 将原生 SDK 的 ASR、翻译、状态、指标、下载进度、错误等事件转换成 Flutter 事件。

## 调用链路

```text
Flutter Demo UI
  ↓
TmkTranslationFlutter 静态 API
  ↓
TmkTranslationPlatform 抽象接口
  ↓
MethodChannelTmkTranslationPlatform
  ↓ MethodChannel / EventChannel
TmkTranslationFlutterPlugin 原生实现
  ↓
TMK Translation SDK for iOS / Android
```

同步请求类能力走 MethodChannel，例如初始化、创建会话、启动/停止会话。持续回调类能力走 EventChannel，例如识别文本、翻译文本、会话状态、音频指标和错误事件。

## 主要接口边界

| 层级 | 负责内容 | 不应该负责 |
| --- | --- | --- |
| Demo App | UI、页面状态、用户交互、事件展示 | 直接调用原生 SDK |
| platform_interface | Dart 契约、模型、枚举、测试替身边界 | MethodChannel 细节、平台实现 |
| tmk_translation_flutter Dart 层 | 对外 API、MethodChannel/EventChannel 适配 | UI 展示、业务页面状态 |
| tmk_translation_flutter 原生层 | SDK 初始化、鉴权、session 管理、音频/模型/事件适配 | Flutter 页面逻辑 |
| TMK 原生 SDK | 实际翻译、鉴权、通道、模型和底层能力 | Flutter API 稳定性 |

## 新增能力时的推荐流程

1. 在 `tmk_translation_platform_interface` 中新增或调整接口、模型、枚举。
2. 在 `tmk_translation_flutter` 的 Dart channel 实现中实现该接口。
3. 在 iOS/Android 原生插件中添加对应 method 或 event 映射。
4. 在 `tmk_translation_demo` 中接入新能力并验证用户流程。
5. 补充平台接口测试、插件测试或 Demo widget 测试。

## 配置说明

示例 App 通过平台配置提供 SDK 凭证：

- iOS Demo: `apps/tmk_translation_demo/ios/Runner/Info.plist` 读取 `TMKSampleAppID` 和 `TMKSampleAppSecret`，实际值来自 xcconfig 中的 `TMK_SAMPLE_APP_ID`、`TMK_SAMPLE_APP_SECRET`。
- Android Demo: 原生插件从 manifest metadata 中读取 `TMK_SAMPLE_APP_ID`、`TMK_SAMPLE_APP_SECRET`。

也可以在 Flutter 初始化时显式传入：

```dart
await TmkTranslationFlutter.initialize(
  appId: 'your_app_id',
  appSecret: 'your_app_secret',
  settings: settings,
);
```

注意不要把真实凭证提交到仓库。

## 相关 README

- [`apps/tmk_translation_demo/README.md`](apps/tmk_translation_demo/README.md)
- [`packages/tmk_translation_flutter/README.md`](packages/tmk_translation_flutter/README.md)
- [`packages/tmk_translation_platform_interface/README.md`](packages/tmk_translation_platform_interface/README.md)
