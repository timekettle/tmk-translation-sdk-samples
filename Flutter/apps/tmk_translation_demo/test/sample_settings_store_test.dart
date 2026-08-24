import 'package:flutter_test/flutter_test.dart';
import 'package:tmk_translation_demo/src/sample_settings_store.dart';
import 'package:tmk_translation_demo/src/tmk_translation_adapter.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart' as api;

void main() {
  test('uses the original Sample settings defaults', () async {
    final store = SampleSettingsStore(storage: _MemorySettingsStorage());

    final settings = await store.load();

    expect(settings.diagnosisEnabled, isFalse);
    expect(settings.consoleLogEnabled, isTrue);
    expect(settings.networkEnvironment, 'test');
    expect(settings.mockEngineEnabled, isFalse);
  });

  test('persists every legacy settings field', () async {
    final storage = _MemorySettingsStorage();
    final store = SampleSettingsStore(storage: storage);
    const expected = TmkSettingsDraft(
      diagnosisEnabled: true,
      consoleLogEnabled: false,
      networkEnvironment: 'pre_jp',
      mockEngineEnabled: true,
    );

    await store.save(expected);
    final actual = await store.load();

    expect(actual.diagnosisEnabled, expected.diagnosisEnabled);
    expect(actual.consoleLogEnabled, expected.consoleLogEnabled);
    expect(actual.networkEnvironment, expected.networkEnvironment);
    expect(actual.mockEngineEnabled, expected.mockEngineEnabled);
  });

  test('maps unsupported legacy environment to public unknown enum', () {
    final config = sampleGlobalConfig(
      const TmkSettingsDraft(
        diagnosisEnabled: false,
        consoleLogEnabled: true,
        networkEnvironment: 'uat',
        mockEngineEnabled: false,
      ),
      appId: 'app-id',
      appSecret: 'app-secret',
    );

    expect(
      config.networkEnvironment,
      api.TmkTranslationNetworkEnvironment.unknown,
    );
  });
}

final class _MemorySettingsStorage implements SampleSettingsStorage {
  final Map<String, Object> values = {};

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<String?> getString(String key) async => values[key] as String?;

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}
