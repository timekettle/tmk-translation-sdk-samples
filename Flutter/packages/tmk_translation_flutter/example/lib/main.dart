import 'package:tmk_translation_flutter/tmk_translation_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _status = 'Ready';

  @override
  void initState() {
    super.initState();
    initPlugin();
  }

  Future<void> initPlugin() async {
    try {
      final settings = await TmkTranslationFlutter.getCurrentSettings();
      final runtimeStatus = await TmkTranslationFlutter.initialize(settings: settings);
      if (!mounted) return;
      setState(() {
        _status = runtimeStatus.versionText;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'Init failed: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Center(
          child: Text(_status),
        ),
      ),
    );
  }
}
