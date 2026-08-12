import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart';

import '../conversation_bubbles.dart';
import '../models.dart';
import '../theme.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.title, required this.config});

  final String title;
  final TmkSessionConfig config;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  static const int _maxDisplayedBubbles = 200;

  final List<ConversationBubble> _bubbles = [];
  final Map<String, int> _bubbleIndex = {};

  StreamSubscription<TmkPluginEvent>? _eventsSubscription;
  late TmkSessionConfig _sessionConfig;
  late ConversationBubbleRenderPipeline _bubbleRenderPipeline;
  String? _sessionId;
  bool _isCreating = true;
  bool _isStarting = false;
  bool _isStarted = false;
  bool _isDownloading = false;
  bool _showOfflineDetails = true;
  bool _isLoadingLanguageOptions = false;
  String _statusText = '准备中...';
  TmkSessionMetricsEvent? _metrics;
  TmkOfflineModelStatus? _offlineModelStatus;
  List<TmkLanguageOption> _supportedLanguageOptions = const [];
  TmkOneToOnePlaybackMode _playbackMode = TmkOneToOnePlaybackMode.left;

  @override
  void initState() {
    super.initState();
    _sessionConfig = widget.config;
    _bubbleRenderPipeline = _createBubbleRenderPipeline(_sessionConfig);
    _eventsSubscription = TmkTranslationFlutter.events.listen(_handleEvent);
    unawaited(_loadSupportedLanguages());
    unawaited(_createSession());
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    final sessionId = _sessionId;
    if (sessionId != null) {
      unawaited(_disposeSession(sessionId));
    }
    super.dispose();
  }

  TmkLanguageSource get _languageSource {
    return _sessionConfig.mode == TmkTranslationMode.offline
        ? TmkLanguageSource.offline
        : TmkLanguageSource.online;
  }

  int get _configuredChannels {
    return _sessionConfig.scenario == TmkScenario.oneToOne ? 2 : 1;
  }

  ConversationBubbleRenderPipeline _createBubbleRenderPipeline(
    TmkSessionConfig config,
  ) {
    return ConversationBubbleRenderPipeline(
      scenario: config.scenario,
      mode: config.mode,
      selectedSourceLanguage: config.sourceLanguage,
      selectedTargetLanguage: config.targetLanguage,
    );
  }

  bool get _canStartListening {
    return !_isCreating &&
        !_isStarting &&
        !_isStarted &&
        _sessionId != null &&
        (_sessionConfig.mode != TmkTranslationMode.offline ||
            (_offlineModelStatus?.isReady ?? false));
  }

  Future<void> _disposeSession(String sessionId) async {
    try {
      await TmkTranslationFlutter.stopSession(sessionId);
    } catch (_) {}
    try {
      await TmkTranslationFlutter.disposeSession(sessionId);
    } catch (_) {}
  }

  Future<void> _createSession() async {
    final previousSessionId = _sessionId;
    if (previousSessionId != null) {
      await _disposeSession(previousSessionId);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _sessionId = null;
      _isCreating = true;
      _isStarting = false;
      _isStarted = false;
      _isDownloading = false;
      _metrics = null;
      _offlineModelStatus = null;
      _statusText = '准备会话中...';
      _bubbleRenderPipeline = _createBubbleRenderPipeline(_sessionConfig);
      _bubbles.clear();
      _bubbleIndex.clear();
    });
    try {
      final sessionId = await TmkTranslationFlutter.createSession(
        _sessionConfig,
      );
      if (_sessionConfig.scenario == TmkScenario.oneToOne) {
        await TmkTranslationFlutter.setOneToOnePlaybackMode(
          sessionId,
          _playbackMode,
        );
      }
      final offlineStatus = _sessionConfig.mode == TmkTranslationMode.offline
          ? await TmkTranslationFlutter.getOfflineModelStatus(sessionId)
          : null;
      if (!mounted) {
        return;
      }
      setState(() {
        _sessionId = sessionId;
        _offlineModelStatus = offlineStatus;
        _isCreating = false;
        _statusText = _initialStatusText(offlineStatus);
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

  String _initialStatusText(TmkOfflineModelStatus? offlineStatus) {
    if (_sessionConfig.mode == TmkTranslationMode.offline) {
      return offlineStatus?.detail ?? '请先检查当前语言对的离线模型状态';
    }
    if (_sessionConfig.scenario == TmkScenario.oneToOne) {
      return '在线通道配置已准备，点击“开始收听”开始采集';
    }
    return '在线通道配置已准备，点击“开始收听”开始采集';
  }

  Future<void> _loadSupportedLanguages() async {
    if (_isLoadingLanguageOptions) {
      return;
    }
    setState(() => _isLoadingLanguageOptions = true);
    try {
      final languages = await TmkTranslationFlutter.getSupportedLanguages(
        _languageSource,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _supportedLanguageOptions = languages;
        _isLoadingLanguageOptions = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoadingLanguageOptions = false;
        _statusText = '加载语言列表失败：$error';
      });
    }
  }

  Future<void> _startListening() async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    setState(() {
      _isStarting = true;
      _statusText = '正在启动收听...';
    });
    try {
      await TmkTranslationFlutter.startSession(sessionId);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isStarting = false;
        _statusText = '开始收听失败：$error';
      });
    }
  }

  Future<void> _stopListening() async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    try {
      await TmkTranslationFlutter.stopSession(sessionId);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusText = '停止收听失败：$error';
      });
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isStarted = false;
      _isStarting = false;
      _statusText = '收听已停止';
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
    try {
      await TmkTranslationFlutter.downloadOfflineModels(sessionId);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isDownloading = false;
        _statusText = '下载模型失败：$error';
      });
    }
  }

  Future<void> _cancelDownload() async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return;
    }
    await TmkTranslationFlutter.cancelOfflineDownload(sessionId);
    if (!mounted) {
      return;
    }
    setState(() {
      _isDownloading = false;
      _statusText = '已取消模型下载';
    });
  }

  Future<void> _changeSourceLanguage() async {
    if (_supportedLanguageOptions.isEmpty) {
      await _loadSupportedLanguages();
    }
    if (!mounted || _supportedLanguageOptions.isEmpty) {
      return;
    }
    final currentIndex = _supportedLanguageOptions.indexWhere(
      (item) => item.code == _sessionConfig.sourceLanguage,
    );
    final selected = await _showPickerSheet<TmkLanguageOption>(
      title: '选择语言',
      options: _supportedLanguageOptions,
      initialIndex: currentIndex >= 0 ? currentIndex : 0,
      labelBuilder: (item) => item.title,
    );
    if (selected == null || selected.code == _sessionConfig.sourceLanguage) {
      return;
    }
    if (selected.code == _sessionConfig.targetLanguage) {
      setState(() {
        _statusText = '源语言不能与目标语言一致';
      });
      return;
    }
    setState(() {
      _sessionConfig = _sessionConfig.copyWith(sourceLanguage: selected.code);
      _statusText = '正在切换语言...';
    });
    await _createSession();
  }

  Future<void> _changePlaybackMode() async {
    final selected = await _showPickerSheet<TmkOneToOnePlaybackMode>(
      title: '播放音源',
      options: TmkOneToOnePlaybackMode.values,
      initialIndex: TmkOneToOnePlaybackMode.values.indexOf(_playbackMode),
      labelBuilder: (item) => item.title,
    );
    if (selected == null || selected == _playbackMode) {
      return;
    }
    final sessionId = _sessionId;
    setState(() {
      _playbackMode = selected;
      _statusText = '播放音源已切换为${selected.title}';
    });
    if (sessionId == null) {
      return;
    }
    try {
      await TmkTranslationFlutter.setOneToOnePlaybackMode(sessionId, selected);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusText = '切换播放音源失败：$error';
      });
    }
  }

  Future<T?> _showPickerSheet<T>({
    required String title,
    required List<T> options,
    required int initialIndex,
    required String Function(T item) labelBuilder,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        var selectedIndex = initialIndex.clamp(0, options.length - 1);
        final controller = FixedExtentScrollController(
          initialItem: selectedIndex,
        );
        return SafeArea(
          top: false,
          child: Container(
            height: 320,
            decoration: const BoxDecoration(
              color: appSurface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            Navigator.of(context).pop(options[selectedIndex]),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: appBorder),
                Expanded(
                  child: CupertinoPicker(
                    scrollController: controller,
                    itemExtent: 40,
                    backgroundColor: Colors.transparent,
                    onSelectedItemChanged: (index) => selectedIndex = index,
                    children: options
                        .map(
                          (item) => Center(
                            child: Text(
                              labelBuilder(item),
                              style: const TextStyle(
                                color: appText,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _handleEvent(TmkPluginEvent event) {
    if (event.sessionId != _sessionId || !mounted) {
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
              summary: _sessionConfig.scenario == TmkScenario.oneToOne
                  ? '双向模型已就绪'
                  : '模型已就绪',
              detail: _sessionConfig.scenario == TmkScenario.oneToOne
                  ? '${_sessionConfig.sourceLanguage} ↔ ${_sessionConfig.targetLanguage} 可直接开始离线对话'
                  : '${_sessionConfig.sourceLanguage} → ${_sessionConfig.targetLanguage} 可直接开始离线收听',
            );
            _isDownloading = false;
          }
        });
      case TmkBubbleEvent():
      case TmkRecognizedEvent():
      case TmkTranslatedEvent():
        final snapshots = _bubbleRenderPipeline.consumePluginEvent(event);
        if (snapshots.isEmpty) {
          break;
        }
        setState(() {
          for (final snapshot in snapshots) {
            _applyBubbleSnapshot(snapshot);
          }
        });
      case TmkSessionMetricsEvent():
        setState(() {
          _metrics = event;
        });
      case TmkDownloadEvent():
        setState(() {
          _isDownloading = !event.isCompleted;
          _statusText = event.message;
          _offlineModelStatus = TmkOfflineModelStatus(
            isReady: event.isCompleted,
            isSupported: true,
            summary: event.isCompleted
                ? (_sessionConfig.scenario == TmkScenario.oneToOne
                      ? '双向模型已就绪'
                      : '模型已就绪')
                : '模型下载中',
            detail: event.message,
          );
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

  void _applyBubbleSnapshot(ConversationBubbleSnapshot snapshot) {
    final bubble = ConversationBubble(
      id: snapshot.id,
      bubbleId: snapshot.bubbleId,
      sdkSessionId: snapshot.sdkSessionId,
      lane: snapshot.lane,
      sourceLangCode: snapshot.sourceLangCode,
      targetLangCode: snapshot.targetLangCode,
      sourceText: snapshot.sourceText,
      translatedText: snapshot.translatedText,
    );
    final index = _bubbleIndex[bubble.id];
    if (index != null && index >= 0 && index < _bubbles.length) {
      _bubbles[index] = bubble;
      return;
    }
    _bubbleIndex[bubble.id] = _bubbles.length;
    _bubbles.add(bubble);
    _trimBubblesIfNeeded();
  }

  void _trimBubblesIfNeeded() {
    if (_bubbles.length <= _maxDisplayedBubbles) {
      return;
    }
    final overflow = _bubbles.length - _maxDisplayedBubbles;
    _bubbles.removeRange(0, overflow);
    _bubbleIndex
      ..clear()
      ..addEntries(
        _bubbles.indexed.map((entry) => MapEntry(entry.$2.id, entry.$1)),
      );
  }

  String _languageTitle(String code) {
    for (final option in _supportedLanguageOptions) {
      if (option.code == code) {
        return option.title;
      }
    }
    return code;
  }

  String _buildInfoText() {
    final sourceTitle = _languageTitle(_sessionConfig.sourceLanguage);
    final targetTitle = _languageTitle(_sessionConfig.targetLanguage);
    final metrics = _metrics;
    final capture = metrics == null || metrics.captureChannels <= 0
        ? '-'
        : '${metrics.captureSampleRate}Hz/${metrics.captureChannels}ch';
    final playback = metrics == null || metrics.playbackChannels <= 0
        ? '-'
        : '${metrics.playbackChannels}ch';
    final roomNo = metrics?.roomNo ?? '-';
    final buffer = StringBuffer(
      '房间:$roomNo  语言:$sourceTitle→$targetTitle  采集:$capture  回放:$playback',
    );
    if (_sessionConfig.scenario == TmkScenario.oneToOne) {
      buffer.write('  播放:${_playbackMode.title}');
    }
    return buffer.toString();
  }

  String _bubbleMetaText(ConversationBubble bubble) {
    final metrics = _metrics;
    final bubbleId = bubble.bubbleId;
    final configuredSampleRate = metrics?.configuredSampleRate ?? 16000;
    final configuredChannels =
        metrics?.configuredChannels ?? _configuredChannels;
    final capture = metrics == null || metrics.captureChannels <= 0
        ? '-'
        : '${metrics.captureSampleRate}Hz/${metrics.captureChannels}ch';
    final playback = metrics == null || metrics.playbackChannels <= 0
        ? '-'
        : '${metrics.playbackChannels}ch';
    final scenario =
        metrics?.scenario ??
        (_sessionConfig.scenario == TmkScenario.oneToOne
            ? 'oneToOne'
            : 'listen');
    final mode = metrics?.mode ?? _sessionConfig.mode.value;
    final lines = <String>[
      'sessionId: ${bubble.sdkSessionId.isEmpty ? "-" : bubble.sdkSessionId}  bubbleId: $bubbleId',
      '房间: ${metrics?.roomNo ?? "-"}  通道: $scenario/$mode',
      '采样: 配置${configuredSampleRate}Hz/${configuredChannels}ch  采集$capture  回放$playback',
    ];
    return lines.join('\n');
  }

  String _offlineActionTitle() {
    if (_isDownloading) {
      return '下载中...';
    }
    if (_offlineModelStatus?.isReady == true) {
      return '模型已就绪';
    }
    return _sessionConfig.scenario == TmkScenario.oneToOne ? '下载双向模型' : '下载模型';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_sessionConfig.scenario == TmkScenario.oneToOne)
            _AppBarAction(title: '播放音源', onPressed: _changePlaybackMode),
          _AppBarAction(title: '语言', onPressed: _changeSourceLanguage),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _statusText,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              _buildInfoText(),
              style: const TextStyle(fontSize: 12, color: appTextMuted),
            ),
            if (_sessionConfig.scenario == TmkScenario.oneToOne &&
                _sessionConfig.useFixedAudio) ...[
              const SizedBox(height: 4),
              const Text(
                '当前右声道使用固定音源模拟 1v1 第二路输入。',
                style: TextStyle(fontSize: 12, color: appTextMuted),
              ),
            ],
            const SizedBox(height: 10),
            if (_sessionConfig.mode == TmkTranslationMode.offline) ...[
              _OfflineControlPanel(
                buttonTitle: _offlineActionTitle(),
                buttonEnabled:
                    !_isDownloading && !(_offlineModelStatus?.isReady ?? false),
                showCancelButton: _isDownloading,
                showDetails: _showOfflineDetails,
                status: _offlineModelStatus,
                onDownload: _downloadModels,
                onCancel: _cancelDownload,
                onToggleDetails: () =>
                    setState(() => _showOfflineDetails = !_showOfflineDetails),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: _ControlButton(
                    title: _isStarting ? '正在启动...' : '开始收听',
                    onPressed: _canStartListening ? _startListening : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ControlButton(
                    title: '停止收听',
                    onPressed: _isStarted ? _stopListening : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _bubbles.isEmpty
                  ? const _EmptyBubbleState()
                  : ListView.separated(
                      itemCount: _bubbles.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final bubble = _bubbles[index];
                        return _ConversationBubbleTile(
                          bubble: bubble,
                          scenario: _sessionConfig.scenario,
                          metaText: _bubbleMetaText(bubble),
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

class _AppBarAction extends StatelessWidget {
  const _AppBarAction({required this.title, required this.onPressed});

  final String title;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: appText),
      child: Text(title),
    );
  }
}

class _OfflineControlPanel extends StatelessWidget {
  const _OfflineControlPanel({
    required this.buttonTitle,
    required this.buttonEnabled,
    required this.showCancelButton,
    required this.showDetails,
    required this.status,
    required this.onDownload,
    required this.onCancel,
    required this.onToggleDetails,
  });

  final String buttonTitle;
  final bool buttonEnabled;
  final bool showCancelButton;
  final bool showDetails;
  final TmkOfflineModelStatus? status;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onToggleDetails;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _CompactButton(
              title: buttonTitle,
              onPressed: buttonEnabled ? onDownload : null,
            ),
            if (showCancelButton)
              _CompactButton(title: '取消', onPressed: onCancel),
            _CompactButton(
              title: showDetails ? '收起详情' : '模型详情',
              onPressed: onToggleDetails,
            ),
          ],
        ),
        if (showDetails) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: appCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: appBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status?.summary ?? '检查离线模型中...',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  status?.detail ?? '请先确认当前语言对的离线模型状态。',
                  style: const TextStyle(
                    fontSize: 12,
                    color: appTextMuted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({required this.title, required this.onPressed});

  final String title;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      height: 36,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: enabled
              ? appPrimary.withValues(alpha: 0.14)
              : appCard,
          foregroundColor: enabled ? appText : appTextMuted,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _CompactButton extends StatelessWidget {
  const _CompactButton({required this.title, required this.onPressed});

  final String title;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      height: 32,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: enabled
              ? appPrimary.withValues(alpha: 0.14)
              : appCard,
          foregroundColor: enabled ? appText : appTextMuted,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _EmptyBubbleState extends StatelessWidget {
  const _EmptyBubbleState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: appCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: appBorder),
      ),
      child: const Text('等待识别结果...', style: TextStyle(color: appTextMuted)),
    );
  }
}

class _ConversationBubbleTile extends StatelessWidget {
  const _ConversationBubbleTile({
    required this.bubble,
    required this.scenario,
    required this.metaText,
  });

  final ConversationBubble bubble;
  final TmkScenario scenario;
  final String metaText;

  @override
  Widget build(BuildContext context) {
    final isRightBubble =
        scenario == TmkScenario.oneToOne && bubble.isRightLane;
    return Align(
      alignment: isRightBubble ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isRightBubble ? appPrimary.withValues(alpha: 0.14) : appCard,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                metaText,
                style: const TextStyle(
                  fontSize: 12,
                  color: appTextMuted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '源语言(${bubble.sourceLangCode})：${bubble.sourceDisplay}',
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 8),
              Text(
                '目标语言(${bubble.targetLangCode})：${bubble.translatedDisplay}',
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
