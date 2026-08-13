import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart' as api;

// This file is Sample-only glue. It intentionally keeps the demo's existing
// view models compiling while the SDK's public API remains the sole package
// boundary. No platform interface, Pigeon or channel type is imported here.
export 'package:tmk_translation_flutter/tmk_translation_flutter.dart'
    show TmkTranslationMode, TmkSpeakerChannel;

enum TmkScenario {
  listen('listen'),
  oneToOne('one_to_one');

  const TmkScenario(this.value);
  final String value;
}

enum TmkOneToOnePlaybackMode {
  left('left', '目标语言翻译'),
  right('right', '源语言翻译');

  const TmkOneToOnePlaybackMode(this.value, this.title);
  final String value;
  final String title;
}

enum TmkAudioSource {
  microphone('microphone'),
  external('external');

  const TmkAudioSource(this.value);
  final String value;
}

enum TmkAudioOutputMode {
  system('system'),
  external('external');

  const TmkAudioOutputMode(this.value);
  final String value;
}

enum TmkOneToOneChannelMode {
  interleaved('interleaved'),
  perChannel('per_channel');

  const TmkOneToOneChannelMode(this.value);
  final String value;
}

enum TmkLanguageSource {
  online('online'),
  offline('offline');

  const TmkLanguageSource(this.value);
  final String value;
}

enum TmkEngineStatusKind { checking, available, unavailable, placeholder }

enum TmkLogLevel { info, warning, error }

@immutable
class TmkSettingsDraft {
  const TmkSettingsDraft({
    required this.diagnosisEnabled,
    required this.consoleLogEnabled,
    required this.networkEnvironment,
    required this.mockEngineEnabled,
  });

  final bool diagnosisEnabled;
  final bool consoleLogEnabled;
  final String networkEnvironment;
  final bool mockEngineEnabled;

  factory TmkSettingsDraft.defaults() => const TmkSettingsDraft(
    diagnosisEnabled: true,
    consoleLogEnabled: false,
    networkEnvironment: 'test',
    mockEngineEnabled: false,
  );

  TmkSettingsDraft copyWith({
    bool? diagnosisEnabled,
    bool? consoleLogEnabled,
    String? networkEnvironment,
    bool? mockEngineEnabled,
  }) => TmkSettingsDraft(
    diagnosisEnabled: diagnosisEnabled ?? this.diagnosisEnabled,
    consoleLogEnabled: consoleLogEnabled ?? this.consoleLogEnabled,
    networkEnvironment: networkEnvironment ?? this.networkEnvironment,
    mockEngineEnabled: mockEngineEnabled ?? this.mockEngineEnabled,
  );
}

@immutable
class TmkEngineStatus {
  const TmkEngineStatus({
    required this.kind,
    required this.summary,
    required this.detail,
  });
  final TmkEngineStatusKind kind;
  final String summary;
  final String detail;
}

@immutable
class TmkAuthInfo {
  const TmkAuthInfo({
    required this.tokenSummary,
    required this.tokenDetail,
    required this.autoRefreshSummary,
    required this.autoRefreshDetail,
  });
  final String tokenSummary;
  final String tokenDetail;
  final String autoRefreshSummary;
  final String autoRefreshDetail;
}

@immutable
class TmkRuntimeStatus {
  const TmkRuntimeStatus({
    required this.onlineEngineStatus,
    required this.offlineEngineStatus,
    required this.authInfo,
    required this.versionText,
  });
  final TmkEngineStatus onlineEngineStatus;
  final TmkEngineStatus offlineEngineStatus;
  final TmkAuthInfo authInfo;
  final String versionText;
}

@immutable
class TmkLanguageOption {
  const TmkLanguageOption({
    required this.code,
    required this.familyCode,
    required this.title,
  });
  final String code;
  final String familyCode;
  final String title;
}

