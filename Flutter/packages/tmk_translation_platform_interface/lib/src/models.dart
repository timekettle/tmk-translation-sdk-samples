import 'package:flutter/foundation.dart';

enum TmkScenario {
  listen('listen'),
  oneToOne('one_to_one');

  const TmkScenario(this.value);

  final String value;

  static TmkScenario fromValue(String value) {
    return TmkScenario.values.firstWhere(
      (item) => item.value == value,
      orElse: () => TmkScenario.listen,
    );
  }
}

enum TmkTranslationMode {
  online('online'),
  offline('offline'),
  auto('auto'),
  mix('mix');

  const TmkTranslationMode(this.value);

  final String value;

  static TmkTranslationMode fromValue(String value) {
    return TmkTranslationMode.values.firstWhere(
      (item) => item.value == value,
      orElse: () => TmkTranslationMode.online,
    );
  }
}

enum TmkLanguageSource {
  online('online'),
  offline('offline');

  const TmkLanguageSource(this.value);

  final String value;

  static TmkLanguageSource fromValue(String value) {
    return TmkLanguageSource.values.firstWhere(
      (item) => item.value == value,
      orElse: () => TmkLanguageSource.online,
    );
  }
}

enum TmkEngineStatusKind {
  checking('checking'),
  available('available'),
  unavailable('unavailable'),
  placeholder('placeholder');

  const TmkEngineStatusKind(this.value);

  final String value;

  static TmkEngineStatusKind fromValue(String value) {
    return TmkEngineStatusKind.values.firstWhere(
      (item) => item.value == value,
      orElse: () => TmkEngineStatusKind.placeholder,
    );
  }
}

enum TmkLogLevel {
  info('info'),
  warning('warning'),
  error('error');

  const TmkLogLevel(this.value);

  final String value;

