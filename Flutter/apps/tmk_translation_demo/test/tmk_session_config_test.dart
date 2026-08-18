import 'package:flutter_test/flutter_test.dart';
import 'package:tmk_translation_demo/src/tmk_translation_adapter.dart';

void main() {
  test('one-to-one sample sessions default to the per-channel contract', () {
    final config = TmkSessionConfig(
      scenario: TmkScenario.oneToOne,
      mode: TmkTranslationMode.online,
      sourceLanguage: 'zh-CN',
      targetLanguage: 'en-US',
    );

    expect(config.oneToOneChannelMode, TmkOneToOneChannelMode.perChannel);
  });
}