@immutable
class TmkSessionConfig {
  const TmkSessionConfig({
    required this.scenario,
    required this.mode,
    required this.sourceLanguage,
    required this.targetLanguage,
    this.useFixedAudio = true,
    this.capturePcm = false,
    this.audioSource = TmkAudioSource.external,
    this.audioOutputMode = TmkAudioOutputMode.external,
    this.oneToOneChannelMode = TmkOneToOneChannelMode.perChannel,
  });

  final TmkScenario scenario;
  final api.TmkTranslationMode mode;
  final String sourceLanguage;
  final String targetLanguage;
  final bool useFixedAudio;
  final bool capturePcm;
  final TmkAudioSource audioSource;
  final TmkAudioOutputMode audioOutputMode;
  final TmkOneToOneChannelMode oneToOneChannelMode;

  TmkSessionConfig copyWith({
    TmkScenario? scenario,
    api.TmkTranslationMode? mode,
    String? sourceLanguage,
    String? targetLanguage,
    bool? useFixedAudio,
    bool? capturePcm,
    TmkAudioSource? audioSource,
    TmkAudioOutputMode? audioOutputMode,
    TmkOneToOneChannelMode? oneToOneChannelMode,
  }) => TmkSessionConfig(
    scenario: scenario ?? this.scenario,
    mode: mode ?? this.mode,
    sourceLanguage: sourceLanguage ?? this.sourceLanguage,
    targetLanguage: targetLanguage ?? this.targetLanguage,
    useFixedAudio: useFixedAudio ?? this.useFixedAudio,
    capturePcm: capturePcm ?? this.capturePcm,
    audioSource: audioSource ?? this.audioSource,
    audioOutputMode: audioOutputMode ?? this.audioOutputMode,
    oneToOneChannelMode: oneToOneChannelMode ?? this.oneToOneChannelMode,
  );
}

@immutable
class TmkOfflineModelStatus {
  const TmkOfflineModelStatus({
    required this.isReady,
    required this.isSupported,
    required this.summary,
    required this.detail,
  });
  final bool isReady;
  final bool isSupported;
  final String summary;
  final String detail;
}

abstract class TmkPluginEvent {
  const TmkPluginEvent({required this.kind, required this.sessionId});
  final String kind;
  final String? sessionId;
}

abstract class TmkConversationTextEvent extends TmkPluginEvent {
  const TmkConversationTextEvent({
    required super.kind,
    required super.sessionId,
    required this.sdkSessionId,
    required this.sourceLangCode,
    required this.targetLangCode,
    required this.isFinal,
    required this.extraData,
    this.text,
    this.channel,
  });
  final String sdkSessionId;
  final String sourceLangCode;
  final String targetLangCode;
  final bool isFinal;
  final String? text;
  final String? channel;
  final Map<String, Object?> extraData;
}

class TmkRecognizedEvent extends TmkConversationTextEvent {
  const TmkRecognizedEvent({
    required super.sessionId,
    required super.sdkSessionId,
    required super.sourceLangCode,
    required super.targetLangCode,
    required super.isFinal,
    required super.extraData,
    super.text,
    super.channel,
  }) : super(kind: 'recognized');
}

class TmkTranslatedEvent extends TmkConversationTextEvent {
  const TmkTranslatedEvent({
    required super.sessionId,
    required super.sdkSessionId,
    required super.sourceLangCode,
    required super.targetLangCode,
    required super.isFinal,
    required super.extraData,
    super.text,
    super.channel,
  }) : super(kind: 'translated');
}

class TmkBubbleEvent extends TmkPluginEvent {
  const TmkBubbleEvent({
    required super.sessionId,
    required this.bubbleId,
    required this.sdkSessionId,
    required this.sourceLangCode,
    required this.targetLangCode,
    required this.isFinal,
    this.channel,
    this.sourceText,
    this.translatedText,
  }) : super(kind: 'bubble');
  final String bubbleId;
  final String sdkSessionId;
  final String sourceLangCode;
  final String targetLangCode;
  final bool isFinal;
  final String? channel;
  final String? sourceText;
  final String? translatedText;
}

