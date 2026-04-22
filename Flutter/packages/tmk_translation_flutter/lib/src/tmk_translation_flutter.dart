import 'dart:async';

import 'package:tmk_translation_platform_interface/tmk_translation_platform_interface.dart';

import 'method_channel_tmk_translation_platform.dart';

class TmkTranslationFlutter {
  TmkTranslationFlutter._();

  static TmkTranslationPlatform get _platform {
    MethodChannelTmkTranslationPlatform.registerWith();
    return TmkTranslationPlatform.instance;
  }

  static Stream<TmkPluginEvent> get events => _platform.events;

  static Future<TmkSettingsDraft> getCurrentSettings() {
    return _platform.getCurrentSettings();
  }

  static Future<TmkRuntimeStatus> initialize({
    String? appId,
    String? appSecret,
    TmkSettingsDraft? settings,
  }) {
    return _platform.initialize(
      appId: appId,
      appSecret: appSecret,
      settings: settings,
    );
  }

  static Future<TmkRuntimeStatus> applySettings(
    TmkSettingsDraft settings, {
    String? appId,
    String? appSecret,
  }) {
    return _platform.applySettings(
      settings,
      appId: appId,
      appSecret: appSecret,
    );
  }

  static Future<bool> verifyAuth() {
    return _platform.verifyAuth();
  }

  static Future<List<TmkLanguageOption>> getSupportedLanguages(
    TmkLanguageSource source,
  ) {
    return _platform.getSupportedLanguages(source);
  }

  static Future<TmkRuntimeStatus> getRuntimeStatus() {
    return _platform.getRuntimeStatus();
  }

  static Future<String?> exportDiagnosisLogs() {
    return _platform.exportDiagnosisLogs();
  }

  static Future<String> createSession(TmkSessionConfig config) {
    return _platform.createSession(config);
  }

  static Future<TmkOfflineModelStatus> getOfflineModelStatus(String sessionId) {
    return _platform.getOfflineModelStatus(sessionId);
  }

  static Future<void> downloadOfflineModels(String sessionId) {
    return _platform.downloadOfflineModels(sessionId);
  }

  static Future<void> cancelOfflineDownload(String sessionId) {
    return _platform.cancelOfflineDownload(sessionId);
  }

  static Future<void> startSession(String sessionId) {
    return _platform.startSession(sessionId);
  }

  static Future<void> stopSession(String sessionId) {
    return _platform.stopSession(sessionId);
  }

  static Future<void> disposeSession(String sessionId) {
    return _platform.disposeSession(sessionId);
  }
}
