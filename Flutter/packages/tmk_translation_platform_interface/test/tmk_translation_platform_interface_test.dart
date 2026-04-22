import 'package:flutter_test/flutter_test.dart';
import 'package:tmk_translation_platform_interface/tmk_translation_platform_interface.dart';

void main() {
  test('parses settings from a map', () {
    const settings = TmkSettingsDraft(
      diagnosisEnabled: true,
      consoleLogEnabled: false,
      networkEnvironment: 'test',
      mockEngineEnabled: false,
    );

    expect(TmkSettingsDraft.fromMap(settings.toMap()), settings);
  });
}