class TmkSessionStateEvent extends TmkPluginEvent {
  const TmkSessionStateEvent({
    required super.sessionId,
    required this.statusText,
    this.isStarted,
    this.isStarting,
    this.isModelReady,
  }) : super(kind: 'session_state');
  final String statusText;
  final bool? isStarted;
  final bool? isStarting;
  final bool? isModelReady;
}

class TmkSessionMetricsEvent extends TmkPluginEvent {
  const TmkSessionMetricsEvent({
    required super.sessionId,
    required this.roomNo,
    required this.scenario,
    required this.mode,
    required this.configuredSampleRate,
    required this.configuredChannels,
    required this.captureSampleRate,
    required this.captureChannels,
    required this.playbackChannels,
  }) : super(kind: 'metrics');
  final String roomNo;
  final String scenario;
  final String mode;
  final int configuredSampleRate;
  final int configuredChannels;
  final int captureSampleRate;
  final int captureChannels;
  final int playbackChannels;
}

class TmkDownloadEvent extends TmkPluginEvent {
  const TmkDownloadEvent({
    required super.sessionId,
    required this.stage,
    required this.message,
    this.progress,
    this.isCompleted = false,
  }) : super(kind: 'download');
  final String stage;
  final String message;
  final double? progress;
  final bool isCompleted;
}

class TmkErrorEvent extends TmkPluginEvent {
  const TmkErrorEvent({
    required super.sessionId,
    required this.code,
    required this.message,
  }) : super(kind: 'error');
  final String code;
  final String message;
}

class TmkLogEvent extends TmkPluginEvent {
  const TmkLogEvent({
    required super.sessionId,
    required this.message,
    required this.level,
  }) : super(kind: 'log');
  final String message;
  final TmkLogLevel level;
}

class TmkActivityEvent extends TmkPluginEvent {
  const TmkActivityEvent({
    required super.sessionId,
    required this.channel,
    required this.volume,
  }) : super(kind: 'activity');
  final String? channel;
  final double volume;
}

final class TmkTranslationFlutter {
  TmkTranslationFlutter._();

  static final api.TmkTranslationSdk _sdk = api.TmkTranslationSdk.instance;
  static final StreamController<TmkPluginEvent> _events =
      StreamController<TmkPluginEvent>.broadcast();
  static final StreamController<api.TmkTranslatedAudioFrame> _audio =
      StreamController<api.TmkTranslatedAudioFrame>.broadcast();
  static final Map<String, api.TmkTranslationSession> _sessions =
      <String, api.TmkTranslationSession>{};
  static final Map<String, api.TmkOfflineModelDownloadOperation> _downloads =
      <String, api.TmkOfflineModelDownloadOperation>{};
  static final Map<String, StreamSubscription<api.TmkTranslationSessionEvent>>
  _subscriptions =
      <String, StreamSubscription<api.TmkTranslationSessionEvent>>{};

  static Stream<TmkPluginEvent> get events => _events.stream;
  static Stream<api.TmkTranslatedAudioFrame> get translatedAudioFrames =>
      _audio.stream;

  static Future<TmkSettingsDraft> getCurrentSettings() async =>
      TmkSettingsDraft.defaults();

  static Future<TmkRuntimeStatus> initialize({
    String? appId,
    String? appSecret,
    TmkSettingsDraft? settings,
  }) async {
    final draft = settings ?? TmkSettingsDraft.defaults();
    await _sdk.initialize(
      api.TmkTranslationGlobalConfig(
        appId: appId?.trim().isNotEmpty == true
            ? appId!
            : const String.fromEnvironment('TMK_APP_ID'),
        appSecret: appSecret?.trim().isNotEmpty == true
            ? appSecret!
            : const String.fromEnvironment('TMK_APP_SECRET'),
        diagnosisConfig: api.TmkDiagnosisConfig(
          enabled: draft.diagnosisEnabled,
          consoleOutputEnabled: draft.consoleLogEnabled,
        ),
      ),
    );
    await _sdk.verifyAuth();
    return getRuntimeStatus();
  }

