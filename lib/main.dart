import 'dart:io';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:media_kit/media_kit.dart';
import 'app_controller.dart';
import 'services/smoke_check.dart';
import 'data/request_signer.dart';
import 'discovery_controller.dart';
import 'discovery_view.dart';
import 'domain/discovery.dart';
import 'domain/drama.dart';
import 'playback_view.dart';
import 'services/app_storage.dart';
import 'services/playback_acceptance.dart';
import 'watch_history.dart';
import 'watch_history_view.dart';
import 'services/history_acceptance.dart';
import 'services/app_updater.dart';
import 'update_view.dart';
import 'services/update_acceptance.dart';

const accent = Color(0xFFC20032);
const ink = Color(0xFF24242D);
const muted = Color(0xFF858590);
const canvas = Color(0xFFF6F6F8);
const demoUrl = 'https://hongguoduanju.com/player/7671966197985856536';
bool get desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (desktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1320, 900),
        minimumSize: Size(400, 640),
        center: true,
        backgroundColor: canvas,
        titleBarStyle: TitleBarStyle.hidden,
        title: '红葡萄',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  if (arguments.contains('--smoke') ||
      arguments.contains('--acceptance') ||
      arguments.contains('--search-acceptance') ||
      arguments.contains('--playback-acceptance') ||
      arguments.contains('--history-acceptance') ||
      arguments.contains('--update-acceptance')) {
    runApp(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('正在验证本地视频引擎…'))),
      ),
    );
    try {
      if (arguments.contains('--update-acceptance')) {
        await runUpdateAcceptance();
      } else if (arguments.contains('--history-acceptance')) {
        await runHistoryAcceptance();
      } else if (arguments.contains('--playback-acceptance')) {
        await runPlaybackAcceptance();
      } else if (arguments.contains('--search-acceptance')) {
        await runSearchAcceptance();
      } else if (arguments.contains('--acceptance')) {
        await runRemoteAcceptance();
      } else {
        await runNativeSmokeCheck();
      }
      exit(0);
    } catch (_) {
      exit(1);
    }
  }
  runApp(const StudioApp());
}

class StudioApp extends StatelessWidget {
  const StudioApp({
    super.key,
    this.controller,
    this.discoveryController,
    this.updater,
  });
  final StudioController? controller;
  final DiscoveryController? discoveryController;
  final AppUpdater? updater;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '红葡萄',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        surface: Colors.white,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: ink, height: 1.5),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: canvas,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 19),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: muted),
      ),
    ),
    home: StudioHome(
      controller: controller,
      discoveryController: discoveryController,
      updater: updater,
    ),
  );
}

class StudioHome extends StatefulWidget {
  const StudioHome({
    super.key,
    this.controller,
    this.discoveryController,
    this.updater,
  });
  final StudioController? controller;
  final DiscoveryController? discoveryController;
  final AppUpdater? updater;
  @override
  State<StudioHome> createState() => _StudioHomeState();
}

class _StudioHomeState extends State<StudioHome> with WidgetsBindingObserver {
  late final StudioController c = widget.controller ?? StudioController();
  late final updater = widget.updater ?? AppUpdater();

