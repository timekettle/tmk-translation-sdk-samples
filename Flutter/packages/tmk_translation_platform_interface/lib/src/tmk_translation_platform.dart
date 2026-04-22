import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'models.dart';

abstract class TmkTranslationPlatform extends PlatformInterface {
  TmkTranslationPlatform() : super(token: _token);

  static final Object _token = Object();

  static TmkTranslationPlatform _instance = _PlaceholderPlatform();

  static TmkTranslationPlatform get instance => _instance;

  static set instance(TmkTranslationPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Stream<TmkPluginEvent> get events;

  Future<TmkSettingsDraft> getCurrentSettings();

  Future<TmkRuntimeStatus> initialize({
    String? appId,
    String? appSecret,
    TmkSettingsDraft? settings,
  });

  Future<TmkRuntimeStatus> applySettings(
    TmkSettingsDraft settings, {
    String? appId,
    String? appSecret,
  });

  Future<bool> verifyAuth();

  Future<List<TmkLanguageOption>> getSupportedLanguages(TmkLanguageSource source);

  Future<TmkRuntimeStatus> getRuntimeStatus();

  Future<String?> exportDiagnosisLogs();

  Future<String> createSession(TmkSessionConfig config);

  Future<TmkOfflineModelStatus> getOfflineModelStatus(String sessionId);

  Future<void> downloadOfflineModels(String sessionId);

  Future<void> cancelOfflineDownload(String sessionId);

  Future<void> startSession(String sessionId);

  Future<void> setOneToOnePlaybackMode(
    String sessionId,
    TmkOneToOnePlaybackMode mode,
  );

  Future<void> stopSession(String sessionId);

  Future<void> disposeSession(String sessionId);
}

class _PlaceholderPlatform extends TmkTranslationPlatform {
  @override
  Stream<TmkPluginEvent> get events => const Stream<TmkPluginEvent>.empty();

  Never _unsupported() {
    throw UnimplementedError('TmkTranslationPlatform has not been initialized.');
  }

  @override
  Future<TmkRuntimeStatus> applySettings(
    TmkSettingsDraft settings, {
    String? appId,
    String? appSecret,
  }) async {
    _unsupported();
  }

  @override
  Future<void> cancelOfflineDownload(String sessionId) async {
    _unsupported();
  }

  @override
  Future<String> createSession(TmkSessionConfig config) async {
    _unsupported();
  }

  @override
  Future<void> disposeSession(String sessionId) async {
    _unsupported();
  }

  @override
  Future<void> downloadOfflineModels(String sessionId) async {
    _unsupported();
  }

  @override
  Future<String?> exportDiagnosisLogs() async {
    _unsupported();
  }

  @override
  Future<TmkSettingsDraft> getCurrentSettings() async {
    _unsupported();
  }

  @override
  Future<TmkOfflineModelStatus> getOfflineModelStatus(String sessionId) async {
    _unsupported();
  }

  @override
  Future<TmkRuntimeStatus> getRuntimeStatus() async {
    _unsupported();
  }

  @override
  Future<List<TmkLanguageOption>> getSupportedLanguages(
    TmkLanguageSource source,
  ) async {
    _unsupported();
  }

  @override
  Future<TmkRuntimeStatus> initialize({
    String? appId,
    String? appSecret,
    TmkSettingsDraft? settings,
  }) async {
    _unsupported();
  }

  @override
  Future<void> startSession(String sessionId) async {
    _unsupported();
  }

  @override
  Future<void> setOneToOnePlaybackMode(
    String sessionId,
    TmkOneToOnePlaybackMode mode,
  ) async {
    _unsupported();
  }

  @override
  Future<void> stopSession(String sessionId) async {
    _unsupported();
  }

  @override
  Future<bool> verifyAuth() async {
    _unsupported();
  }
}
