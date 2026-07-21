import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tmk_translation_demo/src/app.dart';

void main() {
  testWidgets('app renders home shell', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 3000));
    await tester.pumpWidget(const TmkTranslationDemoApp());
    expect(find.text('翻译中台'), findsOneWidget);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  });
}
