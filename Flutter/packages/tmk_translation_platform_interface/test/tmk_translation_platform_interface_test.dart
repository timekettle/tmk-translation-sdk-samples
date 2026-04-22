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

  test('parses session metrics and conversation events from maps', () {
    final metrics = TmkPluginEvent.fromMap(const {
      'kind': 'metrics',
      'sessionId': 'flutter-session',
      'roomNo': '12345',
      'scenario': 'oneToOne',
      'mode': 'online',
      'configuredSampleRate': 16000,
      'configuredChannels': 2,
      'captureSampleRate': 16000,
      'captureChannels': 2,
      'playbackChannels': 2,
    });
    expect(metrics, isA<TmkSessionMetricsEvent>());
    expect((metrics as TmkSessionMetricsEvent).roomNo, '12345');
    expect(metrics.playbackChannels, 2);

    final recognized = TmkPluginEvent.fromMap(const {
      'kind': 'recognized',
      'sessionId': 'flutter-session',
      'sdkSessionId': 'sdk-session-1',
      'sourceLangCode': 'zh-CN',
      'targetLangCode': 'en-US',
      'isFinal': false,
      'text': '你好',
      'extraData': {
        'bubble_id': 'bubble-1',
        'channel': 'right',
      },
    });
    expect(recognized, isA<TmkRecognizedEvent>());
    expect((recognized as TmkRecognizedEvent).sdkSessionId, 'sdk-session-1');
    expect(recognized.extraData['bubble_id'], 'bubble-1');

    final translated = TmkPluginEvent.fromMap(const {
      'kind': 'translated',
      'sessionId': 'flutter-session',
      'sdkSessionId': 'sdk-session-1',
      'sourceLangCode': 'zh-CN',
      'targetLangCode': 'en-US',
      'isFinal': true,
      'text': 'hello',
      'channel': 'right',
      'extraData': {
        'bubbleId': 'bubble-1',
      },
    });
    expect(translated, isA<TmkTranslatedEvent>());
    expect((translated as TmkTranslatedEvent).channel, 'right');
  });
}