  static TmkLogLevel fromValue(String? value) {
    return TmkLogLevel.values.firstWhere(
      (item) => item.value == value,
      orElse: () => TmkLogLevel.info,
    );
  }
}

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

  factory TmkSettingsDraft.defaults() {
    return const TmkSettingsDraft(
      diagnosisEnabled: false,
      consoleLogEnabled: true,
      networkEnvironment: 'test',
      mockEngineEnabled: false,
    );
  }

  factory TmkSettingsDraft.fromMap(Map<Object?, Object?> map) {
    return TmkSettingsDraft(
      diagnosisEnabled: map['diagnosisEnabled'] as bool? ?? false,
      consoleLogEnabled: map['consoleLogEnabled'] as bool? ?? true,
      networkEnvironment: map['networkEnvironment'] as String? ?? 'test',
      mockEngineEnabled: map['mockEngineEnabled'] as bool? ?? false,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'diagnosisEnabled': diagnosisEnabled,
      'consoleLogEnabled': consoleLogEnabled,
      'networkEnvironment': networkEnvironment,
      'mockEngineEnabled': mockEngineEnabled,
    };
  }

  TmkSettingsDraft copyWith({
    bool? diagnosisEnabled,
    bool? consoleLogEnabled,
    String? networkEnvironment,
    bool? mockEngineEnabled,
  }) {
    return TmkSettingsDraft(
      diagnosisEnabled: diagnosisEnabled ?? this.diagnosisEnabled,
      consoleLogEnabled: consoleLogEnabled ?? this.consoleLogEnabled,
      networkEnvironment: networkEnvironment ?? this.networkEnvironment,
      mockEngineEnabled: mockEngineEnabled ?? this.mockEngineEnabled,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TmkSettingsDraft &&
        other.diagnosisEnabled == diagnosisEnabled &&
        other.consoleLogEnabled == consoleLogEnabled &&
        other.networkEnvironment == networkEnvironment &&
        other.mockEngineEnabled == mockEngineEnabled;
  }

  @override
  int get hashCode => Object.hash(
        diagnosisEnabled,
        consoleLogEnabled,
        networkEnvironment,
        mockEngineEnabled,
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

  factory TmkEngineStatus.fromMap(Map<Object?, Object?> map) {
    return TmkEngineStatus(
      kind: TmkEngineStatusKind.fromValue(map['kind'] as String? ?? ''),
      summary: map['summary'] as String? ?? '',
      detail: map['detail'] as String? ?? '',
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'kind': kind.value,
      'summary': summary,
      'detail': detail,
    };
  }
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

  factory TmkAuthInfo.fromMap(Map<Object?, Object?> map) {
    return TmkAuthInfo(
      tokenSummary: map['tokenSummary'] as String? ?? '',
      tokenDetail: map['tokenDetail'] as String? ?? '',
      autoRefreshSummary: map['autoRefreshSummary'] as String? ?? '',
      autoRefreshDetail: map['autoRefreshDetail'] as String? ?? '',
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'tokenSummary': tokenSummary,
      'tokenDetail': tokenDetail,
      'autoRefreshSummary': autoRefreshSummary,
      'autoRefreshDetail': autoRefreshDetail,
    };
  }
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

  factory TmkRuntimeStatus.fromMap(Map<Object?, Object?> map) {
    return TmkRuntimeStatus(
      onlineEngineStatus: TmkEngineStatus.fromMap(
        map['onlineEngineStatus'] as Map<Object?, Object?>? ?? const {},
      ),
      offlineEngineStatus: TmkEngineStatus.fromMap(
        map['offlineEngineStatus'] as Map<Object?, Object?>? ?? const {},
      ),
      authInfo: TmkAuthInfo.fromMap(
        map['authInfo'] as Map<Object?, Object?>? ?? const {},
      ),
      versionText: map['versionText'] as String? ?? 'TmkTranslationSDK',
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'onlineEngineStatus': onlineEngineStatus.toMap(),
      'offlineEngineStatus': offlineEngineStatus.toMap(),
      'authInfo': authInfo.toMap(),
      'versionText': versionText,
    };
  }
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

  factory TmkLanguageOption.fromMap(Map<Object?, Object?> map) {
    return TmkLanguageOption(
      code: map['code'] as String? ?? '',
      familyCode: map['familyCode'] as String? ?? '',
      title: map['title'] as String? ?? '',
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'code': code,
      'familyCode': familyCode,
      'title': title,
    };
  }
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
  });

  final TmkScenario scenario;
  final TmkTranslationMode mode;
  final String sourceLanguage;
  final String targetLanguage;
  final bool useFixedAudio;
  final bool capturePcm;

  factory TmkSessionConfig.fromMap(Map<Object?, Object?> map) {
    return TmkSessionConfig(
      scenario: TmkScenario.fromValue(map['scenario'] as String? ?? ''),
      mode: TmkTranslationMode.fromValue(map['mode'] as String? ?? ''),
      sourceLanguage: map['sourceLanguage'] as String? ?? 'zh-CN',
      targetLanguage: map['targetLanguage'] as String? ?? 'en-US',
      useFixedAudio: map['useFixedAudio'] as bool? ?? true,
      capturePcm: map['capturePcm'] as bool? ?? false,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'scenario': scenario.value,
      'mode': mode.value,
      'sourceLanguage': sourceLanguage,
      'targetLanguage': targetLanguage,
      'useFixedAudio': useFixedAudio,
      'capturePcm': capturePcm,
    };
  }

  TmkSessionConfig copyWith({
    TmkScenario? scenario,
    TmkTranslationMode? mode,
    String? sourceLanguage,
    String? targetLanguage,
    bool? useFixedAudio,
    bool? capturePcm,
  }) {
    return TmkSessionConfig(
      scenario: scenario ?? this.scenario,
      mode: mode ?? this.mode,
      sourceLanguage: sourceLanguage ?? this.sourceLanguage,
      targetLanguage: targetLanguage ?? this.targetLanguage,
      useFixedAudio: useFixedAudio ?? this.useFixedAudio,
      capturePcm: capturePcm ?? this.capturePcm,
    );
  }
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

  factory TmkOfflineModelStatus.fromMap(Map<Object?, Object?> map) {
    return TmkOfflineModelStatus(
      isReady: map['isReady'] as bool? ?? false,
      isSupported: map['isSupported'] as bool? ?? true,
      summary: map['summary'] as String? ?? '',
      detail: map['detail'] as String? ?? '',
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'isReady': isReady,
      'isSupported': isSupported,
      'summary': summary,
      'detail': detail,
    };
  }
}

