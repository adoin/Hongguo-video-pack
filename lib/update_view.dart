import 'package:flutter/material.dart';
import 'services/app_updater.dart';

ButtonStyle get updateActionButtonStyle => FilledButton.styleFrom(
  minimumSize: const Size(0, 40),
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  textStyle: const TextStyle(
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w600,
  ),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  tapTargetSize: MaterialTapTargetSize.padded,
);

class UpdateScreen extends StatefulWidget {
  const UpdateScreen({
    super.key,
    required this.updater,
    required this.busy,
    required this.install,
    required this.openRelease,
  });
  final AppUpdater updater;
  final bool Function() busy;
  final Future<bool> Function() install;
  final Future<void> Function(Uri) openRelease;
  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  bool installing = false;
  String? message;
  @override
  void initState() {
    super.initState();
    if (!widget.updater.checking && !widget.updater.downloading) {
      widget.updater.check();
    }
  }

  Future<void> _install() async {
    if (widget.busy()) {
      setState(() => message = '请先完成或取消当前拼接任务，再安装更新。');
      return;
    }
    setState(() {
      installing = true;
      message = null;
    });
    try {
      final opened = await widget.install();
      if (mounted) {
        setState(
          () => message = opened
              ? '已打开系统安装向导，请按提示完成更新。'
              : '请允许本应用安装更新，然后返回再次点击“安装更新”。',
        );
      }
    } catch (_) {
      if (mounted) setState(() => message = '无法启动安装，请重试或打开对应发布页下载。');
    } finally {
      if (mounted) setState(() => installing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('检查更新')),
    body: ListenableBuilder(
      listenable: widget.updater,
      builder: (context, _) {
        final updater = widget.updater;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '当前版本：${updater.currentVersion.isEmpty ? '读取中…' : updater.currentVersion}',
            ),
            const SizedBox(height: 8),
            const Text('只更新正式版，忽略 beta、alpha、rc 等预发布版本。'),
            const SizedBox(height: 16),
            DropdownButtonFormField<UpdateSource>(
              key: ValueKey(updater.selectedSource),
              initialValue: updater.selectedSource,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '更新来源'),
              items: [
                for (final source in UpdateSource.values)
                  DropdownMenuItem(value: source, child: Text(source.label)),
              ],
              onChanged: updater.checking || updater.downloading || installing
                  ? null
                  : (value) {
                      if (value != null) updater.selectSource(value);
                    },
            ),
            const SizedBox(height: 12),
            Text('Gitee：${updater.sourceStatus(UpdateSource.gitee)}'),
            Text('GitHub：${updater.sourceStatus(UpdateSource.github)}'),
            const SizedBox(height: 20),
            Text(
              updater.status,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            if (updater.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  updater.error,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (updater.checking || updater.downloading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: LinearProgressIndicator(
                  value: updater.downloading ? updater.progress : null,
                ),
              ),
            if (updater.downloading && updater.progress != null)
              Text('${(updater.progress! * 100).toStringAsFixed(0)}%'),
            if (message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(message!),
              ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton(
                  style: updateActionButtonStyle,
                  onPressed:
                      updater.checking || updater.downloading || installing
                      ? null
                      : updater.check,
                  child: const Text('重新检查'),
                ),
                if (updater.hasUpdate &&
                    !updater.downloading &&
                    updater.readyFile == null)
                  FilledButton(
                    style: updateActionButtonStyle,
                    onPressed:
                        updater.checking || updater.release!.installer == null
                        ? null
                        : updater.download,
                    child: const Text('下载更新'),
                  ),
                if (updater.downloading)
                  TextButton(
                    style: updateActionButtonStyle,
                    onPressed: updater.cancel,
                    child: const Text('取消下载'),
                  ),
                if (updater.readyFile != null)
                  FilledButton(
                    style: updateActionButtonStyle,
                    onPressed: installing ? null : _install,
                    child: Text(installing ? '正在打开安装向导…' : '安装更新'),
                  ),
                if (updater.release != null)
                  TextButton(
                    style: updateActionButtonStyle,
                    onPressed: () => widget.openRelease(updater.release!.page),
                    child: Text('${updater.release!.source} 发布页'),
                  ),
              ],
            ),
            if (updater.hasUpdate && updater.release!.installer == null)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text('该正式版的平台安装包尚未就绪，请稍后重试或查看发布页。'),
              ),
            if (updater.hasUpdate) ...[
              const SizedBox(height: 24),
              Text(
                '正式版 ${updater.release!.version} 更新说明',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              SelectableText(
                updater.release!.notes.isEmpty
                    ? '此版本未提供更新说明。'
                    : updater.release!.notes,
              ),
            ],
          ],
        );
      },
    ),
  );
}
