# tmk_translation_demo

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## 气泡渲染机制

SDK 返回的识别与翻译结果不会直接逐条渲染成气泡，而是先经过统一事件适配与气泡聚合。系统会按 `bubbleId` 和会话声道对结果进行归并，将同一轮对话中的 ASR 增量、MT 增量和最终结果合成为一个稳定的气泡快照，再映射成页面层的列表行数据。

整体链路为：`SDK Result -> Event Adapter -> Bubble Assembler -> Bubble Snapshot -> Row Model -> UI Cell`。其中 `Bubble Assembler` 负责处理 partial/final 合并、文本去重、增量覆盖、左右声道拆分，以及同一会话内源语言/目标语言内容的累积更新；UI 层只负责根据当前行数据和运行时状态渲染气泡。

收听模式按单声道会话组织，所有结果归并为左侧单列气泡；一对一对话按左右声道分别组织，同一 `bubbleId` 会结合声道信息拆成左右两类气泡，并保持固定的语言方向和显示位置。气泡正文由聚合后的快照驱动，气泡头部的元信息由运行时状态驱动，包括会话 ID、房间号、场景/模式、配置采样率、采集声道和回放声道等；当这些运行时指标变化时，当前可见气泡会同步刷新，保证展示信息与底层会话状态一致。