@immutable
abstract class TmkPluginEvent {
  const TmkPluginEvent({
    required this.kind,
    required this.sessionId,
  });

  final String kind;
  final String? sessionId;

  static TmkPluginEvent fromMap(Map<Object?, Object?> map) {
    final kind = map['kind'] as String? ?? '';
    switch (kind) {
      case 'session_state':
        return TmkSessionStateEvent.fromMap(map);
      case 'bubble':
        return TmkBubbleEvent.fromMap(map);
      case 'download':
        return TmkDownloadEvent.fromMap(map);
      case 'error':
        return TmkErrorEvent.fromMap(map);
      case 'log':
      default:
        return TmkLogEvent.fromMap(map);
    }
  }
}

@immutable
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

  factory TmkSessionStateEvent.fromMap(Map<Object?, Object?> map) {
    return TmkSessionStateEvent(
      sessionId: map['sessionId'] as String?,
      statusText: map['statusText'] as String? ?? '',
      isStarted: map['isStarted'] as bool?,
      isStarting: map['isStarting'] as bool?,
      isModelReady: map['isModelReady'] as bool?,
    );
  }
}

@immutable
class TmkBubbleEvent extends TmkPluginEvent {
  const TmkBubbleEvent({
    required super.sessionId,
    required this.bubbleId,
    required this.sourceLangCode,
    required this.targetLangCode,
    required this.isFinal,
    this.channel,
    this.sourceText,
    this.translatedText,
  }) : super(kind: 'bubble');

  final String bubbleId;
  final String sourceLangCode;
  final String targetLangCode;
  final bool isFinal;
  final String? channel;
  final String? sourceText;
  final String? translatedText;

  factory TmkBubbleEvent.fromMap(Map<Object?, Object?> map) {
    return TmkBubbleEvent(
      sessionId: map['sessionId'] as String?,
      bubbleId: map['bubbleId'] as String? ?? '',
      sourceLangCode: map['sourceLangCode'] as String? ?? '',
      targetLangCode: map['targetLangCode'] as String? ?? '',
      isFinal: map['isFinal'] as bool? ?? false,
      channel: map['channel'] as String?,
      sourceText: map['sourceText'] as String?,
      translatedText: map['translatedText'] as String?,
    );
  }
}

@immutable
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

  factory TmkDownloadEvent.fromMap(Map<Object?, Object?> map) {
    return TmkDownloadEvent(
      sessionId: map['sessionId'] as String?,
      stage: map['stage'] as String? ?? 'downloading',
      message: map['message'] as String? ?? '',
      progress: (map['progress'] as num?)?.toDouble(),
      isCompleted: map['isCompleted'] as bool? ?? false,
    );
  }
}

@immutable
class TmkLogEvent extends TmkPluginEvent {
  const TmkLogEvent({
    required super.sessionId,
    required this.message,
    required this.level,
  }) : super(kind: 'log');

  final String message;
  final TmkLogLevel level;

  factory TmkLogEvent.fromMap(Map<Object?, Object?> map) {
    return TmkLogEvent(
      sessionId: map['sessionId'] as String?,
      message: map['message'] as String? ?? '',
      level: TmkLogLevel.fromValue(map['level'] as String?),
    );
  }
}

@immutable
class TmkErrorEvent extends TmkPluginEvent {
  const TmkErrorEvent({
    required super.sessionId,
    required this.code,
    required this.message,
  }) : super(kind: 'error');

  final String code;
  final String message;

  factory TmkErrorEvent.fromMap(Map<Object?, Object?> map) {
    return TmkErrorEvent(
      sessionId: map['sessionId'] as String?,
      code: map['code'] as String? ?? 'unknown_error',
      message: map['message'] as String? ?? '',
    );
  }
}
