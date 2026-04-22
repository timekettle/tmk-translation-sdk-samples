import 'package:flutter/material.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart';

import '../theme.dart';
import 'session_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  TmkScenario _scenario = TmkScenario.listen;
  TmkTranslationMode _mode = TmkTranslationMode.online;
  List<TmkLanguageOption> _languages = const [];
  TmkLanguageOption? _sourceLanguage;
  TmkLanguageOption? _targetLanguage;
  TmkSettingsDraft _settings = TmkSettingsDraft.defaults();
  TmkRuntimeStatus? _runtimeStatus;
  String _footerText = '正在准备在线语言列表...';
  bool _isBootstrapping = true;
  bool _isLoadingLanguages = false;
  String? _bootstrapError;
  int _languageRequestId = 0;
  bool _hasLoadedLanguagesOnce = false;
  bool _shouldRetryOnlineLanguagesOnResume = false;
  bool _lastOnlineLanguagesLoadFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    if (!mounted) {
      return;
    }
    if (ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    if (_mode != TmkTranslationMode.online) {
      return;
    }
    if (_shouldRetryOnlineLanguagesOnResume == false || _isLoadingLanguages) {
      return;
    }
    if (_languages.isNotEmpty && _lastOnlineLanguagesLoadFailed == false) {
      return;
    }
    setState(() {
      _footerText = '检测到应用已恢复，正在重新获取在线语言列表...';
    });
    _loadLanguages();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _isBootstrapping = true;
      _bootstrapError = null;
    });
    try {
      final settings = await TmkTranslationFlutter.getCurrentSettings();
      final runtimeStatus = await TmkTranslationFlutter.initialize(settings: settings);
      if (!mounted) {
        return;
      }
      setState(() {
        _settings = settings;
        _runtimeStatus = runtimeStatus;
      });
      await _loadLanguages();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bootstrapError = error.toString();
        _footerText = 'SDK 初始化失败，请检查凭证或接入配置。';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBootstrapping = false;
        });
      }
    }
  }

  Future<void> _loadLanguages() async {
    final languageSource = _mode == TmkTranslationMode.offline
        ? TmkLanguageSource.offline
        : TmkLanguageSource.online;
    final requestId = ++_languageRequestId;
    _hasLoadedLanguagesOnce = true;
    setState(() {
      _isLoadingLanguages = true;
      _footerText = languageSource == TmkLanguageSource.online
          ? '正在准备在线语言列表...'
          : '正在准备离线语言列表...';
    });
    try {
      final languages = await TmkTranslationFlutter.getSupportedLanguages(languageSource);
      if (!mounted || requestId != _languageRequestId) {
        return;
      }
      if (languageSource == TmkLanguageSource.online) {
        _lastOnlineLanguagesLoadFailed = false;
        _shouldRetryOnlineLanguagesOnResume = false;
      }
      final source = _preferredLanguage(
        languages,
        exact: _sourceLanguage?.code ?? (languageSource == TmkLanguageSource.online ? 'zh-CN' : 'zh'),
        family: _sourceLanguage?.familyCode ?? 'zh',
      );
      final preferredTarget = _preferredLanguage(
        languages,
        exact: _targetLanguage?.code ?? (languageSource == TmkLanguageSource.online ? 'en-US' : 'en'),
        family: _targetLanguage?.familyCode ?? 'en',
      );
      setState(() {
        _languages = languages;
        _sourceLanguage = source;
        if (source != null && preferredTarget != null && preferredTarget.code != source.code) {
          _targetLanguage = preferredTarget;
        } else {
          _targetLanguage = _firstLanguageDifferentFrom(source);
        }
        _footerText = languageSource == TmkLanguageSource.online
            ? '在线语言列表已加载，自动使用 SDK 最新能力'
            : '离线语言列表已加载，可直接切换到本地翻译';
      });
    } catch (error) {
      if (!mounted || requestId != _languageRequestId) {
        return;
      }
      if (languageSource == TmkLanguageSource.online) {
        _lastOnlineLanguagesLoadFailed = true;
        _shouldRetryOnlineLanguagesOnResume = true;
      }
      setState(() {
        _languages = const [];
        _sourceLanguage = null;
        _targetLanguage = null;
        _footerText = languageSource == TmkLanguageSource.online
            ? '在线语言列表加载失败，请检查网络或权限；应用恢复后会自动重试'
            : '语言列表加载失败：$error';
      });
    } finally {
      if (mounted && requestId == _languageRequestId) {
        setState(() {
          _isLoadingLanguages = false;
        });
      }
    }
  }

  TmkLanguageOption? _preferredLanguage(
    List<TmkLanguageOption> languages, {
    required String exact,
    required String family,
  }) {
    for (final item in languages) {
      if (item.code.toLowerCase() == exact.toLowerCase()) {
        return item;
      }
    }
    for (final item in languages) {
      if (item.familyCode.toLowerCase() == family.toLowerCase()) {
        return item;
      }
    }
    return languages.isEmpty ? null : languages.first;
  }

  TmkLanguageOption? _firstLanguageDifferentFrom(TmkLanguageOption? option) {
    for (final item in _languages) {
      if (item.code != option?.code) {
        return item;
      }
    }
    return null;
  }

  void _normalizeTargetLanguage() {
    if (_sourceLanguage?.code != _targetLanguage?.code) {
      return;
    }
    _targetLanguage = _firstLanguageDifferentFrom(_sourceLanguage);
  }

  Future<void> _openSettings() async {
    final result = await Navigator.of(context).push<SettingsResult>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          initialSettings: _settings,
          initialRuntimeStatus: _runtimeStatus,
        ),
      ),
    );
    if (!mounted || result == null) {
      return;
    }
    setState(() {
      _settings = result.settings;
      _runtimeStatus = result.runtimeStatus;
    });
    await _loadLanguages();
  }

  void _onSelectMode(TmkTranslationMode mode) {
    if (mode == TmkTranslationMode.auto || mode == TmkTranslationMode.mix) {
      return;
    }
    setState(() {
      _mode = mode;
      if (mode != TmkTranslationMode.online) {
        _shouldRetryOnlineLanguagesOnResume = false;
        _lastOnlineLanguagesLoadFailed = false;
      }
    });
    _loadLanguages();
  }

  void _swapLanguages() {
    if (_sourceLanguage == null || _targetLanguage == null) {
      return;
    }
    setState(() {
      final current = _sourceLanguage;
      _sourceLanguage = _targetLanguage;
      _targetLanguage = current;
      _normalizeTargetLanguage();
    });
  }

  Future<void> _pickLanguage({required bool isSource}) async {
    if (_languages.isEmpty) {
      return;
    }
    final currentOption = isSource ? _sourceLanguage : _targetLanguage;
    final selected = await showModalBottomSheet<TmkLanguageOption>(
      context: context,
      backgroundColor: appSurface,
      builder: (context) {
        return SafeArea(
          child: ListView.separated(
            itemCount: _languages.length,
            separatorBuilder: (_, _) => const Divider(height: 1, color: appBorder),
            itemBuilder: (context, index) {
              final item = _languages[index];
              final isSelected = item.code == currentOption?.code;
              return ListTile(
                title: Text(item.title),
                subtitle: Text(item.code, style: const TextStyle(color: appTextMuted)),
                trailing: isSelected
                    ? const Icon(Icons.check_circle_rounded, color: appAccent)
                    : null,
                onTap: () => Navigator.of(context).pop(item),
              );
            },
          ),
        );
      },
    );
    if (!mounted || selected == null) {
      return;
    }
    if (isSource && _targetLanguage?.code == selected.code) {
      return;
    }
    if (!isSource && _sourceLanguage?.code == selected.code) {
      return;
    }
    setState(() {
      if (isSource) {
        _sourceLanguage = selected;
      } else {
        _targetLanguage = selected;
      }
      _normalizeTargetLanguage();
    });
  }

  bool get _canStart =>
      !_isBootstrapping &&
      !_isLoadingLanguages &&
      _sourceLanguage != null &&
      _targetLanguage != null &&
      _sourceLanguage!.code != _targetLanguage!.code &&
      (_mode == TmkTranslationMode.online || _mode == TmkTranslationMode.offline);

  Future<void> _openSession() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SessionScreen(
          title: _scenario == TmkScenario.listen
              ? (_mode == TmkTranslationMode.online ? '在线收听' : '离线收听')
              : (_mode == TmkTranslationMode.online ? '在线 1v1' : '离线 1v1'),
          config: TmkSessionConfig(
            scenario: _scenario,
            mode: _mode,
            sourceLanguage: _sourceLanguage!.code,
            targetLanguage: _targetLanguage!.code,
          ),
        ),
      ),
    );
    if (!mounted || _hasLoadedLanguagesOnce == false) {
      return;
    }
    await _loadLanguages();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0F1117), Color(0xFF0D131D), Color(0xFF0F1117)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          FilledButton.tonal(
                            onPressed: _openSettings,
                            style: FilledButton.styleFrom(
                              backgroundColor: appCard,
                              foregroundColor: appPrimarySoft,
                            ),
                            child: const Text('设置'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '翻译中台',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '先选场景，再选模式',
                        style: TextStyle(color: appTextMuted),
                      ),
                      const SizedBox(height: 28),
                      const _SectionLabel('① 使用场景'),
                      const SizedBox(height: 12),
                      _ScenarioCard(
                        title: '收听模式',
                        subtitle: '收听外语内容，实时翻译',
                        icon: Icons.hearing_rounded,
                        selected: _scenario == TmkScenario.listen,
                        onTap: () => setState(() => _scenario = TmkScenario.listen),
                      ),
                      const SizedBox(height: 10),
                      _ScenarioCard(
                        title: '一对一对话',
                        subtitle: '双人面对面，双声道分离',
                        icon: Icons.forum_rounded,
                        selected: _scenario == TmkScenario.oneToOne,
                        onTap: () => setState(() => _scenario = TmkScenario.oneToOne),
                      ),
                      const SizedBox(height: 28),
                      Row(
                        children: const [
                          _SectionLabel('② 翻译模式'),
                          SizedBox(width: 8),
                          Text(
                            '智能切换和双引擎竞速暂不支持，已保留入口样式',
                            style: TextStyle(color: appPrimarySoft, fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _ModeCard(
                            title: '在线翻译',
                            subtitle: '云端引擎，语言覆盖更全',
                            badge: 'ONLINE',
                            color: appAccent,
                            selected: _mode == TmkTranslationMode.online,
                            enabled: true,
                            onTap: () => _onSelectMode(TmkTranslationMode.online),
                          ),
                          _ModeCard(
                            title: '离线翻译',
                            subtitle: '本地引擎，无需网络',
                            badge: 'OFFLINE',
                            color: appOffline,
                            selected: _mode == TmkTranslationMode.offline,
                            enabled: true,
                            onTap: () => _onSelectMode(TmkTranslationMode.offline),
                          ),
                          const _ModeCard(
                            title: '智能切换',
                            subtitle: '暂不支持',
                            badge: 'AUTO',
                            color: appPrimary,
                            selected: false,
                            enabled: false,
                          ),
                          const _ModeCard(
                            title: '双引擎竞速',
                            subtitle: '暂不支持',
                            badge: 'MIX',
                            color: appPrimary,
                            selected: false,
                            enabled: false,
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      const _SectionLabel('③ 语言设置'),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _LanguageCard(
                              label: '源语言',
                              option: _sourceLanguage,
                              onTap: () => _pickLanguage(isSource: true),
                            ),
                          ),
                          const SizedBox(width: 12),
                          _SwapLanguageButton(onTap: _swapLanguages),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _LanguageCard(
                              label: '目标语言',
                              option: _targetLanguage,
                              onTap: () => _pickLanguage(isSource: false),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _footerText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: appTextMuted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      if (_bootstrapError != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _bootstrapError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: appDanger, height: 1.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton(
                    onPressed: _canStart ? _openSession : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: appPrimary,
                      disabledBackgroundColor: appBorder,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    child: _isBootstrapping
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('开始翻译'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: appTextMuted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _ScenarioCard extends StatelessWidget {
  const _ScenarioCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: selected ? appAccent.withValues(alpha: 0.12) : appCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? appAccent : appBorder, width: 1.5),
        ),
        child: Row(
          children: [
            Icon(icon, size: 28, color: appText),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(color: appTextMuted)),
                ],
              ),
            ),
            Icon(
              selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
              color: selected ? appAccent : appTextMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.color,
    required this.selected,
    required this.enabled,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String badge;
  final Color color;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: (MediaQuery.of(context).size.width - 52) / 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: enabled ? appCard : appCard.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: selected ? color : appBorder, width: selected ? 1.5 : 1),
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 14),
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(subtitle, style: const TextStyle(color: appTextMuted, height: 1.4)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LanguageCard extends StatelessWidget {
  const _LanguageCard({
    required this.label,
    required this.option,
    required this.onTap,
  });

  final String label;
  final TmkLanguageOption? option;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        height: 92,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: appCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: appBorder, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: appTextMuted,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    option?.title ?? '请选择',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                  ),
                ),
              ),
            ),
            if ((option?.code ?? '').isNotEmpty)
              Text(
                option!.code,
                style: const TextStyle(
                  color: appText,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }
}

class _SwapLanguageButton extends StatelessWidget {
  const _SwapLanguageButton({
    required this.onTap,
  });

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: appPrimary,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: const Text(
          '⇄',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class SettingsResult {
  const SettingsResult({
    required this.settings,
    required this.runtimeStatus,
  });

  final TmkSettingsDraft settings;
  final TmkRuntimeStatus runtimeStatus;
}
