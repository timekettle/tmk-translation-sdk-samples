# tmk_translation_demo

TMK Translation SDK 的 Flutter 示例 App，用于验证 `tmk_translation_flutter` 插件在 Flutter 应用中的完整接入流程。

## 模块定位

```text
tmk_translation_demo
  → Sample-only adapter
    → package:tmk_translation_flutter/tmk_translation_flutter.dart
      → iOS/Android Timekettle Translation SDK
```

Demo 是独立第三方黑盒消费者。它只通过
`package:tmk_translation_flutter/tmk_translation_flutter.dart` 使用 SDK，
不直接调用 platform interface、Pigeon、MethodChannel、Room、Channel、Listener
或任何其他插件内部类型。Adapter 只负责把既有页面模型映射到冻结的公开 Session API，
不作为公共 API 的需求来源。

## 公开依赖

正式验收使用目标制品 `1.3.1-rc.3` 或可复现 Git SHA。开发联调可以在本机使用未提交的
`pubspec_overrides.yaml` path 依赖；该文件不得提交，`pubspec.lock` 仍保持正式依赖记录。
Android 原生依赖从 Maven Central 和公共 Jiagouyun Maven 解析，iOS 原生依赖从 CocoaPods
CDN/Trunk 解析；凭据只通过本地构建环境注入。

Android 工程需要在实际生效的 Gradle 仓库配置中加入：

```kotlin
maven(url = "https://mvnrepo.jiagouyun.com/repository/maven-releases")
```

企业网络若启用仓库白名单，需要允许访问 `mvnrepo.jiagouyun.com`。

## 主要能力

- 初始化 SDK 并展示在线/离线能力状态。
- 加载在线或离线语言列表。
- 支持收听模式和一对一模式。
- 支持在线和离线翻译模式的 UI 入口。
- 创建（创建成功即自动启动）、停止、重新准备和释放翻译会话。
- 展示会话指标：房间号、场景、模式、采样率、采集声道、回放声道等。
- 订阅插件事件并渲染识别/翻译气泡。
- 收听模式从手机麦克风推送单声道 PCM；一对一模式将手机麦克风映射到右声道，
  将原 Sample 的固定英文 PCM 映射到左声道。
- 按一对一播放音源选择消费 SDK 返回的翻译 PCM，并通过手机扬声器播放。
- 在 Sample 内持久化诊断、控制台日志和网络环境设置。

## 关键代码

- `lib/main.dart`：Flutter 入口。
- `lib/src/app.dart`：MaterialApp 配置。
- `lib/src/screens/home_screen.dart`：首页、SDK 初始化、语言加载、模式选择。
- `lib/src/screens/session_screen.dart`：会话创建、释放、事件订阅和状态展示。
- `lib/src/screens/settings_screen.dart`：诊断、日志、网络环境等调试配置。
- `lib/src/conversation_bubbles.dart`：SDK 事件到气泡列表的聚合渲染管线。
- `lib/src/tmk_translation_adapter.dart`：Sample 内部稳定导入面；模型、SDK 调用和事件
  适配分别实现，只消费公开 API。

## 职责边界

录音、权限申请、固定 PCM、系统播放、页面状态、导航、按钮流程和 UI 均属于 Sample。
Plugin 只提供初始化、鉴权、Session、PCM 输入、翻译事件、模型、诊断、错误和生命周期。
会话通过 `createSession()` 自动启动；取消、结构化错误、Stream 保序和幂等释放由 SDK
公共契约保证，Sample 不依赖固定翻译文本。

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

冻结的高层 API 由 Dart 初始化，因此开发运行时通过 `dart-define` 注入凭据：

```bash
flutter run \
  --dart-define=TMK_APP_ID="$TMK_SAMPLE_APP_ID" \
  --dart-define=TMK_APP_SECRET="$TMK_SAMPLE_APP_SECRET"
```

真实值只放在本地环境或 CI Secret 中，不提交到仓库。原生工程中已有的 manifest
placeholder/Info.plist 变量仅供旧版 Sample 构建兼容，不是高层 API 的凭据来源。

## 气泡渲染机制

SDK 返回的识别与翻译结果不会直接逐条渲染成气泡，而是先经过统一事件适配与气泡聚合。系统会按 `bubbleId` 和会话声道对结果进行归并，将同一轮对话中的 ASR 增量、MT 增量和最终结果合成为一个稳定的气泡快照，再映射成页面层的列表行数据。

整体链路为：`SDK Result -> Event Adapter -> Bubble Assembler -> Bubble Snapshot -> Row Model -> UI Cell`。其中 `Bubble Assembler` 负责处理 partial/final 合并、文本去重、增量覆盖、左右声道拆分，以及同一会话内源语言/目标语言内容的累积更新；UI 层只负责根据当前行数据和运行时状态渲染气泡。

收听模式按单声道会话组织，所有结果归并为左侧单列气泡；一对一对话按左右声道分别组织，同一 `bubbleId` 会结合声道信息拆成左右两类气泡，并保持固定的语言方向和显示位置。气泡正文由聚合后的快照驱动，气泡头部的元信息由运行时状态驱动，包括会话 ID、房间号、场景/模式、配置采样率、采集声道和回放声道等；当这些运行时指标变化时，当前可见气泡会同步刷新，保证展示信息与底层会话状态一致。
