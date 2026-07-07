# tmk_translation_flutter

Flutter 插件实现包，用于把 `tmk_translation_platform_interface` 中定义的 Dart API 连接到 iOS/Android 原生 TMK Translation SDK。

## 职责

- 对外提供 `TmkTranslationFlutter` 静态 API。
- 注册 `MethodChannelTmkTranslationPlatform` 作为默认平台实现。
- 通过 MethodChannel 调用原生方法：初始化、鉴权、语言列表、创建会话、启停会话、离线模型等。
- 通过 EventChannel 接收原生事件：会话状态、识别/翻译文本、气泡结果、音频指标、下载进度、错误日志等。
- 在 iOS/Android 原生层管理 TMK SDK 初始化、session 生命周期、音频采集/播放和 SDK 事件适配。

## 与其他模块的关系

```text
tmk_translation_demo
  → tmk_translation_flutter
    → tmk_translation_platform_interface
    → iOS/Android TMK Translation SDK
```

业务方通常只依赖本包：

```yaml
dependencies:
  tmk_translation_flutter:
    path: ../../packages/tmk_translation_flutter
```

本包会重新导出 platform interface 中的模型和枚举，因此 App 可以直接从 `package:tmk_translation_flutter/tmk_translation_flutter.dart` 导入 API。

## 关键文件

- `lib/src/tmk_translation_flutter.dart`：业务调用入口。
- `lib/src/method_channel_tmk_translation_platform.dart`：MethodChannel/EventChannel 平台实现。
- `ios/Classes/TmkTranslationFlutterPlugin.swift`：iOS 原生插件实现。
- `android/src/main/kotlin/co/timekettle/translation/flutter/TmkTranslationFlutterPlugin.kt`：Android 原生插件实现。
- `ios/tmk_translation_flutter.podspec`：iOS 依赖声明，当前依赖 `TmkTranslationSDK`。

## 调用示例

```dart
final settings = await TmkTranslationFlutter.getCurrentSettings();
final status = await TmkTranslationFlutter.initialize(settings: settings);
final languages = await TmkTranslationFlutter.getSupportedLanguages(
  TmkLanguageSource.online,
);

final sessionId = await TmkTranslationFlutter.createSession(
  const TmkSessionConfig(
    scenario: TmkScenario.listen,
    mode: TmkTranslationMode.online,
    sourceLanguage: 'zh-CN',
    targetLanguage: 'en-US',
    useFixedAudio: false,
  ),
);

await TmkTranslationFlutter.startSession(sessionId);
```

事件监听：

```dart
final subscription = TmkTranslationFlutter.events.listen((event) {
  // 根据 event.kind 分发 session_state、bubble、metrics、error 等事件。
});
```

## 设计原则

- Dart API 保持平台无关，平台差异留在原生插件内部处理。
- MethodChannel 的 method 名和 EventChannel 的事件字段应与 platform interface 模型保持一致。
- 新增能力时先更新 `tmk_translation_platform_interface`，再补齐本包 Dart、iOS、Android 实现。
- 不在插件实现层承载 Demo UI 状态或页面展示逻辑。
