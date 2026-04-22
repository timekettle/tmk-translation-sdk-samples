import 'package:flutter/material.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart';

import '../theme.dart';
import 'home_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.initialSettings,
    required this.initialRuntimeStatus,
  });

  final TmkSettingsDraft initialSettings;
  final TmkRuntimeStatus? initialRuntimeStatus;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _networkOptions = ['dev', 'test', 'uat', 'pre', 'pre_jp', 'pre_us'];

  late TmkSettingsDraft _draft;
  TmkRuntimeStatus? _runtimeStatus;
  bool _isApplying = false;

  @override
  void initState() {
    super.initState();
    _draft = widget.initialSettings;
    _runtimeStatus = widget.initialRuntimeStatus;
  }

  Future<void> _apply() async {
    setState(() => _isApplying = true);
    try {
      final runtimeStatus = await TmkTranslationFlutter.applySettings(_draft);
      if (!mounted) {
        return;
      }
      setState(() => _runtimeStatus = runtimeStatus);
      Navigator.of(context).pop(
        SettingsResult(settings: _draft, runtimeStatus: runtimeStatus),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('设置应用失败：$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isApplying = false);
      }
    }
  }

  Future<void> _exportLogs() async {
    final path = await TmkTranslationFlutter.exportDiagnosisLogs();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          path == null || path.isEmpty ? '当前平台暂未提供可导出的诊断目录。' : '诊断目录：$path',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final runtimeStatus = _runtimeStatus;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          _SettingsSection(
            title: 'SDK 配置',
            children: [
              SwitchListTile(
                value: _draft.diagnosisEnabled,
                onChanged: (value) => setState(() {
                  _draft = _draft.copyWith(diagnosisEnabled: value);
                }),
                title: const Text('诊断模式'),
                subtitle: const Text('记录详细日志用于排查问题'),
              ),
              const Divider(height: 1, color: appBorder),
              SwitchListTile(
                value: _draft.consoleLogEnabled,
                onChanged: (value) => setState(() {
                  _draft = _draft.copyWith(consoleLogEnabled: value);
                }),
                title: const Text('控制台日志'),
                subtitle: const Text('在原生日志系统中输出调试日志'),
              ),
              const Divider(height: 1, color: appBorder),
              ListTile(
                title: const Text('网络环境'),
                subtitle: const Text('当前 SDK 请求环境'),
                trailing: DropdownButton<String>(
                  value: _draft.networkEnvironment,
                  dropdownColor: appSurface,
                  underline: const SizedBox.shrink(),
                  items: _networkOptions
                      .map(
                        (value) => DropdownMenuItem<String>(
                          value: value,
                          child: Text(value.toUpperCase()),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _draft = _draft.copyWith(networkEnvironment: value);
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SettingsSection(
            title: '引擎状态',
            children: [
              _StatusTile(
                title: '在线引擎',
                hint: 'LingCast + Agora RTC',
                summary: runtimeStatus?.onlineEngineStatus.summary ?? '暂无数据',
                detail: runtimeStatus?.onlineEngineStatus.detail ?? '尚未获取状态',
                accent: runtimeStatus?.onlineEngineStatus.kind == TmkEngineStatusKind.available
                    ? appAccent
                    : appDanger,
              ),
              _StatusTile(
                title: '离线引擎',
                hint: '离线模型与本地引擎',
                summary: runtimeStatus?.offlineEngineStatus.summary ?? '暂无数据',
                detail: runtimeStatus?.offlineEngineStatus.detail ?? '尚未获取状态',
                accent: runtimeStatus?.offlineEngineStatus.kind == TmkEngineStatusKind.available
                    ? appAccent
                    : appWarning,
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SettingsSection(
            title: '鉴权信息',
            children: [
              _StatusTile(
                title: 'Token 状态',
                hint: '当前鉴权结果',
                summary: runtimeStatus?.authInfo.tokenSummary ?? '暂无数据',
                detail: runtimeStatus?.authInfo.tokenDetail ?? '等待鉴权结果',
                accent: runtimeStatus?.authInfo.tokenSummary == '有效' ? appAccent : appDanger,
              ),
              _StatusTile(
                title: '自动刷新',
                hint: '自动续期能力展示占位',
                summary: runtimeStatus?.authInfo.autoRefreshSummary ?? '暂无数据',
                detail: runtimeStatus?.authInfo.autoRefreshDetail ?? '暂无数据',
                accent: appPrimarySoft,
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SettingsSection(
            title: '诊断',
            children: [
              ListTile(
                title: const Text('导出诊断日志'),
                subtitle: const Text('返回当前平台可用的诊断目录路径'),
                trailing: FilledButton.tonal(
                  onPressed: _exportLogs,
                  child: const Text('导出'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            runtimeStatus?.versionText ?? 'TmkTranslationSDK',
            textAlign: TextAlign.center,
            style: const TextStyle(color: appTextMuted),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 54,
            child: FilledButton(
              onPressed: _isApplying ? null : _apply,
              style: FilledButton.styleFrom(
                backgroundColor: appPrimary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              child: _isApplying
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('确认并重新应用'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: appTextMuted,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: appCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: appBorder),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.title,
    required this.hint,
    required this.summary,
    required this.detail,
    required this.accent,
  });

  final String title;
  final String hint;
  final String summary;
  final String detail;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Text(hint),
      trailing: SizedBox(
        width: 180,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(summary, style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              detail,
              textAlign: TextAlign.right,
              style: const TextStyle(color: appTextMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
