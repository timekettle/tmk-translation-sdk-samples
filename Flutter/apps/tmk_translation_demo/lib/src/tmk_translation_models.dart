import 'package:flutter/foundation.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart' as api;

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
    diagnosisEnabled: false,
    consoleLogEnabled: true,
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
  });

  final TmkScenario scenario;
  final api.TmkTranslationMode mode;
  final String sourceLanguage;
  final String targetLanguage;
  final bool useFixedAudio;

  TmkSessionConfig copyWith({
    TmkScenario? scenario,
    api.TmkTranslationMode? mode,
    String? sourceLanguage,
    String? targetLanguage,
    bool? useFixedAudio,
  }) => TmkSessionConfig(
    scenario: scenario ?? this.scenario,
    mode: mode ?? this.mode,
    sourceLanguage: sourceLanguage ?? this.sourceLanguage,
    targetLanguage: targetLanguage ?? this.targetLanguage,
    useFixedAudio: useFixedAudio ?? this.useFixedAudio,
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
    required this.snapshot,
    this.isModelReady,
  }) : super(kind: 'session_state');
  final api.TmkTranslationChannelStateSnapshot snapshot;
  String get statusText => snapshot.message;
  bool get isStarted =>
      snapshot.state == api.TmkTranslationChannelState.running;
  bool get isStarting =>
      snapshot.state == api.TmkTranslationChannelState.starting;
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
  const TmkErrorEvent({required super.sessionId, required this.error})
    : super(kind: 'error');
  final api.TmkTranslationError error;
  String get code => error.constantName;
  String get message => error.message;
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
