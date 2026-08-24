import 'package:tmk_translation_flutter/tmk_translation_flutter.dart' as api;

import 'tmk_translation_models.dart';

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