  static Future<TmkRuntimeStatus> applySettings(
    TmkSettingsDraft settings, {
    String? appId,
    String? appSecret,
  }) => initialize(appId: appId, appSecret: appSecret, settings: settings);

  static Future<bool> verifyAuth() => _sdk.verifyAuth().then((_) => true);

  static Future<TmkRuntimeStatus> getRuntimeStatus() async {
    final version = await _sdk.sdkVersion();
    final offline = await _sdk.isOfflineTranslationSupported();
    return TmkRuntimeStatus(
      onlineEngineStatus: const TmkEngineStatus(
        kind: TmkEngineStatusKind.available,
        summary: '可用',
        detail: 'SDK 已初始化',
      ),
      offlineEngineStatus: TmkEngineStatus(
        kind: offline
            ? TmkEngineStatusKind.available
            : TmkEngineStatusKind.placeholder,
        summary: offline ? '可用' : '依赖模型',
        detail: offline ? '离线翻译已开通' : '当前账号未开通离线翻译能力',
      ),
      authInfo: const TmkAuthInfo(
        tokenSummary: '由 SDK 管理',
        tokenDetail: '凭据不会进入 Sample',
        autoRefreshSummary: 'SDK',
        autoRefreshDetail: '由原生 SDK 管理',
      ),
      versionText: version,
    );
  }

  static Future<List<TmkLanguageOption>> getSupportedLanguages(
    TmkLanguageSource source,
  ) async {
    final operation = source == TmkLanguageSource.online
        ? _sdk.getOnlineSupportedLanguages()
        : _sdk.getOfflineSupportedLanguages();
    final response = await operation.result;
    return response.localeOptions
        .map(
          (item) => TmkLanguageOption(
            code: item.code,
            familyCode: item.code.split('-').first,
            title: item.displayName,
          ),
        )
        .toList(growable: false);
  }

  static Future<String?> exportDiagnosisLogs() async =>
      (await _sdk.getDiagnosisLogDirectoryURL())?.toString();

  static Future<String> createSession(TmkSessionConfig config) async {
    final operation = _sdk.createSession(
      api.TmkTranslationSessionConfig(
        mode: config.mode,
        scenario: config.scenario == TmkScenario.oneToOne
            ? api.TmkTranslationScenario.oneToOne
            : api.TmkTranslationScenario.listen,
        sourceLang: config.sourceLanguage,
        targetLang: config.targetLanguage,
        audioConfig: api.TmkTranslationSessionAudioConfig(
          pcmChannels: config.scenario == TmkScenario.oneToOne ? 2 : 1,
          channelAudioMode:
              config.oneToOneChannelMode == TmkOneToOneChannelMode.perChannel
              ? api.TmkChannelAudioMode.lowLatency
              : api.TmkChannelAudioMode.standard,
        ),
      ),
    );
    // Attach before awaiting the creation result. The frozen SDK contract
    // shares this Streams instance with the successful Session and allows
    // native events to arrive as soon as the channel is created.
    final subscription = operation.streams.all.listen(_emitSessionEvent);
    late final api.TmkTranslationSession session;
    try {
      session = await operation.result;
    } catch (_) {
      await subscription.cancel();
      rethrow;
    }
    _sessions[session.id] = session;
    _subscriptions[session.id] = subscription;
    return session.id;
  }

