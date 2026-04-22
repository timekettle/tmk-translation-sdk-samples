import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart';

import '../models.dart';
import '../theme.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.title,
    required this.config,
  });

  final String title;
  final TmkSessionConfig config;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final List<ConversationBubble> _bubbles = [];
  final Map<String, int> _bubbleIndex = {};

  StreamSubscription<TmkPluginEvent>? _eventsSubscription;
  String? _sessionId;
  bool _isCreating = true;
  bool _isStarting = false;
  bool _isStarted = false;
  bool _isDownloading = false;
  bool _useFixedAudio = true;
  String _statusText = '准备中...';
  TmkOfflineModelStatus? _offlineModelStatus;

  @override
  void initState() {
    super.initState();
    _useFixedAudio = widget.config.useFixedAudio;
    _eventsSubscription = TmkTranslationFlutter.events.listen(_handleEvent);
    _createSession();
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    final sessionId = _sessionId;
    if (sessionId != null) {
      TmkTranslationFlutter.stopSession(sessionId);
      TmkTranslationFlutter.disposeSession(sessionId);
    }
    super.dispose();
  }

  Future<void> _createSession() async {
    final previousSessionId = _sessionId;
    if (previousSessionId != null) {
      await TmkTranslationFlutter.stopSession(previousSessionId);
      await TmkTranslationFlutter.disposeSession(previousSessionId);
    }
    setState(() {
      _sessionId = null;
      _isCreating = true;
      _isStarting = false;
      _isStarted = false;
      _isDownloading = false;
      _statusText = '准备会话中...';
      _bubbles.clear();
      _bubbleIndex.clear();
    });
    final config = widget.config.copyWith(useFixedAudio: _useFixedAudio);
    try {
      final sessionId = await TmkTranslationFlutter.createSession(config);
      final offlineStatus = config.mode == TmkTranslationMode.offline
          ? await TmkTranslationFlutter.getOfflineModelStatus(sessionId)
          : null;
      if (!mounted) {
        return;
      }
      setState(() {
        _sessionId = sessionId;
        _offlineModelStatus = offlineStatus;
        _isCreating = false;
        _statusText = offlineStatus?.detail ?? '通道配置已创建，点击开始翻译。';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isCreating = false;
        _statusText = '创建会话失败：$error';
      });
    }
  }

  Future<void> _start() async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    setState(() {
      _isStarting = true;
      _statusText = '正在启动翻译...';
    });
    try {
      await TmkTranslationFlutter.startSession(sessionId);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isStarting = false;
        _statusText = '启动失败：$error';
      });
    }
  }

  Future<void> _stop() async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    await TmkTranslationFlutter.stopSession(sessionId);
    if (!mounted) {
      return;
    }
    setState(() {
      _isStarted = false;
      _isStarting = false;
      _statusText = '翻译已停止';
    });
  }

  Future<void> _downloadModels() async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    setState(() {
      _isDownloading = true;
      _statusText = '开始下载离线模型...';
    });
    await TmkTranslationFlutter.downloadOfflineModels(sessionId);
  }

  Future<void> _toggleFixedAudio(bool value) async {
    setState(() => _useFixedAudio = value);
    if (_isStarted) {
      return;
    }
    await _createSession();
  }

  void _handleEvent(TmkPluginEvent event) {
    if (event.sessionId != _sessionId) {
      return;
    }
    if (!mounted) {
      return;
    }
    switch (event) {
      case TmkSessionStateEvent():
        setState(() {
          _statusText = event.statusText;
          if (event.isStarted != null) {
            _isStarted = event.isStarted!;
          }
          if (event.isStarting != null) {
            _isStarting = event.isStarting!;
          }
          if (event.isModelReady == true) {
            _offlineModelStatus = TmkOfflineModelStatus(
              isReady: true,
              isSupported: true,
              summary: '模型已就绪',
              detail: '离线模型已完整，可直接开始翻译',
            );
            _isDownloading = false;
          }
        });
      case TmkBubbleEvent():
        final id = ConversationBubble.compositeId(event);
        final index = _bubbleIndex[id];
        if (index == null) {
          setState(() {
            _bubbleIndex[id] = _bubbles.length;
            _bubbles.add(
              ConversationBubble(
                id: id,
                sourceLangCode: event.sourceLangCode,
                targetLangCode: event.targetLangCode,
                channel: event.channel,
                sourceText: event.sourceText,
                translatedText: event.translatedText,
                isFinal: event.isFinal,
              ),
            );
          });
        } else {
          setState(() {
            _bubbles[index] = _bubbles[index].copyWith(
              sourceText: event.sourceText ?? _bubbles[index].sourceText,
              translatedText: event.translatedText ?? _bubbles[index].translatedText,
              isFinal: event.isFinal,
            );
          });
        }
      case TmkDownloadEvent():
        setState(() {
          _isDownloading = !event.isCompleted;
          _statusText = event.message;
          if (event.isCompleted) {
            _offlineModelStatus = TmkOfflineModelStatus(
              isReady: true,
              isSupported: true,
              summary: '模型已就绪',
              detail: '离线模型下载完成，可直接开始翻译',
            );
          }
        });
      case TmkErrorEvent():
        setState(() {
          _isStarting = false;
          _isStarted = false;
          _isDownloading = false;
          _statusText = event.message;
        });
      case TmkLogEvent():
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config.copyWith(useFixedAudio: _useFixedAudio);
    final canStart = !_isCreating &&
        !_isStarting &&
        !_isStarted &&
        _sessionId != null &&
        (config.mode != TmkTranslationMode.offline || (_offlineModelStatus?.isReady ?? false));
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: appCard,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: appBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${config.sourceLanguage} → ${config.targetLanguage}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(_statusText, style: const TextStyle(color: appTextMuted, height: 1.5)),
                  if (config.scenario == TmkScenario.oneToOne) ...[
                    const SizedBox(height: 16),
                    SwitchListTile(
                      value: _useFixedAudio,
                      contentPadding: EdgeInsets.zero,
                      onChanged: _isStarted ? null : _toggleFixedAudio,
                      title: const Text('固定右声道音频'),
                      subtitle: const Text('关闭后保留 UI 与会话结构，但第二路音频使用静音占位'),
                    ),
                  ],
                ],
              ),
            ),
            if (config.mode == TmkTranslationMode.offline) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: appCard,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: appBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _offlineModelStatus?.summary ?? '检查离线模型中...',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _offlineModelStatus?.detail ?? '请先检查当前语言对的离线模型状态。',
                      style: const TextStyle(color: appTextMuted, height: 1.5),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonal(
                            onPressed: _isDownloading ? null : _downloadModels,
                            child: Text(_isDownloading ? '下载中...' : '下载当前语言模型'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: canStart ? _start : null,
                    style: FilledButton.styleFrom(backgroundColor: appAccent),
                    child: Text(_isStarting ? '正在启动...' : '开始翻译'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _isStarted ? _stop : null,
                    style: FilledButton.styleFrom(backgroundColor: appDanger),
                    child: const Text('停止翻译'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              '翻译气泡',
              style: TextStyle(color: appTextMuted, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _bubbles.isEmpty
                  ? Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: appCard,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: appBorder),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        '等待识别结果...',
                        style: TextStyle(color: appTextMuted),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _bubbles.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final bubble = _bubbles[index];
                        return Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: appCard,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: appBorder),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  _MetaBadge(text: bubble.sourceLangCode, color: appPrimarySoft),
                                  _MetaBadge(text: bubble.targetLangCode, color: appAccent),
                                  if (bubble.channel != null)
                                    _MetaBadge(text: bubble.channel!, color: appWarning),
                                  _MetaBadge(
                                    text: bubble.isFinal ? 'FINAL' : 'PARTIAL',
                                    color: bubble.isFinal ? appAccent : appTextMuted,
                                  ),
                                ],
                              ),
                              if ((bubble.sourceText ?? '').isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Text(
                                  bubble.sourceText!,
                                  style: const TextStyle(fontSize: 16, height: 1.5),
                                ),
                              ],
                              if ((bubble.translatedText ?? '').isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text(
                                  bubble.translatedText!,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    height: 1.5,
                                    color: appPrimarySoft,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaBadge extends StatelessWidget {
  const _MetaBadge({
    required this.text,
    required this.color,
  });

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}
