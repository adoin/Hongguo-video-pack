import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/app_logs.dart';
import 'services/webdav_sync.dart';
import 'watch_history.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.history,
    required this.sync,
    required this.logs,
  });
  final WatchHistory history;
  final WebDavSync sync;
  final AppLogs logs;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final url = TextEditingController(text: widget.sync.config.url),
      username = TextEditingController(text: widget.sync.config.username),
      password = TextEditingController(text: widget.sync.config.password),
      limit = TextEditingController(text: '${widget.history.limit}');
  late bool enabled = widget.sync.config.enabled,
      automatic = widget.sync.config.automatic;
  bool saving = false;
  bool hidden = true;
  WebDavConfig get draft => WebDavConfig(
    url: url.text.trim(),
    username: username.text.trim(),
    password: password.text,
    enabled: enabled,
    automatic: automatic,
  );
  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      await widget.sync.save(draft);
      _notice('同步设置已保存');
    } on FormatException catch (e) {
      _notice(e.message);
    } catch (_) {
      _notice('设置保存失败，请检查系统凭据存储。');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    url.dispose();
    username.dispose();
    password.dispose();
    limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: ListenableBuilder(
      listenable: Listenable.merge([widget.sync, widget.history]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('观看记录', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  TextField(
                    controller: limit,
                    key: const ValueKey('history-limit'),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '在线记录条数',
                      helperText: '1–10000；合成文件记录另行保留。',
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () async {
                        final value = int.tryParse(limit.text.trim());
                        if (value == null || value < 1 || value > 10000) {
                          _notice('请输入 1 到 10000 的整数。');
                          return;
                        }
                        widget.history.setLimit(value);
                        await widget.history.flush();
                        _notice('记录条数已保存');
                      },
                      child: const Text('保存记录条数'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'WebDAV 同步',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Text(
                    '同步观看点位、已看过标记和记录条数设置。视频文件、日志和账号凭据不上传；其他设备的合成视频需关联本地文件。',
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用 WebDAV'),
                    value: enabled,
                    onChanged: widget.sync.busy || saving
                        ? null
                        : (v) => setState(() => enabled = v),
                  ),
                  TextField(
                    controller: url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'WebDAV 目录地址',
                      hintText: 'https://example.com/dav/',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: username,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: '用户名'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: password,
                    obscureText: hidden,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: '密码或应用密码',
                      suffixIcon: IconButton(
                        tooltip: hidden ? '显示密码' : '隐藏密码',
                        onPressed: () => setState(() => hidden = !hidden),
                        icon: Icon(
                          hidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动同步'),
                    subtitle: const Text('启动、返回应用和记录变更时同步。'),
                    value: automatic,
                    onChanged: widget.sync.busy || saving
                        ? null
                        : (v) => setState(() => automatic = v),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: widget.sync.busy || saving
                            ? null
                            : () async {
                                await widget.sync.test(draft);
                                _notice(widget.sync.error ?? '连接正常');
                              },
                        child: const Text('测试连接'),
                      ),
                      FilledButton(
                        onPressed: widget.sync.busy || saving ? null : _save,
                        child: Text(saving ? '保存中…' : '保存同步设置'),
                      ),
                      OutlinedButton(
                        onPressed:
                            widget.sync.busy ||
                                saving ||
                                !widget.sync.config.enabled
                            ? null
                            : widget.sync.sync,
                        child: const Text('立即同步'),
                      ),
                    ],
                  ),
                  if (widget.sync.busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(),
                    ),
                  if (widget.sync.lastSync != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        '上次同步：${widget.sync.lastSync!.toLocal().toString().substring(0, 19)}',
                      ),
                    ),
                  if (widget.sync.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        widget.sync.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 28),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.terminal),
                    title: const Text('开发者日志'),
                    subtitle: const Text('查看错误、警告或手动开启全量日志'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => DeveloperLogsScreen(logs: widget.logs),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class DeveloperLogsScreen extends StatefulWidget {
  const DeveloperLogsScreen({super.key, required this.logs});
  final AppLogs logs;
  @override
  State<DeveloperLogsScreen> createState() => _DeveloperLogsScreenState();
}

class _DeveloperLogsScreenState extends State<DeveloperLogsScreen> {
  String filter = 'issues';
  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('开发者日志'),
      actions: [
        IconButton(
          tooltip: '复制全部错误与警告',
          icon: const Icon(Icons.copy_all_outlined),
          onPressed: () => _copy(
            widget.logs.entries
                .where((e) => e.level.index >= LogLevel.warning.index)
                .map((e) => e.text)
                .join('\n\n'),
          ),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: widget.logs,
      builder: (context, _) {
        final entries = widget.logs.entries.reversed
            .where(
              (e) => switch (filter) {
                'error' => e.level == LogLevel.error,
                'warning' => e.level == LogLevel.warning,
                'all' => true,
                _ => e.level.index >= LogLevel.warning.index,
              },
            )
            .toList();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('全量日志'),
              subtitle: const Text('额外记录普通事件和调试信息，最多保留 1000 条。'),
              value: widget.logs.full,
              onChanged: widget.logs.setFull,
            ),
            DropdownButtonFormField<String>(
              initialValue: filter,
              decoration: const InputDecoration(labelText: '显示级别'),
              items: const [
                DropdownMenuItem(value: 'issues', child: Text('错误与警告')),
                DropdownMenuItem(value: 'error', child: Text('错误')),
                DropdownMenuItem(value: 'warning', child: Text('警告')),
                DropdownMenuItem(value: 'all', child: Text('全部')),
              ],
              onChanged: (v) => setState(() => filter = v!),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.logs.clear,
                child: const Text('清空日志'),
              ),
            ),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('暂无此级别日志')),
              ),
            for (final entry in entries)
              Card(
                elevation: 0,
                child: ExpansionTile(
                  leading: Icon(
                    entry.level == LogLevel.error
                        ? Icons.error_outline
                        : entry.level == LogLevel.warning
                        ? Icons.warning_amber
                        : Icons.info_outline,
                  ),
                  title: Text(
                    '${entry.source} · ${entry.message.split('\n').first}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${entry.level.name.toUpperCase()} · ${entry.time.toLocal().toString().substring(0, 19)}',
                  ),
                  trailing: IconButton(
                    tooltip: '复制此条日志',
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () => _copy(entry.text),
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(entry.text),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}