  static Future<TmkOfflineModelStatus> getOfflineModelStatus(
    String sessionId,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) {
      return const TmkOfflineModelStatus(
        isReady: false,
        isSupported: false,
        summary: '会话不存在',
        detail: '',
      );
    }
    final ready = await _sdk.isOfflineModelReady(
      srcLang: session.config.sourceLang,
      dstLang: session.config.targetLang,
      scenario: session.config.scenario,
    );
    return TmkOfflineModelStatus(
      isReady: ready,
      isSupported: true,
      summary: ready ? '模型已就绪' : '需要下载模型',
      detail: ready ? '可开始离线翻译' : '请先下载模型',
    );
  }

  static Future<void> downloadOfflineModels(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    await _downloads.remove(sessionId)?.cancel();
    final operation = _sdk.downloadOfflineModels(
      srcLang: session.config.sourceLang,
      dstLang: session.config.targetLang,
      scenario: session.config.scenario,
    );
    _downloads[sessionId] = operation;
    final subscription = operation.events.listen(
      (event) => _emitDownloadEvent(sessionId, event),
    );
    try {
      await operation.result;
    } catch (_) {
      if (!operation.isCancelled) rethrow;
    } finally {
      await subscription.cancel();
      if (identical(_downloads[sessionId], operation)) {
        _downloads.remove(sessionId);
      }
    }
  }

  static Future<void> cancelOfflineDownload(String sessionId) async {
    await _downloads.remove(sessionId)?.cancel();
  }

  static Future<void> pushChannelAudio(
    String sessionId,
    Uint8List pcm,
    api.TmkSpeakerChannel channel,
  ) async {
    await _sessions[sessionId]?.pushStreamAudioData(
      pcm,
      speakerChannel: channel,
    );
  }

  static Future<void> pushStreamAudio(
    String sessionId,
    Uint8List pcm, {
    required int channelCount,
  }) async {
    await _sessions[sessionId]?.pushStreamAudioData(
      pcm,
      channelCount: channelCount,
    );
  }

  static Future<void> disposeSession(String sessionId) async {
    await _downloads.remove(sessionId)?.cancel();
    await _subscriptions.remove(sessionId)?.cancel();
    await _sessions.remove(sessionId)?.dispose();
  }

  static void _emitDownloadEvent(
    String sessionId,
    api.TmkOfflineModelDownloadEvent event,
  ) {
    switch (event) {
      case api.TmkOfflineModelDownloadProgress():
        final progress = event.fileTotalBytes > 0
            ? event.downloadedBytes / event.fileTotalBytes
            : null;
        _events.add(
          TmkDownloadEvent(
            sessionId: sessionId,
            stage: 'downloading',
            message: '(${event.index}/${event.total}) ${event.fileName}',
            progress: progress,
          ),
        );
      case api.TmkOfflineModelTotalProgress():
        final progress = event.totalBytesAll > 0
            ? event.downloadedBytesAll / event.totalBytesAll
            : null;
        _events.add(
          TmkDownloadEvent(
            sessionId: sessionId,
            stage: 'downloading',
            message: '正在下载离线模型',
            progress: progress,
          ),
        );
      case api.TmkOfflineModelUnzipProgress():
        _events.add(
          TmkDownloadEvent(
            sessionId: sessionId,
            stage: 'unzipping',
            message: '正在解压 ${event.fileName}',
            progress: event.progress,
          ),
        );
      case api.TmkOfflineModelReady():
        _events.add(
          TmkDownloadEvent(
            sessionId: sessionId,
            stage: 'completed',
            message: '离线模型已就绪',
            progress: 1,
            isCompleted: true,
          ),
        );
      case api.TmkOfflineModelFailed():
        _events.add(
          TmkErrorEvent(
            sessionId: sessionId,
            code: event.error.constantName,
            message: event.error.message,
          ),
        );
      case api.TmkOfflineModelNamedEvent():
        _events.add(
          TmkLogEvent(
            sessionId: sessionId,
            message: event.name,
            level: TmkLogLevel.info,
          ),
        );
    }
  }

  static void _emitSessionEvent(api.TmkTranslationSessionEvent event) {
    final sessionId = event.sessionId;
    if (event is api.TmkRecognizedEvent) {
      _events.add(
        TmkRecognizedEvent(
          sessionId: sessionId,
          sdkSessionId: event.result.sessionId,
          sourceLangCode: event.result.srcCode ?? '',
          targetLangCode: event.result.dstCode ?? '',
          isFinal: event.isFinal,
          text: event.result.data,
          channel: event.result.extraData['channel'] as String?,
          extraData: event.result.extraData,
        ),
      );
    } else if (event is api.TmkTranslatedEvent) {
      _events.add(
        TmkTranslatedEvent(
          sessionId: sessionId,
          sdkSessionId: event.result.sessionId,
          sourceLangCode: event.result.srcCode ?? '',
          targetLangCode: event.result.dstCode ?? '',
          isFinal: event.isFinal,
          text: event.result.data,
          channel: event.result.extraData['channel'] as String?,
          extraData: event.result.extraData,
        ),
      );
    } else if (event is api.TmkAudioDataReceivedEvent) {
      final sampleRate =
          _sessions[sessionId]?.config.audioConfig.pcmSampleRate ?? 16000;
      _audio.add(
        api.TmkTranslatedAudioFrame(
          sessionId: sessionId,
          data: event.data,
          sampleRate: sampleRate,
          channelCount: event.channelCount,
          route: event.route ?? api.TmkTranslatedAudioRoute.unknown,
        ),
      );
    } else if (event is api.TmkSessionStateChangedEvent) {
      _events.add(
        TmkSessionStateEvent(
          sessionId: sessionId,
          statusText: event.snapshot.message,
          isStarted:
              event.snapshot.state == api.TmkTranslationChannelState.running,
          isStarting:
              event.snapshot.state == api.TmkTranslationChannelState.starting,
        ),
      );
    } else if (event is api.TmkSessionErrorEvent) {
      _events.add(
        TmkErrorEvent(
          sessionId: sessionId,
          code: event.error.constantName,
          message: event.error.message,
        ),
      );
    } else if (event is api.TmkNamedEvent) {
      _events.add(_adaptNamedEvent(event));
    }
  }

  static TmkPluginEvent _adaptNamedEvent(api.TmkNamedEvent event) {
    final args = event.args is Map<Object?, Object?>
        ? event.args as Map<Object?, Object?>
        : const <Object?, Object?>{};
    switch (event.name) {
      case 'metrics':
        return TmkSessionMetricsEvent(
          sessionId: event.sessionId,
          roomNo: '${args['roomNo'] ?? '-'}',
          scenario: '${args['scenario'] ?? ''}',
          mode: '${args['mode'] ?? ''}',
          configuredSampleRate:
              (args['configuredSampleRate'] as num?)?.toInt() ?? 0,
          configuredChannels:
              (args['configuredChannels'] as num?)?.toInt() ?? 0,
          captureSampleRate: (args['captureSampleRate'] as num?)?.toInt() ?? 0,
          captureChannels: (args['captureChannels'] as num?)?.toInt() ?? 0,
          playbackChannels: (args['playbackChannels'] as num?)?.toInt() ?? 0,
        );
      case 'activity':
        return TmkActivityEvent(
          sessionId: event.sessionId,
          channel: args['channel'] as String?,
          volume: (args['volume'] as num?)?.toDouble() ?? 0,
        );
      case 'download':
        return TmkDownloadEvent(
          sessionId: event.sessionId,
          stage: '${args['stage'] ?? 'downloading'}',
          message: '${args['message'] ?? ''}',
          progress: (args['progress'] as num?)?.toDouble(),
          isCompleted: args['isCompleted'] as bool? ?? false,
        );
      default:
        return TmkLogEvent(
          sessionId: event.sessionId,
          message: '${args['message'] ?? event.name}',
          level: switch (args['level']) {
            'warning' => TmkLogLevel.warning,
            'error' => TmkLogLevel.error,
            _ => TmkLogLevel.info,
          },
        );
    }
  }
}
