import 'package:shared_preferences/shared_preferences.dart';

import 'tmk_translation_adapter.dart';

abstract interface class SampleSettingsStorage {
  Future<bool?> getBool(String key);

  Future<String?> getString(String key);

  Future<void> setBool(String key, bool value);

  Future<void> setString(String key, String value);
}

final class SharedPreferencesSettingsStorage implements SampleSettingsStorage {
  SharedPreferencesSettingsStorage({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<bool?> getBool(String key) => _preferences.getBool(key);

  @override
  Future<String?> getString(String key) => _preferences.getString(key);

  @override
  Future<void> setBool(String key, bool value) async {
    await _preferences.setBool(key, value);
  }

  @override
  Future<void> setString(String key, String value) async {
    await _preferences.setString(key, value);
  }
}

final class SampleSettingsStore {
  SampleSettingsStore({SampleSettingsStorage? storage}) : _storage = storage;

  static const _diagnosisEnabled = 'sample.diagnosis_enabled';
  static const _consoleLogEnabled = 'sample.console_log_enabled';
  static const _networkEnvironment = 'sample.network_environment';
  static const _mockEngineEnabled = 'sample.mock_engine_enabled';

  SampleSettingsStorage? _storage;

  SampleSettingsStorage get _resolvedStorage =>
      _storage ??= SharedPreferencesSettingsStorage();

  Future<TmkSettingsDraft> load() async {
    final defaults = TmkSettingsDraft.defaults();
    return TmkSettingsDraft(
      diagnosisEnabled:
          await _resolvedStorage.getBool(_diagnosisEnabled) ??
          defaults.diagnosisEnabled,
      consoleLogEnabled:
          await _resolvedStorage.getBool(_consoleLogEnabled) ??
          defaults.consoleLogEnabled,
      networkEnvironment:
          await _resolvedStorage.getString(_networkEnvironment) ??
          defaults.networkEnvironment,
      mockEngineEnabled:
          await _resolvedStorage.getBool(_mockEngineEnabled) ??
          defaults.mockEngineEnabled,
    );
  }

  Future<void> save(TmkSettingsDraft settings) async {
    await Future.wait<void>([
      _resolvedStorage.setBool(_diagnosisEnabled, settings.diagnosisEnabled),
      _resolvedStorage.setBool(_consoleLogEnabled, settings.consoleLogEnabled),
      _resolvedStorage.setString(
        _networkEnvironment,
        settings.networkEnvironment,
      ),
      _resolvedStorage.setBool(_mockEngineEnabled, settings.mockEngineEnabled),
    ]);
  }
}
