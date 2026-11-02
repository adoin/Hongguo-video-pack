import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import 'app_controller.dart';
import 'domain/discovery.dart';
import 'domain/drama.dart';
import 'playback_controller.dart';
import 'playback_gestures.dart';
import 'services/playback_engine.dart';
import 'watch_history.dart';
import 'data/discovery_client.dart';
import 'related_controller.dart';
import 'services/episode_preloader.dart';
import 'services/app_logs.dart';

class PlaybackScreen extends StatefulWidget {
  const PlaybackScreen({
    super.key,
    required this.summary,
    required this.tasks,
    required this.onStitch,
    required this.onTasks,
    this.onCloseWindow,
    this.controller,
    this.videoBuilder,
    this.resume,
    this.nativeEngine,
    this.relatedController,
  });
  final DramaSummary summary;
  final StudioController tasks;
  final Future<bool> Function(Drama, Set<int>, int) onStitch;
  final VoidCallback onTasks;
  final Future<void> Function()? onCloseWindow;
  final PlaybackController? controller;
  final Widget Function()? videoBuilder;
  final WatchPoint? resume;
  final NativePlaybackEngine? nativeEngine;
  final RelatedController? relatedController;
  @override
  State<PlaybackScreen> createState() => _PlaybackScreenState();
}

