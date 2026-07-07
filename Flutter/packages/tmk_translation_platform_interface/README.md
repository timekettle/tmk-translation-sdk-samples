# tmk_translation_platform_interface

Flutter 平台接口包，定义 TMK Translation Flutter 插件的稳定 Dart 契约和共享模型。

## 职责

- 定义 `TmkTranslationPlatform` 抽象接口。
- 定义 Flutter 侧共享模型、枚举和事件类型。
- 为 `tmk_translation_flutter`、Demo App 和测试替身提供一致 API 边界。
- 使用 `plugin_platform_interface` 的 token 校验机制保护平台实现注册。

本包不直接调用 iOS/Android 原生 SDK，也不包含 MethodChannel/EventChannel 实现。

## 关键文件

- `lib/tmk_translation_platform_interface.dart`：包导出入口。
- `lib/src/tmk_translation_platform.dart`：平台抽象接口和默认占位实现。
- `lib/src/models.dart`：设置、运行状态、语言、会话配置、插件事件等模型。

## 在整体架构中的位置

```text
Demo App / 业务 App
  ↓
tmk_translation_flutter 对外 API
  ↓
tmk_translation_platform_interface 抽象契约
  ↓
tmk_translation_flutter 的 MethodChannel 平台实现
  ↓
iOS / Android 原生 TMK SDK
```

`tmk_translation_flutter` 依赖本包并实现 `TmkTranslationPlatform`。业务 App 一般不需要直接依赖本包；如果要写测试替身、Mock 平台实现或新增平台实现，才需要直接使用这里的接口。

## 扩展接口的规则

新增插件能力时应先更新本包：

1. 在 `TmkTranslationPlatform` 增加抽象方法或事件契约。
2. 在 `models.dart` 增加必要的请求/响应模型或枚举。
3. 为 `_PlaceholderPlatform` 增加对应未实现方法，保证未注册平台实现时能明确报错。
4. 再到 `tmk_translation_flutter` 中补齐 MethodChannel 和原生实现。

保持本包 API 稳定可以降低 Flutter 应用、插件实现和测试之间的耦合。