  Future<void> _checkUpdates({bool automatic = false}) async {
    await updater.check();
    if (!mounted) return;
    if (automatic && updater.allSourcesFailed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('GitHub 和 Gitee 均检查失败，暂时无法获取更新。'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(label: '手动检查', onPressed: _showUpdates),
        ),
      );
      return;
    }
    if (!automatic) {
      _showUpdates();
      return;
    }
    if (!updater.hasUpdate ||
        c.busy ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现正式版 ${updater.release!.version}'),
        content: Text('当前版本 ${updater.currentVersion}，是否查看并下载更新？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('查看更新'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) _showUpdates();
  }

  void _showUpdates() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UpdateScreen(
          updater: updater,
          busy: () => c.busy || c.loading,
          openRelease: _open,
          install: () async {
            if (c.busy || c.loading) throw StateError('task busy');
            final file = await updater.verifyForInstall();
            if (c.busy || c.loading) throw StateError('task busy');
            await c.flush();
            if (Platform.isWindows) {
              await Process.start(file.path, [
                '/NORESTART',
              ], mode: ProcessStartMode.detached);
              await windowManager.close();
              return true;
            }
            if (Platform.isAndroid) {
              return await NativeRequestSigner.channel.invokeMethod<bool>(
                    'installUpdate',
                    {'path': file.path},
                  ) ??
                  false;
            }
            throw UnsupportedError('unsupported platform');
          },
        ),
      ),
    );
  }

  final link = TextEditingController(text: demoUrl);
  bool _saving = false;
  late final discovery = widget.discoveryController ?? DiscoveryController();
  late int page = widget.controller == null ? 0 : 1;
  final scroll = ScrollController();

  void _navigate(int value) {
    setState(() => page = value);
    if (scroll.hasClients) scroll.jumpTo(0);
    if (value == 0 && discovery.result == null && !discovery.loading) {
      discovery.refresh();
    }
  }

  void _pickDrama(DramaSummary drama) {
    if (c.busy || c.loading) return;
    link.text = 'https://hongguoduanju.com/player/${drama.id}';
    _navigate(1);
    c.load(link.text);
  }

  void _playDrama(DramaSummary drama, {WatchPoint? resume}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaybackScreen(
          summary: drama,
          resume: resume,
          tasks: c,
          onStitch: _startPlaybackStitch,
          onTasks: _showPlaybackTasks,
          onCloseWindow: _closeWindow,
        ),
      ),
    );
  }

  void _resume(WatchPoint point) {
    _playDrama(
      DramaSummary(id: point.dramaId, title: point.title, cover: point.cover),
      resume: point,
    );
  }

  void _showWatchHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            WatchHistoryScreen(history: c.watchHistory, onResume: _resume),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(c.watchHistory.pruneMissing());
    }
    if (state == AppLifecycleState.paused) unawaited(c.watchHistory.flush());
  }

  Future<bool> _startPlaybackStitch(
    Drama drama,
    Set<int> selected,
    int quality,
  ) async {
    if (c.busy || c.loading || selected.isEmpty) return false;
    if (c.outputDirectory.isEmpty) await _prepare();
    await c.load(drama.id);
    if (c.drama?.id != drama.id ||
        c.variants.isEmpty ||
        c.outputDirectory.isEmpty) {
      return false;
    }
    c.selectEpisodes(selected);
    c.setQuality(quality);
    link.text = c.lastInput;
    unawaited(c.assemble());
    return c.busy;
  }

  void _showPlaybackTasks() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .8,
          child: AnimatedBuilder(
            animation: c,
            builder: (_, _) => SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Text(
                    '拼接任务管理',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 16),
                  _activityCard(),
                  const SizedBox(height: 20),
                  _historyCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _closeWindow() async {
    if (c.busy) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('结束当前任务并退出？'),
          content: const Text('当前导出尚未完成。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续处理'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('结束并退出'),
            ),
          ],
        ),
      );
      if (leave != true) return;
      await c.cancel();
    }
    await c.flush();
    await windowManager.close();
  }

  void _related() {
    final drama = c.drama;
    if (drama == null) return;
    setState(() => page = 0);
    if (scroll.hasClients) scroll.jumpTo(0);
    discovery.show(
      DiscoveryMode.related,
      keyword: seriesKeyword(drama.title),
      excludeId: drama.id,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller == null) {
      _prepare();
      discovery.refresh();
      unawaited(_checkUpdates(automatic: true));
    } else if (widget.updater != null) {
      unawaited(_checkUpdates(automatic: true));
    }
  }

  Future<void> _prepare() async {
    try {
      final support = await appSupportDirectory();
      discovery.client.indexCache = File(
        p.join(support.path, 'catalogue-v1.json'),
      );
      try {
        await discovery.client.loadSearchIdentity(
          File(p.join(support.path, 'search-visitor.json')),
        );
      } catch (_) {
        c.log('本机搜索初始化信息无法读取，当前使用网页搜索。');
      }
      final docs = Platform.isAndroid
          ? support
          : await getApplicationDocumentsDirectory();
      if (!mounted) return;
      await c.initialize(
        File(p.join(support.path, 'workspace.json')),
        Platform.isAndroid
            ? p.join(docs.path, 'exports')
            : p.join(docs.path, 'Hongguo Studio', 'exports'),
      );
      if (!mounted) return;
      link.text = c.lastInput;
    } catch (_) {
      if (mounted) c.log('无法准备导出目录，请选择可写目录。');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.updater == null) updater.dispose();
    link.dispose();
    scroll.dispose();
    if (widget.discoveryController == null) discovery.dispose();
    if (widget.controller == null) c.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      final paths = result.files
          .map((f) => f.path)
          .whereType<String>()
          .toList();
      if (paths.length != result.files.length) throw StateError('部分素材无法读取');
      if (mounted) c.addFiles(paths);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能导入素材，请检查空间后重新选择文件。')));
      }
    }
  }

  Future<void> _pickDirectory() async {
    if (Platform.isAndroid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('安卓导出先保存在应用内；完成后点击“保存到手机”选择系统目录。')),
      );
      return;
    }
    final directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择导出目录',
    );
    if (directory != null && mounted) c.setDirectory(directory);
  }

  Future<void> _open(Uri uri) async {
    try {
      if (uri.scheme == 'file') {
        final path = uri.toFilePath();
        if (!await File(path).exists()) {
          await c.watchHistory.pruneMissing();
          throw StateError('文件已不存在');
        }
        final point =
            c.watchHistory.fileFor(path) ??
            WatchPoint(
              title:
                  c.history
                          .where((e) => e['path'] == path)
                          .firstOrNull?['title']
                      as String? ??
                  p.basenameWithoutExtension(path),
              path: path,
            );
        if (mounted) _resume(point);
        return;
      }
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('没有可打开此链接的应用');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开，请复制链接或路径后手动打开')));
      }
    }
  }

  Future<void> _saveToPhone(String path) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = await NativeRequestSigner.channel.invokeMethod<bool>(
        'saveFile',
        {'path': path},
      );
      if (mounted && saved == true) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('视频已保存到所选目录')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存未完成，请检查目标目录剩余空间后重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rangeDialog() async {
    final first = TextEditingController(text: '1');
    final last = TextEditingController(text: '${c.drama!.episodes.length}');
    final key = GlobalKey<FormState>();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('按范围选择'),
        content: Form(
          key: key,
          child: Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: first,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '起始集'),
                  validator: (v) =>
                      (int.tryParse(v ?? '') ?? 0) < 1 ? '至少 1' : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: last,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '结束集'),
                  validator: (v) {
                    final a = int.tryParse(first.text) ?? 0,
                        b = int.tryParse(v ?? '') ?? 0;
                    return b < a || b > c.drama!.episodes.length
                        ? '范围无效'
                        : null;
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (key.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('选择'),
          ),
        ],
      ),
    );
    if (result == true) {
      c.selectRange(int.parse(first.text), int.parse(last.text));
    }
    // Text fields can still be referenced during the dialog's closing transition.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    first.dispose();
    last.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c, updater]),
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 1050;
      return PopScope(
        canPop: !c.busy,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && c.busy) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('任务正在进行，可切到后台；请先取消任务再退出。')),
            );
          }
        },
        child: Scaffold(
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: page,
                  onDestinationSelected: _navigate,
                  backgroundColor: Colors.white,
                  indicatorColor: accent.withValues(alpha: .12),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.explore_outlined),
                      selectedIcon: Icon(Icons.explore),
                      label: '发现',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.dashboard_outlined),
                      selectedIcon: Icon(Icons.dashboard),
                      label: '工作台',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.downloading_outlined),
                      selectedIcon: Icon(Icons.downloading),
                      label: '任务',
                    ),
                  ],
                ),
          body: SafeArea(
            child: Column(
              children: [
                if (desktop)
                  SizedBox(
                    height: 42,
                    child: Row(
                      children: [
                        Expanded(
                          child: DragToMoveArea(
                            child: Container(
                              color: canvas,
                              padding: const EdgeInsets.only(left: 24),
                              alignment: Alignment.centerLeft,
                            ),
                          ),
                        ),
                        WindowCaptionButton.minimize(
                          onPressed: () => windowManager.minimize(),
                          brightness: Brightness.light,
                        ),
                        WindowCaptionButton.maximize(
                          onPressed: () async {
                            await windowManager.isMaximized()
                                ? await windowManager.unmaximize()
                                : await windowManager.maximize();
                          },
                          brightness: Brightness.light,
                        ),
                        WindowCaptionButton.close(
                          onPressed: () async {
                            if (c.busy) {
                              final leave = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('结束当前任务并退出？'),
                                  content: const Text('当前导出尚未完成。'),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('继续处理'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('结束并退出'),
                                    ),
                                  ],
                                ),
                              );
                              if (leave != true) return;
                              await c.cancel();
                            }
                            await c.flush();
                            await windowManager.close();
                          },
                          brightness: Brightness.light,
                        ),
                      ],
                    ),
                  ),
                if (!wide)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      children: [
                        const Text(
                          '红葡萄',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _showAbout,
                          child: Text(_versionLabel),
                        ),
                        IconButton(
                          onPressed: _showUpdates,
                          tooltip: '检查更新',
                          icon: const Icon(Icons.system_update_alt, size: 20),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (wide) _sidebar(),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: scroll,
                          padding: EdgeInsets.all(wide ? 32 : 18),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1400),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (page == 0) ...[
                                    RecentHistory(
                                      history: c.watchHistory,
                                      onResume: _resume,
                                      onAll: _showWatchHistory,
                                    ),
                                    DiscoveryView(
                                      controller: discovery,
                                      onPick: _pickDrama,
                                      onPlay: _playDrama,
                                      selectionDisabled: c.busy || c.loading,
                                    ),
                                  ] else if (page == 2) ...[
                                    TextButton.icon(
                                      onPressed: _showWatchHistory,
                                      icon: const Icon(Icons.history),
                                      label: const Text('观看记录'),
                                    ),
                                    const Text(
                                      '任务与导出',
                                      style: TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    _activityCard(),
                                    const SizedBox(height: 24),
                                    _historyCard(),
                                  ] else ...[
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton.icon(
                                        onPressed: _showWatchHistory,
                                        icon: const Icon(Icons.history),
                                        label: const Text('观看记录'),
                                      ),
                                    ),
                                    _heading(wide),
                                    const SizedBox(height: 28),
                                    _linkCard(),
                                    if (c.drama != null) ...[
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        children: [
                                          TextButton.icon(
                                            onPressed: _related,
                                            icon: const Icon(
                                              Icons.link_rounded,
                                              size: 18,
                                            ),
                                            label: const Text('查看关联作品 / 其他季'),
                                          ),
                                          TextButton.icon(
                                            onPressed: () => _navigate(0),
                                            icon: const Icon(
                                              Icons.explore_outlined,
                                              size: 18,
                                            ),
                                            label: const Text('继续发现'),
                                          ),
                                        ],
                                      ),
                                    ],
                                    const SizedBox(height: 24),
                                    if (wide)
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              children: [
                                                _dramaCard(),
                                                const SizedBox(height: 24),
                                                _localCard(),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 24),
                                          SizedBox(
                                            width: 320,
                                            child: Column(
                                              children: [
                                                _exportCard(),
                                                const SizedBox(height: 24),
                                                _activityCard(),
                                              ],
                                            ),
                                          ),
                                        ],
                                      )
                                    else ...[
                                      _dramaCard(),
                                      const SizedBox(height: 20),
                                      _exportCard(),
                                      const SizedBox(height: 20),
                                      _localCard(),
                                      const SizedBox(height: 20),
                                      _activityCard(),
                                    ],
                                    if (c.history.isNotEmpty) ...[
                                      const SizedBox(height: 24),
                                      _historyCard(),
                                    ],
                                  ],
                                  const SizedBox(height: 20),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  String get _versionLabel =>
      updater.currentVersion.isEmpty ? '本地版本' : 'v${updater.currentVersion}';

  void _showAbout() => showAboutDialog(
    context: context,
    applicationName: '红葡萄',
    applicationVersion: updater.currentVersion.isEmpty
        ? '本地版本'
        : updater.currentVersion,
    applicationLegalese:
        '请仅处理你有权使用的视频内容，未经授权不得下载、传播或商业利用视频内容。\n软件源码依 GPL-3.0 发布；该许可不授予视频内容的使用或传播权。\n\n访客来源 · 本地制作\n包含 GPL-3.0 协议适配与 FFmpeg 组件。源码与第三方声明随交付包提供。',
    children: [
      TextButton(
        onPressed: () {
          Navigator.of(context).pop();
          _showUpdates();
        },
        child: const Text('检查更新'),
      ),
      TextButton(
        onPressed: () async {
          final notices = await rootBundle.loadString('THIRD_PARTY_NOTICES.md');
          if (!mounted) return;
          showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('第三方声明'),
              content: SingleChildScrollView(child: SelectableText(notices)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭'),
                ),
              ],
            ),
          );
        },
        child: const Text('第三方声明'),
      ),
    ],
  );

  Widget _sidebar() => Container(
    width: 88,
    margin: const EdgeInsets.fromLTRB(12, 12, 0, 12),
    decoration: BoxDecoration(
      color: ink,
      borderRadius: BorderRadius.circular(26),
    ),
    child: Column(
      children: [
        const SizedBox(height: 24),
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(15),
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset('assets/branding/logo.png', fit: BoxFit.cover),
        ),
        const SizedBox(height: 45),
        for (final entry in [
          (0, Icons.explore_outlined, '发现'),
          (1, Icons.dashboard_outlined, '工作台'),
          (2, Icons.downloading_outlined, '任务'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: InkWell(
              onTap: () => _navigate(entry.$1),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: 62,
                height: 68,
                decoration: BoxDecoration(
                  color: page == entry.$1
                      ? Colors.white.withValues(alpha: .14)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      entry.$2,
                      color: page == entry.$1
                          ? Colors.white
                          : const Color(0xFF92929D),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      entry.$3,
                      style: TextStyle(
                        fontSize: 11,
                        color: page == entry.$1
                            ? Colors.white
                            : const Color(0xFF92929D),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const Spacer(),
        IconButton(
          onPressed: _showUpdates,
          tooltip: '检查更新',
          icon: const Icon(
            Icons.system_update_alt,
            color: Color(0xFFCACAD2),
            size: 20,
          ),
        ),
        TextButton(
          onPressed: _showAbout,
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFFCACAD2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
          ),
          child: Text(_versionLabel, style: const TextStyle(fontSize: 11)),
        ),
        const SizedBox(height: 16),
      ],
    ),
  );

  Widget _heading(bool wide) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'YOUR CREATIVE WORKSPACE',
              style: TextStyle(
                fontSize: 10,
                color: accent,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '让故事，一气呵成。',
              style: TextStyle(
                fontSize: wide ? 30 : 25,
                fontWeight: FontWeight.w800,
                color: ink,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '从一部短剧，到一个完整合集。',
              style: TextStyle(color: muted, fontSize: 13),
            ),
          ],
        ),
      ),
      if (wide) const Tag('访客模式 · 本地制作', icon: Icons.link_rounded),
    ],
  );

  Widget _linkCard() => Surface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle(
          '导入剧集',
          subtitle: '粘贴红果链接，读取分集与可用画质',
          icon: Icons.add_link_rounded,
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, constraints) {
            final field = TextField(
              controller: link,
              enabled: !c.loading && !c.busy,
              decoration: const InputDecoration(
                hintText: '红果播放链接 / 剧集 ID',
                prefixIcon: Icon(Icons.link, size: 20),
              ),
              onSubmitted: (_) => c.load(link.text),
            );
            final button = FilledButton.icon(
              onPressed: c.loading || c.busy ? null : () => c.load(link.text),
              icon: c.loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text(c.loading ? '正在读取' : '读取剧集'),
            );
            return constraints.maxWidth > 600
                ? Row(
                    children: [
                      Expanded(child: field),
                      const SizedBox(width: 12),
                      button,
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [field, const SizedBox(height: 12), button],
                  );
          },
        ),
      ],
    ),
  );

  Widget _dramaCard() => Surface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (c.drama == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 38),
            child: Center(
              child: Column(
                children: [
                  Icon(
                    Icons.video_library_outlined,
                    size: 46,
                    color: accent.withValues(alpha: .5),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '你的下一部合集，从这里开始',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '已填入《持械入宋：第一季》示例链接',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          )
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 90,
                  height: 126,
                  child: Image.network(
                    c.drama!.cover,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: canvas,
                      child: const Icon(Icons.movie_outlined, color: muted),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.drama!.title,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Tag('${c.drama!.episodes.length} 集'),
                        const Tag('红果短剧'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      c.drama!.intro,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _open(
                Uri.parse('https://hongguoduanju.com/player/${c.drama!.id}'),
              ),
              icon: const Icon(Icons.open_in_new, size: 15),
              label: const Text('原站预览'),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '选择分集',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '已选 ${c.selected.length}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              TextButton(
                onPressed: c.busy || c.loading ? null : _rangeDialog,
                child: const Text('范围'),
              ),
              TextButton(
                onPressed: c.busy || c.loading
                    ? null
                    : () => c.selectAll(
                        c.selected.length != c.drama!.episodes.length,
                      ),
                child: Text(
                  c.selected.length == c.drama!.episodes.length ? '清空' : '全选',
                ),
              ),
            ],
          ),
          const Text(
            '默认选择前两集，先完成一次小规模验证。',
            style: TextStyle(color: muted, fontSize: 11),
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 330),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final episode in c.drama!.episodes)
                    Semantics(
                      label: '第 ${episode.number} 集',
                      selected: c.selected.contains(episode.number),
                      button: true,
                      child: SizedBox(
                        width: 48,
                        height: 44,
                        child: Material(
                          color: c.selected.contains(episode.number)
                              ? accent
                              : canvas,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            onTap: c.busy || c.loading
                                ? null
                                : () => c.toggle(episode.number),
                            borderRadius: BorderRadius.circular(12),
                            child: Center(
                              child: Text(
                                '${episode.number}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: c.selected.contains(episode.number)
                                      ? Colors.white
                                      : ink,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _exportCard() => Surface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle(
          '制作合集',
          subtitle: '优先无损，规格不同时自动兼容',
          icon: Icons.auto_awesome_outlined,
        ),
        const SizedBox(height: 24),
        const Text(
          '清晰度',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<int>(
          key: ValueKey(
            '${c.quality}-${c.variants.map((v) => v.quality).join(',')}',
          ),
          initialValue: c.quality,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          items: [
            const DropdownMenuItem(
              value: 0,
              child: Text('最高可用', style: TextStyle(fontSize: 13)),
            ),
            for (final quality in c.variants.map((v) => v.quality).toSet())
              DropdownMenuItem(
                value: quality,
                child: Text(
                  '${quality}P',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
          onChanged: c.busy || c.loading
              ? null
              : (value) => c.setQuality(value ?? 0),
        ),
        const SizedBox(height: 8),
        Text(
          c.variants.isEmpty
              ? '清晰度以接口实际返回为准'
              : c.variants.map((v) => v.label).join(' / '),
          style: const TextStyle(fontSize: 11, color: muted),
        ),
        if (c.drama != null)
          TextButton.icon(
            onPressed: c.busy || c.loading ? null : c.retryQuality,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重新检测画质'),
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(
              child: Text(
                '导出到',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              onPressed: c.busy ? null : _pickDirectory,
              tooltip: '选择导出目录',
              icon: const Icon(Icons.folder_open_outlined, size: 20),
            ),
            IconButton(
              tooltip: '清理分集缓存',
              onPressed: c.busy || c.loading
                  ? null
                  : () async {
                      final clear = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('清理已下载分集缓存？'),
                          content: const Text(
                            '导出的 MP4 文件会保留。清理后，重试任务需要重新下载分集。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('清理缓存'),
                            ),
                          ],
                        ),
                      );
                      if (clear == true) await c.clearCache();
                    },
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
            ),
          ],
        ),
        SelectableText(
          c.outputDirectory.isEmpty
              ? '正在准备本地目录…'
              : Platform.isAndroid
              ? '应用内存储 · 导出后可另存到手机'
              : c.outputDirectory,
          style: const TextStyle(fontSize: 11, color: muted),
        ),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动兼容素材', style: TextStyle(fontSize: 12)),
          subtitle: const Text(
            '优先只修复差异集数；转码最多 2 线程',
            style: TextStyle(fontSize: 10, color: muted),
          ),
          value: c.normalize,
          onChanged: c.busy ? null : c.setNormalize,
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed:
                c.busy ||
                    c.loading ||
                    c.drama == null ||
                    c.selected.isEmpty ||
                    c.variants.isEmpty ||
                    c.variants.every((v) => !v.downloadable) ||
                    c.outputDirectory.isEmpty
                ? null
                : () => c.assemble(),
            icon: const Icon(Icons.movie_filter_outlined, size: 19),
            label: Text(
              '下载并拼接${c.selected.isEmpty ? '' : ' · ${c.selected.length} 集'}',
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '只显示来源实际返回的兼容画质。失败后重试会复用已下载分集。',
          style: TextStyle(color: muted, fontSize: 11),
        ),
      ],
    ),
  );

  Widget _localCard() => Surface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle(
          '本地素材',
          subtitle: '也可以从已有视频开始',
          icon: Icons.folder_copy_outlined,
        ),
        const SizedBox(height: 18),
        if (c.localFiles.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: canvas,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Row(
              children: [
                Icon(Icons.upload_file_outlined, color: muted),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '导入同规格视频，按列表顺序拼接。',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
              ],
            ),
          ),
        for (var i = 0; i < c.localFiles.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Text(
                  '${i + 1}'.padLeft(2, '0'),
                  style: const TextStyle(color: accent, fontSize: 12),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.basename(c.localFiles[i]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                IconButton(
                  onPressed: c.busy || i == 0 ? null : () => c.moveFile(i, -1),
                  tooltip: '上移',
                  icon: const Icon(Icons.arrow_upward, size: 16),
                ),
                IconButton(
                  onPressed: c.busy || i == c.localFiles.length - 1
                      ? null
                      : () => c.moveFile(i, 1),
                  tooltip: '下移',
                  icon: const Icon(Icons.arrow_downward, size: 16),
                ),
                IconButton(
                  onPressed: c.busy ? null : () => c.removeFile(i),
                  tooltip: '移除素材',
                  icon: const Icon(Icons.close, size: 16),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            TextButton.icon(
              onPressed: c.busy || c.loading ? null : _pickFiles,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加视频'),
            ),
            TextButton.icon(
              onPressed:
                  c.busy ||
                      c.loading ||
                      c.localFiles.isEmpty ||
                      c.outputDirectory.isEmpty
                  ? null
                  : () => c.assemble(local: true),
              icon: const Icon(Icons.call_merge, size: 18),
              label: const Text('拼接本地素材'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _activityCard() => Surface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('任务动态', icon: Icons.waves_rounded),
        const SizedBox(height: 18),
        Text(c.status, style: const TextStyle(fontSize: 12, height: 1.6)),
        if (c.busy || c.progress > 0) ...[
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: c.progress,
              backgroundColor: canvas,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(c.progress * 100).round()}%',
            style: const TextStyle(fontSize: 11, color: muted),
          ),
        ],
        if (c.busy)
          TextButton.icon(
            onPressed: c.cancel,
            icon: const Icon(Icons.stop_circle_outlined, size: 17),
            label: const Text('取消任务'),
          ),
        if (c.error != null) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF1F0),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              c.error!,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFFB94747),
                height: 1.6,
              ),
            ),
          ),
        ],
        if (c.output != null) ...[
          const SizedBox(height: 14),
          SelectableText(
            c.output!,
            style: const TextStyle(fontSize: 11, color: muted),
          ),
          TextButton.icon(
            onPressed: () => _open(Uri.file(c.output!)),
            icon: const Icon(Icons.play_circle_outline, size: 18),
            label: const Text('打开导出视频'),
          ),
          if (Platform.isAndroid)
            TextButton.icon(
              onPressed: _saving ? null : () => _saveToPhone(c.output!),
              icon: const Icon(Icons.save_alt),
              label: Text(_saving ? '正在保存…' : '保存到手机'),
            ),
        ],
        if (c.events.isNotEmpty) ...[
          const SizedBox(height: 18),
          ...c.events
              .take(5)
              .map(
                (event) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    event,
                    style: const TextStyle(
                      fontSize: 10,
                      color: muted,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
        ],
      ],
    ),
  );

  Widget _historyCard() => Surface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle(
          '最近导出',
          subtitle: '合成文件保存在本地，使用内置播放器继续观看',
          icon: Icons.history,
        ),
        const SizedBox(height: 12),
        for (final item
            in c.history
                .where((e) => File(e['path'] as String).existsSync())
                .take(5))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.video_file_outlined, color: accent),
            title: Text(
              '${item['title']}',
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              '${item['count']} 段 · ${item['date'].toString().substring(0, 16).replaceAll('T', ' ')}',
              style: const TextStyle(fontSize: 11, color: muted),
            ),
            onTap: () => _open(Uri.file(item['path'] as String)),
            trailing: Platform.isAndroid
                ? IconButton(
                    tooltip: '保存到手机',
                    onPressed: _saving
                        ? null
                        : () => _saveToPhone(item['path'] as String),
                    icon: const Icon(Icons.save_alt),
                  )
                : const Icon(Icons.open_in_new, size: 18),
          ),
      ],
    ),
  );
}

class Surface extends StatelessWidget {
  const Surface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF252542).withValues(alpha: .035),
          blurRadius: 28,
          offset: const Offset(0, 8),
        ),
      ],
    ),
    child: Material(color: Colors.transparent, child: child),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(
    this.title, {
    super.key,
    this.subtitle,
    required this.icon,
  });
  final String title;
  final String? subtitle;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: accent, size: 19),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: const TextStyle(color: muted, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.icon});
  final String text;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: canvas,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: accent),
          const SizedBox(width: 6),
        ],
        Text(text, style: const TextStyle(color: muted, fontSize: 10)),
      ],
    ),
  );
}