class _PlaybackScreenState extends State<PlaybackScreen>
    with WidgetsBindingObserver {
  NativePlaybackEngine? _native;
  VideoController? _video;
  late final PlaybackController c;
  final first = TextEditingController(text: '1'),
      last = TextEditingController(text: '1');
  bool choosing = false, preparing = false;
  Timer? _historyTimer;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  RelatedController? _related;
  String? _relatedId, _checkedNearEnd;
  String? _checkpoint;
  bool _localLoading = false;
  String? _localError;
  bool get _local => widget.resume?.local == true;

  void _dramaChanged() {
    final drama = c.drama;
    if (drama == null || _related == null || _relatedId == drama.id) return;
    _relatedId = drama.id;
    unawaited(_related!.load(drama.id, drama.title));
  }

  void _playRelated(DramaSummary drama) {
    _saveProgress();
    unawaited(c.engine.pause());
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => PlaybackScreen(
          summary: drama,
          tasks: widget.tasks,
          onStitch: widget.onStitch,
          onTasks: widget.onTasks,
          onCloseWindow: widget.onCloseWindow,
        ),
      ),
    );
  }

  Widget _relatedSection() => ListenableBuilder(
    listenable: _related!,
    builder: (context, _) {
      final related = _related!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '相关剧集',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: related.loading ? null : related.refresh,
                tooltip: '刷新相关剧集',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (related.loading) const LinearProgressIndicator(),
          if (related.error != null) Text(related.error!),
          if (!related.loading &&
              related.items.isEmpty &&
              related.error == null)
            const Text('暂无相关剧集'),
          for (final drama in related.items.take(20))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: drama.cover.isEmpty
                  ? const Icon(Icons.movie_outlined)
                  : SizedBox(
                      width: 42,
                      height: 56,
                      child: Image.network(
                        drama.cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.movie_outlined),
                      ),
                    ),
              title: Text(
                drama.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${related.manual.any((row) => row.id == drama.id) ? '同名系列 · ' : ''}${drama.episodes} 集${drama.metric.isEmpty ? '' : ' · ${drama.metric}'}',
              ),
              trailing: const Icon(Icons.play_arrow_rounded),
              onTap: () => _playRelated(drama),
            ),
        ],
      );
    },
  );

  void _saveProgress() {
    final native = _native;
    if (native == null ||
        c.loading ||
        c.error != null ||
        _localLoading ||
        _localError != null) {
      return;
    }
    final position = native.player.state.position.inMilliseconds;
    final duration = native.player.state.duration.inMilliseconds;
    if (duration <= 0 || position <= 0) return;
    if (_local && !File(widget.resume!.path).existsSync()) {
      unawaited(widget.tasks.watchHistory.pruneMissing());
      return;
    }
    final checkpoint = '${c.index}:$position:$duration';
    if (_checkpoint == checkpoint) return;
    _checkpoint = checkpoint;
    WatchPoint point;
    if (_local) {
      point =
          widget.tasks.watchHistory.fileFor(widget.resume!.path) ??
          widget.resume!.copy();
    } else {
      final drama = c.drama;
      if (drama == null || drama.episodes.isEmpty) return;
      point = WatchPoint(
        title: drama.title,
        dramaId: drama.id,
        cover: drama.cover.isEmpty ? widget.summary.cover : drama.cover,
        episodeId: drama.episodes[c.index].id,
        episode: drama.episodes[c.index].number,
        total: drama.episodes.length,
      );
      final previous = widget.tasks.watchHistory.onlineFor(drama.id);
      point.watched = previous?.watched ?? false;
    }
    point.updateProgress(
      position,
      duration,
      finalEpisode: _local || c.index == c.drama!.episodes.length - 1,
    );
    widget.tasks.watchHistory.record(point);
  }

  Future<void> _openLocal() async {
    setState(() {
      _localLoading = true;
      _localError = null;
      c.error = null;
    });
    try {
      final point = widget.resume!;
      if (!await File(point.path).exists()) {
        await widget.tasks.watchHistory.pruneMissing();
        throw StateError('missing');
      }
      await _native!.open(
        MediaVariant(
          url: Uri.file(point.path).toString(),
          quality: 0,
          codec: 'local',
        ),
        start: Duration(milliseconds: point.positionMs),
      );
    } catch (failure, stack) {
      AppLogs.shared.add(
        LogLevel.error,
        '本地播放',
        '本地视频打开失败',
        error: failure,
        stack: stack,
      );
      if (mounted) _localError = '无法播放本地视频，请确认文件仍存在且可以读取。';
    } finally {
      if (mounted) setState(() => _localLoading = false);
    }
  }

  static const _platform = MethodChannel('dev.hongguo.studio/platform');

  Widget _controls(VideoState state) => Builder(
    builder: (context) {
      if (desktop) return MaterialVideoControls(state);
      final controls = MaterialVideoControlsTheme(
        normal: const MaterialVideoControlsThemeData(),
        fullscreen: const MaterialVideoControlsThemeData(
          volumeGesture: false,
          brightnessGesture: false,
          seekGesture: false,
        ),
        child: MaterialVideoControls(state),
      );
      if (!isFullscreen(context) ||
          MediaQuery.orientationOf(context) != Orientation.landscape) {
        return controls;
      }
      final player = _native!.player;
      return PlaybackGestures(
        position: () => player.state.position,
        duration: () => player.state.duration,
        seek: player.seek,
        changeEpisode: (step) {
          final next = c.index + step;
          if (!c.loading &&
              next >= 0 &&
              next < (c.drama?.episodes.length ?? 0)) {
            unawaited(c.play(next));
          }
        },
        levels: () async {
          final values = await _platform.invokeMapMethod<String, dynamic>(
            'playbackLevels',
          );
          return (
            (values?['brightness'] as num?)?.toDouble() ?? .5,
            (values?['volume'] as num?)?.toDouble() ?? .5,
          );
        },
        setLevel: (light, value) => _platform.invokeMethod<void>(
          light ? 'playbackBrightness' : 'playbackVolume',
          {'value': value},
        ),
        onDispose: () => unawaited(
          _platform
              .invokeMethod<void>('resetPlaybackBrightness')
              .catchError((Object _) {}),
        ),
        child: controls,
      );
    },
  );
  int episodePage = 0;
  bool get desktop => {
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  }.contains(Theme.of(context).platform);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller == null) {
      _native = widget.nativeEngine ?? NativePlaybackEngine();
      _video = VideoController(_native!.player);
    }
    c =
        widget.controller ??
        PlaybackController(
          engine: _native!,
          preloader: EpisodePreloader(
            directory: widget.tasks.playbackCacheDirectory,
          ),
        );
    c.setPreloadNext(widget.tasks.preloadNext);
    _related =
        widget.relatedController ??
        (widget.controller == null && !_local
            ? RelatedController(client: DiscoveryClient())
            : null);
    c.addListener(_dramaChanged);
    _dramaChanged();
    c.onBeforeChange = _saveProgress;
    if (_local) {
      unawaited(_openLocal());
    } else if (c.drama == null) {
      final point =
          widget.resume ??
          widget.tasks.watchHistory.onlineFor(widget.summary.id);
      episodePage = ((point?.episode ?? 1) - 1) ~/ 50;
      unawaited(
        c.load(
          widget.summary.id,
          episode: point?.episode ?? 1,
          episodeId: point?.episodeId ?? '',
          start: Duration(milliseconds: point?.positionMs ?? 0),
        ),
      );
    }
    if (_native != null) {
      _positionSubscription = _native!.player.stream.position.listen((
        position,
      ) {
        if (_local || !_native!.player.state.playing) return;
        final duration = _native!.player.state.duration;
        c.onProgress(position, duration);
        final drama = c.drama;
        if (!c.loading &&
            c.error == null &&
            drama != null &&
            c.index == drama.episodes.length - 1 &&
            duration.inMilliseconds > 0 &&
            position.inMilliseconds >= duration.inMilliseconds * .8 &&
            _checkedNearEnd != drama.id) {
          _checkedNearEnd = drama.id;
          if (_related != null) unawaited(_related!.refresh());
        }
      });
      _historyTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_native!.player.state.playing) _saveProgress();
      });
      _playingSubscription = _native!.player.stream.playing.listen((playing) {
        if (!playing) _saveProgress();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _saveProgress();
      unawaited(widget.tasks.watchHistory.flush());
    }
    if (state == AppLifecycleState.paused) {
      c.suspendPreload();
      unawaited(c.engine.pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _historyTimer?.cancel();
    unawaited(_playingSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    c.removeListener(_dramaChanged);
    if (widget.relatedController == null) _related?.dispose();
    _saveProgress();
    c.onBeforeChange = null;
    if (widget.controller == null) c.dispose();
    first.dispose();
    last.dispose();
    super.dispose();
  }

  Future<void> _stitch() async {
    if (preparing ||
        widget.tasks.busy ||
        widget.tasks.loading ||
        c.drama == null ||
        c.selected.isEmpty) {
      return;
    }
    setState(() => preparing = true);
    try {
      final ok = await widget.onStitch(c.drama!, {...c.selected}, c.quality);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '拼接任务已开始，可在任务管理查看进度。' : '无法准备拼接任务，请重试。')),
      );
    } catch (failure, stack) {
      AppLogs.shared.add(
        LogLevel.error,
        '拼接',
        '准备拼接任务失败',
        error: failure,
        stack: stack,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('准备拼接任务失败，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([c, widget.tasks]),
    builder: (context, _) {
      final episodes = c.drama?.episodes ?? <Episode>[];
      final pages = ((episodes.length + 49) ~/ 50).clamp(1, 10000);
      final rangePage = episodePage.clamp(0, pages - 1);
      final width = MediaQuery.sizeOf(context).width;
      return Scaffold(
        backgroundColor: const Color(0xFFF6F6F8),
        appBar: AppBar(
          backgroundColor: const Color(0xFFF6F6F8),
          title: desktop
              ? DragToMoveArea(
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      c.drama?.title ?? widget.summary.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
              : Text(
                  c.drama?.title ?? widget.summary.title,
                  overflow: TextOverflow.ellipsis,
                ),
          actions: [
            TextButton.icon(
              onPressed: widget.onTasks,
              icon: const Icon(Icons.downloading_outlined),
              label: const Text('任务管理'),
            ),
            if (desktop) ...[
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
                  _saveProgress();
                  await widget.tasks.watchHistory.flush();
                  await widget.onCloseWindow?.call();
                },
                brightness: Brightness.light,
              ),
            ],
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: EdgeInsets.all(width < 600 ? 12 : 24),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: AspectRatio(
                          aspectRatio: width < 600 ? 9 / 12 : 16 / 9,
                          child: ColoredBox(
                            color: Colors.black,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (widget.videoBuilder != null)
                                  widget.videoBuilder!()
                                else
                                  Video(
                                    controller: _video!,
                                    controls: _controls,
                                  ),
                                if (c.loading || _localLoading)
                                  const IgnorePointer(
                                    child: Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  ),
                                if (c.error != null || _localError != null)
                                  Center(
                                    child: Container(
                                      margin: const EdgeInsets.all(16),
                                      padding: const EdgeInsets.all(20),
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            _localError ?? c.error!,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          FilledButton(
                                            onPressed: () => _local
                                                ? _openLocal()
                                                : c.drama == null
                                                ? c.load(widget.summary.id)
                                                : c.play(c.index),
                                            child: const Text('重试播放'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_local) ...[
                        const Text(
                          '本地合成视频 · 自动保存观看位置',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Text(widget.resume!.title),
                      ] else ...[
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              episodes.isEmpty
                                  ? '正在读取完整分集…'
                                  : '第 ${episodes[c.index].number} 集 / 共 ${episodes.length} 集',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            IconButton(
                              tooltip: '上一集',
                              onPressed: c.loading || c.index <= 0
                                  ? null
                                  : () => c.play(c.index - 1),
                              icon: const Icon(Icons.skip_previous_rounded),
                            ),
                            IconButton(
                              tooltip: '下一集',
                              onPressed:
                                  c.loading || c.index + 1 >= episodes.length
                                  ? null
                                  : () => c.play(c.index + 1),
                              icon: const Icon(Icons.skip_next_rounded),
                            ),
                            if (c.variants.isNotEmpty)
                              DropdownButton<int>(
                                value:
                                    c.variants.any(
                                      (v) => v.quality == c.quality,
                                    )
                                    ? c.quality
                                    : 0,
                                items: [
                                  const DropdownMenuItem(
                                    value: 0,
                                    child: Text('自动画质'),
                                  ),
                                  ...c.variants.map(
                                    (v) => DropdownMenuItem(
                                      value: v.quality,
                                      child: Text(v.label),
                                    ),
                                  ),
                                ],
                                onChanged: c.loading
                                    ? null
                                    : (v) {
                                        if (v != null) c.setQuality(v);
                                      },
                              ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('自动连播'),
                                Switch(
                                  value: c.autoAdvance,
                                  onChanged: c.setAutoAdvance,
                                ),
                              ],
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('预加载下一集'),
                                Switch(
                                  key: const ValueKey('preload-next-switch'),
                                  value: c.preloadNext,
                                  onChanged: (value) {
                                    widget.tasks.setPreloadNext(value);
                                    c.setPreloadNext(value);
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SegmentedButton<bool>(
                              style: const ButtonStyle(
                                side: WidgetStatePropertyAll(BorderSide.none),
                              ),
                              segments: const [
                                ButtonSegment(
                                  value: false,
                                  label: Text('播放选集'),
                                  icon: Icon(Icons.play_arrow_rounded),
                                ),
                                ButtonSegment(
                                  value: true,
                                  label: Text('选择拼接'),
                                  icon: Icon(Icons.video_library_outlined),
                                ),
                              ],
                              selected: {choosing},
                              onSelectionChanged: (value) =>
                                  setState(() => choosing = value.first),
                            ),
                            FilledButton.icon(
                              onPressed:
                                  preparing ||
                                      widget.tasks.busy ||
                                      widget.tasks.loading ||
                                      c.selected.isEmpty
                                  ? null
                                  : _stitch,
                              icon: const Icon(Icons.merge_rounded),
                              label: Text(
                                preparing
                                    ? '准备任务…'
                                    : '拼接所选 ${c.selected.length} 集',
                              ),
                            ),
                          ],
                        ),
                        if (widget.tasks.busy)
                          Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                LinearProgressIndicator(
                                  value: widget.tasks.progress,
                                ),
                                const SizedBox(height: 8),
                                Text(widget.tasks.status),
                              ],
                            ),
                          ),
                        if (choosing)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                TextButton(
                                  onPressed: () {
                                    c.selectAll(false);
                                    if (episodes.isNotEmpty) {
                                      c.toggleSelection(
                                        episodes[c.index].number,
                                      );
                                    }
                                  },
                                  child: const Text('只选当前集'),
                                ),
                                TextButton(
                                  onPressed: () => c.selectAll(true),
                                  child: const Text('全选'),
                                ),
                                TextButton(
                                  onPressed: () => c.selectAll(false),
                                  child: const Text('清空'),
                                ),
                                SizedBox(
                                  width: 72,
                                  child: TextField(
                                    controller: first,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: '起始',
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 72,
                                  child: TextField(
                                    controller: last,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: '结束',
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    final a = int.tryParse(first.text),
                                        b = int.tryParse(last.text);
                                    if (a == null ||
                                        b == null ||
                                        a < 1 ||
                                        b < a ||
                                        episodes.isEmpty ||
                                        b > episodes.last.number) {
                                      return;
                                    }
                                    c.selectRange(a, b);
                                  },
                                  child: const Text('选择范围'),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final scale =
                                MediaQuery.textScalerOf(context).scale(13) / 13;
                            final columns =
                                (constraints.maxWidth / (80 * scale))
                                    .floor()
                                    .clamp(1, 10);
                            final start = rangePage * 50;
                            final count = (episodes.length - start).clamp(
                              0,
                              50,
                            );
                            return GridView.builder(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                    mainAxisExtent: 48 * scale,
                                  ),
                              itemCount: count,
                              itemBuilder: (context, offset) {
                                final i = start + offset;
                                final number = episodes[i].number;
                                final selected = choosing
                                    ? c.selected.contains(number)
                                    : i == c.index;
                                final colors = Theme.of(context).colorScheme;
                                return Semantics(
                                  selected: selected,
                                  child: TextButton(
                                    key: ValueKey('episode-$number'),
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      backgroundColor: selected
                                          ? colors.secondaryContainer
                                          : Colors.white,
                                      foregroundColor: selected
                                          ? colors.onSecondaryContainer
                                          : const Color(0xFF24242D),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onPressed: () => choosing
                                        ? c.toggleSelection(number)
                                        : c.play(i),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Center(
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              '第 $number 集',
                                              style: const TextStyle(
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ),
                                        if (selected)
                                          const Positioned(
                                            right: 0,
                                            top: 2,
                                            child: Icon(
                                              Icons.check_rounded,
                                              size: 12,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                        if (pages > 1)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              TextButton(
                                onPressed: rangePage == 0
                                    ? null
                                    : () => setState(
                                        () => episodePage = rangePage - 1,
                                      ),
                                child: const Text('前 50 集'),
                              ),
                              Text('${rangePage + 1} / $pages'),
                              TextButton(
                                onPressed: rangePage + 1 == pages
                                    ? null
                                    : () => setState(
                                        () => episodePage = rangePage + 1,
                                      ),
                                child: const Text('后 50 集'),
                              ),
                            ],
                          ),
                        if (_related != null) _relatedSection(),
                        const SizedBox(height: 20),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
