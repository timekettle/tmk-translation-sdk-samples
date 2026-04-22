import 'package:flutter_test/flutter_test.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart';

void main() {
  test('exposes the plugin facade', () {
    expect(TmkTranslationFlutter.events, isA<Stream<TmkPluginEvent>>());
  });
}
