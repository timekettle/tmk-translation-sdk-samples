import 'dart:async';

import 'package:flutter/services.dart';
import 'package:tmk_translation_platform_interface/tmk_translation_platform_interface.dart';

class MethodChannelTmkTranslationPlatform extends TmkTranslationPlatform {
  static bool _registered = false;

  MethodChannelTmkTranslationPlatform() {
    _events = _eventChannel.receiveBroadcastStream().map((dynamic event) {
      final rawMap = event as Map<Object?, Object?>? ?? const {};
      return TmkPluginEvent.fromMap(rawMap);
    }).asBroadcastStream();
  }

  static const MethodChannel _methodChannel = MethodChannel(
    'co.timekettle.translation.flutter/methods',
  );
  static const EventChannel _eventChannel = EventChannel(
    'co.timekettle.translation.flutter/events',
  );

  late final Stream<TmkPluginEvent> _events;

  static void registerWith() {
    if (_registered) {
      return;
    }
    TmkTranslationPlatform.instance = MethodChannelTmkTranslationPlatform();
    _registered = true;
  }

  @override
  Stream<TmkPluginEvent> get events => _events;

  Future<Map<Object?, Object?>> _invokeMap(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    final result = await _methodChannel.invokeMethod<Object?>(method, arguments);
    return result as Map<Object?, Object?>? ?? const {};
  }

  @override
  Future<TmkSettingsDraft> getCurrentSettings() async {
    return TmkSettingsDraft.fromMap(await _invokeMap('getCurrentSettings'));
  }

  @override
  Future<TmkRuntimeStatus> initialize({
    String? appId,
    String? appSecret,
    TmkSettingsDraft? settings,
  }) async {
    final payload = <String, Object?>{
      'appId': appId,
      'appSecret': appSecret,
      'settings': settings?.toMap(),
    };
    return TmkRuntimeStatus.fromMap(await _invokeMap('initialize', payload));
  }

  @override
  Future<TmkRuntimeStatus> applySettings(
    TmkSettingsDraft settings, {
    String? appId,
    String? appSecret,
  }) async {
    final payload = <String, Object?>{
      'appId': appId,
      'appSecret': appSecret,
      'settings': settings.toMap(),
    };
    return TmkRuntimeStatus.fromMap(await _invokeMap('applySettings', payload));
  }

  @override
  Future<bool> verifyAuth() async {
    final result = await _methodChannel.invokeMethod<bool>('verifyAuth');
    return result ?? false;
  }

  @override
  Future<List<TmkLanguageOption>> getSupportedLanguages(
    TmkLanguageSource source,
  ) async {
    final result = await _methodChannel.invokeListMethod<Object?>(
      'getSupportedLanguages',
      <String, Object?>{'source': source.value},
    );
    return (result ?? const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map(TmkLanguageOption.fromMap)
        .toList(growable: false);
  }

  @override
  Future<TmkRuntimeStatus> getRuntimeStatus() async {
    return TmkRuntimeStatus.fromMap(await _invokeMap('getRuntimeStatus'));
  }

  @override
  Future<String?> exportDiagnosisLogs() async {
    final result = await _methodChannel.invokeMethod<String>('exportDiagnosisLogs');
    return result;
  }

  @override
  Future<String> createSession(TmkSessionConfig config) async {
    final result = await _methodChannel.invokeMethod<String>(
      'createSession',
      config.toMap(),
    );
    if (result == null || result.isEmpty) {
      throw PlatformException(
        code: 'empty_session_id',
        message: 'createSession returned an empty session identifier.',
      );
    }
    return result;
  }

  @override
  Future<TmkOfflineModelStatus> getOfflineModelStatus(String sessionId) async {
    return TmkOfflineModelStatus.fromMap(
      await _invokeMap('getOfflineModelStatus', <String, Object?>{
        'sessionId': sessionId,
      }),
    );
  }

  @override
  Future<void> downloadOfflineModels(String sessionId) {
    return _methodChannel.invokeMethod<void>(
      'downloadOfflineModels',
      <String, Object?>{'sessionId': sessionId},
    );
  }

  @override
  Future<void> cancelOfflineDownload(String sessionId) {
    return _methodChannel.invokeMethod<void>(
      'cancelOfflineDownload',
      <String, Object?>{'sessionId': sessionId},
    );
  }

  @override
  Future<void> startSession(String sessionId) {
    return _methodChannel.invokeMethod<void>(
      'startSession',
      <String, Object?>{'sessionId': sessionId},
    );
  }

  @override
  Future<void> stopSession(String sessionId) {
    return _methodChannel.invokeMethod<void>(
      'stopSession',
      <String, Object?>{'sessionId': sessionId},
    );
  }

  @override
  Future<void> disposeSession(String sessionId) {
    return _methodChannel.invokeMethod<void>(
      'disposeSession',
      <String, Object?>{'sessionId': sessionId},
    );
  }
}
