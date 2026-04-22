import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'theme.dart';

class TmkTranslationDemoApp extends StatelessWidget {
  const TmkTranslationDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TMK Translation Demo',
      debugShowCheckedModeBanner: false,
      theme: buildDemoTheme(),
      home: const HomeScreen(),
    );
  }
}
