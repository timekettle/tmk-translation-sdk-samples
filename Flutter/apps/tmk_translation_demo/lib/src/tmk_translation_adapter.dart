import 'package:flutter/foundation.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart' as api;

// This file contains Sample-owned view models and small DTO/event mappers.
// Every SDK call still goes through the public TmkTranslationSdk and every
// active channel is held by the page that created its TmkTranslationSession.
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

class TmkAudioDataEvent extends TmkPluginEvent {
  TmkAudioDataEvent({
    required super.sessionId,
    required this.data,
    required this.sampleRate,
    required this.channelCount,
    required this.route,
  }) : super(kind: 'audio_data');

  final Uint8List data;
  final int sampleRate;
  final int channelCount;
  final api.TmkTranslatedAudioRoute? route;
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

api.TmkTranslationGlobalConfig sampleGlobalConfig(
  TmkSettingsDraft settings, {
  String? appId,
  String? appSecret,
}) {
  final resolvedAppId = appId?.trim().isNotEmpty == true
      ? appId!.trim()
      : const String.fromEnvironment('TMK_APP_ID');
  final resolvedAppSecret = appSecret?.trim().isNotEmpty == true
      ? appSecret!.trim()
      : const String.fromEnvironment('TMK_APP_SECRET');
  return api.TmkTranslationGlobalConfig(
    appId: resolvedAppId,
    appSecret: resolvedAppSecret,
    networkEnvironment: api.TmkTranslationNetworkEnvironment.fromValue(
      settings.networkEnvironment,
    ),
    diagnosisConfig: api.TmkDiagnosisConfig(
      enabled: settings.diagnosisEnabled,
      consoleOutputEnabled: settings.consoleLogEnabled,
    ),
  );
}

Future<TmkRuntimeStatus> initializeSampleSdk({
  required TmkSettingsDraft settings,
  String? appId,
  String? appSecret,
}) async {
  final sdk = api.TmkTranslationSdk.instance;
  await sdk.initialize(
    sampleGlobalConfig(settings, appId: appId, appSecret: appSecret),
  );
  await sdk.verifyAuth();
  return readSampleRuntimeStatus(sdk);
}

Future<TmkRuntimeStatus> readSampleRuntimeStatus(
  api.TmkTranslationSdk sdk,
) async {
  final version = await sdk.sdkVersion();
  final offline = await sdk.isOfflineTranslationSupported();
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

Future<List<TmkLanguageOption>> loadSampleLanguages(
  api.TmkTranslationSdk sdk,
  TmkLanguageSource source,
) async {
  final operation = source == TmkLanguageSource.online
      ? sdk.getOnlineSupportedLanguages()
      : sdk.getOfflineSupportedLanguages();
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

api.TmkTranslationSessionConfig toSdkSessionConfig(TmkSessionConfig config) {
  // The one-to-one per-channel normalization now lives in the SDK layer:
  // TmkTranslationSessionConfig normalizes one-to-one sessions to the
  // per-channel (low-latency) contract, so the Sample no longer decides the
  // channel routing itself.
  return api.TmkTranslationSessionConfig(
    mode: config.mode,
    scenario: config.scenario == TmkScenario.oneToOne
        ? api.TmkTranslationScenario.oneToOne
        : api.TmkTranslationScenario.listen,
    sourceLang: config.sourceLanguage,
    targetLang: config.targetLanguage,
  );
}

Future<TmkOfflineModelStatus> readOfflineModelStatus(
  api.TmkTranslationSdk sdk,
  api.TmkTranslationSession session,
) async {
  final ready = await sdk.isOfflineModelReady(
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

TmkPluginEvent adaptSessionEvent(api.TmkTranslationSessionEvent event) {
  final sessionId = event.sessionId;
  if (event is api.TmkRecognizedEvent) {
    return TmkRecognizedEvent(
      sessionId: sessionId,
      sdkSessionId: event.result.sessionId,
      sourceLangCode: event.result.srcCode ?? '',
      targetLangCode: event.result.dstCode ?? '',
      isFinal: event.isFinal,
      text: event.result.data,
      channel: event.result.extraData['channel'] as String?,
      extraData: event.result.extraData,
    );
  }
  if (event is api.TmkTranslatedEvent) {
    return TmkTranslatedEvent(
      sessionId: sessionId,
      sdkSessionId: event.result.sessionId,
      sourceLangCode: event.result.srcCode ?? '',
      targetLangCode: event.result.dstCode ?? '',
      isFinal: event.isFinal,
      text: event.result.data,
      channel: event.result.extraData['channel'] as String?,
      extraData: event.result.extraData,
    );
  }
  if (event is api.TmkAudioDataReceivedEvent) {
    return TmkAudioDataEvent(
      sessionId: sessionId,
      data: event.data,
      sampleRate: event.sampleRate,
      channelCount: event.channelCount,
      route: event.route,
    );
  }
  if (event is api.TmkSessionStateChangedEvent) {
    return TmkSessionStateEvent(
      sessionId: sessionId,
      statusText: event.snapshot.message,
      isStarted: event.snapshot.state == api.TmkTranslationChannelState.running,
      isStarting:
          event.snapshot.state == api.TmkTranslationChannelState.starting,
    );
  }
  if (event is api.TmkSessionErrorEvent) {
    return TmkErrorEvent(
      sessionId: sessionId,
      code: event.error.constantName,
      message: event.error.message,
    );
  }
  if (event is api.TmkNamedEvent) {
    return adaptNamedEvent(event);
  }
  return TmkLogEvent(
    sessionId: sessionId,
    message: '未知 SDK 事件',
    level: TmkLogLevel.warning,
  );
}

TmkPluginEvent adaptOfflineModelDownloadEvent(
  String sessionId,
  api.TmkOfflineModelDownloadEvent event,
) {
  switch (event) {
    case api.TmkOfflineModelDownloadProgress():
      final progress = event.fileTotalBytes > 0
          ? event.downloadedBytes / event.fileTotalBytes
          : null;
      return TmkDownloadEvent(
        sessionId: sessionId,
        stage: 'downloading',
        message: '(${event.index}/${event.total}) ${event.fileName}',
        progress: progress,
      );
    case api.TmkOfflineModelTotalProgress():
      final progress = event.totalBytesAll > 0
          ? event.downloadedBytesAll / event.totalBytesAll
          : null;
      return TmkDownloadEvent(
        sessionId: sessionId,
        stage: 'downloading',
        message: '正在下载离线模型',
        progress: progress,
      );
    case api.TmkOfflineModelUnzipProgress():
      return TmkDownloadEvent(
        sessionId: sessionId,
        stage: 'unzipping',
        message: '正在解压 ${event.fileName}',
        progress: event.progress,
      );
    case api.TmkOfflineModelReady():
      return TmkDownloadEvent(
        sessionId: sessionId,
        stage: 'completed',
        message: '离线模型已就绪',
        progress: 1,
        isCompleted: true,
      );
    case api.TmkOfflineModelFailed():
      return TmkErrorEvent(
        sessionId: sessionId,
        code: event.error.constantName,
        message: event.error.message,
      );
    case api.TmkOfflineModelNamedEvent():
      return TmkLogEvent(
        sessionId: sessionId,
        message: event.name,
        level: TmkLogLevel.info,
      );
    case api.TmkOfflineModelDownloadEvent():
      return TmkLogEvent(
        sessionId: sessionId,
        message: '未知离线模型事件',
        level: TmkLogLevel.warning,
      );
  }
}

TmkPluginEvent adaptNamedEvent(api.TmkNamedEvent event) {
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
        configuredChannels: (args['configuredChannels'] as num?)?.toInt() ?? 0,
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
