import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tmk_translation_demo/src/app.dart';
import 'package:tmk_translation_demo/src/screens/home_screen.dart';
import 'package:tmk_translation_demo/src/screens/settings_screen.dart';
import 'package:tmk_translation_demo/src/tmk_translation_adapter.dart';

void main() {
  testWidgets('app renders home shell', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 3000));
    await tester.pumpWidget(const TmkTranslationDemoApp());
    expect(find.text('翻译中台'), findsOneWidget);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  });

  testWidgets('home mode explanation fits a phone-width viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(350, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const TmkTranslationDemoApp());
    await tester.pump();

    expect(find.text('智能切换和双引擎竞速暂不支持，已保留入口样式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings keeps the original controls and network options', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: TmkSettingsDraft.defaults(),
          initialRuntimeStatus: null,
        ),
      ),
    );

    expect(find.text('诊断模式'), findsOneWidget);
    expect(find.text('控制台日志'), findsOneWidget);
    expect(find.text('网络环境'), findsOneWidget);
    expect(find.text('确认并重新应用'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
