# Flutter 示例与公开 API 边界

本目录只验证 Flutter 应用作为第三方消费者接入 `tmk_translation_flutter`。
公共入口固定为：

```dart
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart';
```

## 目录职责

- `apps/tmk_translation_demo`：Sample UI、页面状态、录音/权限、固定 PCM、系统播放和演示业务。
- `packages/`：仅保留仓库已有的 Flutter 示例基础设施；Sample 不依赖 SDK 的 platform interface、Pigeon 或任何内部路径。

Sample 内的 `tmk_translation_adapter.dart` 只是页面模型到公开 Session API 的适配层，不能成为公共 API 的需求来源。公共 API 以 SDK 仓内的 API Reference、iOS/Android 共同稳定能力、Flutter 通用使用方式和三端语义对照记录为准。

## 会话接入约束

Sample 只使用高层 SDK 能力：初始化、鉴权、语言、模型、诊断、`createSession()`、PCM 输入、翻译事件、运行时更新和幂等释放。创建成功即自动启动；Sample 不调用 `start()`、`stop()`，也不接触 Room、Channel、Listener、MethodChannel、EventChannel 或 Pigeon 类型。

录音、权限申请、固定 PCM、播放路由、页面状态、导航和 UI 全部留在 Sample。SDK Stream 是广播流，`createSession()` 操作和成功 Session 共享同一 Streams 实例；Sample 不依赖固定翻译文本。

## 依赖与验收

正式验收依赖目标制品 `tmk_translation_flutter: 1.3.1-rc.3`，Sample 的正式 `pubspec.lock` 保持 hosted RC3 及其校验和。开发联调可在本机创建未跟踪的 `pubspec_overrides.yaml` 使用相对 path 依赖，但不得提交该文件或绝对路径。

执行公开边界门禁：

```bash
cd apps/tmk_translation_demo
./tool/verify_public_api_boundary.sh
```

门禁会拒绝内部包/生成代码导入、直接通道调用、绝对路径依赖和被跟踪的开发覆盖文件。Sample 的 SDK 修复必须回到 `tmk-translation-sdk`；本仓只提交接入 Adapter、演示逻辑和对应测试。
