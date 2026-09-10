import 'package:tmk_translation_flutter/tmk_translation_flutter.dart' as api;

import 'tmk_translation_models.dart';

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
  bool destroyExisting = false,
}) async {
  final sdk = api.TmkTranslationSdk.instance;
  // Android's native SDK cannot be destroyed before its first initialize
  // because its persistence layer does not exist yet. A normal bootstrap
  // initializes directly; settings re-application explicitly resets first.
  if (destroyExisting) {
    await sdk.destroy();
  }
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
      detail: '鉴权成功',
    ),
    offlineEngineStatus: TmkEngineStatus(
      kind: offline
          ? TmkEngineStatusKind.available
          : TmkEngineStatusKind.unavailable,
      summary: offline ? '可用' : '不可用',
      detail: offline ? '离线翻译已开通' : '当前账号未开通离线翻译',
    ),
    authInfo: const TmkAuthInfo(
      tokenSummary: '有效',
      tokenDetail: '鉴权成功，可继续创建房间或通道',
      autoRefreshSummary: '暂无数据',
      autoRefreshDetail: '当前 SDK 未暴露详细刷新信息',
    ),
    versionText: _sampleVersionText(version),
  );
}

String _sampleVersionText(String version) {
  final trimmed = version.trim();
  if (trimmed.startsWith('TmkTranslationSDK ')) return trimmed;
  final normalized = trimmed.startsWith('v') ? trimmed : 'v$trimmed';
  return 'TmkTranslationSDK $normalized';
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
  return api.TmkTranslationSessionConfig(
    mode: config.mode,
    scenario: config.scenario == TmkScenario.oneToOne
        ? api.TmkTranslationScenario.oneToOne
        : api.TmkTranslationScenario.listen,
    sourceLang: config.sourceLanguage,
    targetLang: config.targetLanguage,
    audioConfig: config.scenario == TmkScenario.oneToOne
        ? const api.TmkTranslationSessionAudioConfig(
            pcmChannels: 2,
            channelAudioMode: api.TmkChannelAudioMode.standard,
          )
        : const api.TmkTranslationSessionAudioConfig(),
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
