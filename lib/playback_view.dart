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
import 'domain/series_titles.dart';
import 'playback_orientation.dart';

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
  bool _appActive = true;
  String? _localError;
  bool get _local => widget.resume?.local == true;
  StreamSubscription? _dimensionsSubscription;
  bool _fullscreen = false;
  String? _orientationMode, _lastEpisode;
  Future<void> _applyOrientation() async {
    if (desktop || !_fullscreen) return;
    final ratio = _knownAspect;
    final mode = ratio == null || (ratio - 1).abs() < .05
        ? 'auto'
        : ratio < 1
        ? 'portrait'
        : 'landscape';
    if (mode == _orientationMode) return;
    _orientationMode = mode;
    await SystemChrome.setPreferredOrientations(fullscreenOrientations(ratio));
  }

  Future<void> _enterFullscreen() async {
    _fullscreen = true;
    if (desktop) {
      await defaultEnterNativeFullscreen();
      return;
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await _applyOrientation();
  }

  Future<void> _exitFullscreen() async {
    _fullscreen = false;
    _orientationMode = null;
    await defaultExitNativeFullscreen();
  }

  void _dimensionsChanged() {
    if (!mounted) return;
    setState(() {});
    if (_fullscreen) unawaited(_applyOrientation());
  }

  void _relatedChanged() {
    if (_related == null || _related!.loading || c.drama == null || _local) {
      return;
    }
    final family = SeriesTitle(c.drama!.title);
    final candidates = _related!.items
        .where((row) => family.isNextSeason(row.title))
        .toList();
    c.setNextSeason(candidates.length == 1 ? candidates.single : null);
  }

  void _dramaChanged() {
    final drama = c.drama;
    final episode = drama == null ? null : '${drama.id}:${c.index}';
    if (episode != _lastEpisode) {
      _lastEpisode = episode;
      episodePage = c.index ~/ 50;
    }
    if (drama == null || _related == null || _relatedId == drama.id) return;
    _relatedId = drama.id;
    c.setNextSeason(null);
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
    final checkpoint =
        '${_local ? widget.resume!.path : c.drama?.id}:${c.index}:$position:$duration';
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
      if (desktop) {
        return Stack(
          fit: StackFit.expand,
          children: [MaterialVideoControls(state), _countdown()],
        );
      }
      final controls = MaterialVideoControlsTheme(
        normal: const MaterialVideoControlsThemeData(),
        fullscreen: const MaterialVideoControlsThemeData(
          volumeGesture: false,
          brightnessGesture: false,
          seekGesture: false,
        ),
        child: MaterialVideoControls(state),
      );
      final decorated = Stack(
        fit: StackFit.expand,
        children: [controls, _countdown()],
      );
      if (!isFullscreen(context)) {
        return decorated;
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
        child: decorated,
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
    _related?.addListener(_relatedChanged);
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
      _dimensionsSubscription = _native!.player.stream.videoParams.listen(
        (_) => _dimensionsChanged(),
      );
      _positionSubscription = _native!.player.stream.position.listen((
        position,
      ) {
        if (_local || !_appActive || !_native!.player.state.playing) return;
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
    if (state == AppLifecycleState.resumed) _appActive = true;
    if (state == AppLifecycleState.paused) _appActive = false;
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
    unawaited(_dimensionsSubscription?.cancel());
    _related?.removeListener(_relatedChanged);
    c.removeListener(_dramaChanged);
    if (widget.relatedController == null) _related?.dispose();
    _saveProgress();
    c.onBeforeChange = null;
    if (_fullscreen) unawaited(_exitFullscreen());
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

  int _detailTab = 0;
  double get _aspect => _knownAspect ?? 16 / 9;
  double? get _knownAspect {
    final params = _native?.player.state.videoParams;
    final w = params?.dw ?? _native?.player.state.width ?? 0;
    final h = params?.dh ?? _native?.player.state.height ?? 0;
    final rotated = (params?.rotate ?? 0).abs() % 180 == 90;
    return w > 0 && h > 0
        ? (rotated ? h / w : w / h)
        : c.currentMedia?.aspectRatio;
  }

  Widget _countdown() => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      if (c.nextSeasonSeconds == null || c.nextSeason == null) {
        return const SizedBox.shrink();
      }
      final rich = Align(
        alignment: Alignment.bottomRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .85),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.changingSeason
                    ? '正在准备下一季…'
                    : '${c.nextSeasonSeconds} 秒后播放下一季',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                c.nextSeason!.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: c.cancelNextSeason,
                    child: const Text(
                      '取消',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  FilledButton(
                    onPressed: c.playNextSeason,
                    style: _compact,
                    child: const Text('立即播放'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      return LayoutBuilder(
        builder: (context, box) => box.maxHeight >= 220
            ? rich
            : Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.changingSeason
                              ? '准备下一季…'
                              : '${c.nextSeasonSeconds} 秒后播放下一季',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: c.cancelNextSeason,
                        child: const Text(
                          '取消',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
  ButtonStyle get _compact => FilledButton.styleFrom(
    minimumSize: const Size(0, 40),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
  );
  Widget _player(double height) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: SizedBox(
      height: height,
      width: double.infinity,
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
                onEnterFullscreen: _enterFullscreen,
                onExitFullscreen: _exitFullscreen,
              ),
            if (c.loading || _localLoading)
              const IgnorePointer(
                child: Center(child: CircularProgressIndicator()),
              ),
            if (c.error != null || _localError != null)
              Center(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _localError ?? c.error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        style: _compact,
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
            if (widget.videoBuilder != null) _countdown(),
          ],
        ),
      ),
    ),
  );
  Widget _transport() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _local
                ? '本地视频'
                : c.drama == null
                ? '读取分集…'
                : '第 ${c.drama!.episodes[c.index].number} 集 / 共 ${c.drama!.episodes.length} 集',
            style: const TextStyle(fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (!_local) ...[
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
                c.loading || c.index + 1 >= (c.drama?.episodes.length ?? 0)
                ? null
                : () => c.play(c.index + 1),
            icon: const Icon(Icons.skip_next_rounded),
          ),
          if (c.variants.isNotEmpty)
            PopupMenuButton<int>(
              tooltip: '画质',
              initialValue: c.quality,
              onSelected: c.setQuality,
              itemBuilder: (_) => [
                const PopupMenuItem(value: 0, child: Text('自动画质')),
                ...c.variants.map(
                  (v) => PopupMenuItem(value: v.quality, child: Text(v.label)),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  c.quality == 0 ? '自动画质' : '${c.quality}P',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
        ],
      ],
    ),
  );
  Widget _details() {
    if (_local) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(widget.resume!.title),
      );
    }
    final episodes = c.drama?.episodes ?? <Episode>[];
    final pages = ((episodes.length + 49) ~/ 50).clamp(1, 10000),
        currentPage = episodePage.clamp(
          0,
          ((episodes.length + 49) ~/ 50).clamp(1, 10000) - 1,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 0,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('自动连播', style: TextStyle(fontSize: 12)),
                Switch(value: c.autoAdvance, onChanged: c.setAutoAdvance),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('预加载下一集', style: TextStyle(fontSize: 12)),
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
        SizedBox(
          height: 22,
          child: Text(
            c.preloading
                ? '预加载中…'
                : c.preloadReady
                ? '下一集已缓存'
                : c.playbackInfoReady
                ? '下一集播放信息已准备'
                : '',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        if (c.nextSeason != null && _detailTab != 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('下一季', style: TextStyle(fontSize: 12)),
              subtitle: Text(
                c.nextSeason!.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: '播放下一季',
                onPressed: c.loading ? null : c.playNextSeason,
                icon: const Icon(Icons.play_circle_outline),
              ),
            ),
          ),
        SegmentedButton<int>(
          showSelectedIcon: false,
          expandedInsets: EdgeInsets.zero,
          style: ButtonStyle(
            side: const WidgetStatePropertyAll(BorderSide.none),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            ),
            textStyle: WidgetStatePropertyAll(
              Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12),
            ),
          ),
          segments: const [
            ButtonSegment(value: 0, label: Text('播放选集')),
            ButtonSegment(value: 1, label: Text('选择拼接')),
            ButtonSegment(value: 2, label: Text('相关推荐')),
          ],
          selected: {_detailTab},
          onSelectionChanged: (value) => setState(() {
            _detailTab = value.first;
            choosing = _detailTab == 1;
          }),
        ),
        const SizedBox(height: 12),
        if (_detailTab == 2) ...[
          if (_related != null) _relatedSection() else const Text('暂无相关剧集'),
        ] else ...[
          FilledButton.icon(
            style: _compact,
            onPressed:
                preparing ||
                    widget.tasks.busy ||
                    widget.tasks.loading ||
                    c.selected.isEmpty
                ? null
                : _stitch,
            icon: const Icon(Icons.merge_rounded, size: 18),
            label: Text(preparing ? '准备任务…' : '拼接所选 ${c.selected.length} 集'),
          ),
          if (widget.tasks.busy)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  LinearProgressIndicator(value: widget.tasks.progress),
                  Text(widget.tasks.status),
                ],
              ),
            ),
          if (choosing)
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () {
                    c.selectAll(false);
                    if (episodes.isNotEmpty) {
                      c.toggleSelection(episodes[c.index].number);
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
                    decoration: const InputDecoration(labelText: '起始'),
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: TextField(
                    controller: last,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '结束'),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    final a = int.tryParse(first.text),
                        b = int.tryParse(last.text);
                    if (a != null && b != null) c.selectRange(a, b);
                  },
                  child: const Text('选择范围'),
                ),
              ],
            ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
              final columns = (constraints.maxWidth / (72 * scale))
                  .floor()
                  .clamp(1, 8);
              final start = currentPage * 50,
                  count = (episodes.length - start).clamp(0, 50);
              return GridView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  mainAxisExtent: 46 * scale,
                ),
                itemCount: count,
                itemBuilder: (context, offset) {
                  final i = start + offset, number = episodes[i].number;
                  final selected = choosing
                      ? c.selected.contains(number)
                      : i == c.index;
                  final colors = Theme.of(context).colorScheme;
                  return FilledButton.tonal(
                    key: ValueKey('episode-$number'),
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      backgroundColor: selected
                          ? colors.secondaryContainer
                          : Colors.white,
                      foregroundColor: selected
                          ? colors.onSecondaryContainer
                          : const Color(0xFF24242D),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () =>
                        choosing ? c.toggleSelection(number) : c.play(i),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '第 $number 集',
                              maxLines: 1,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        if (selected)
                          const Positioned(
                            right: 2,
                            top: 2,
                            child: Icon(Icons.check_rounded, size: 11),
                          ),
                      ],
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
                Expanded(
                  child: TextButton(
                    onPressed: currentPage == 0
                        ? null
                        : () => setState(() => episodePage = currentPage - 1),
                    child: const Text('前 50 集'),
                  ),
                ),
                Text(
                  '${currentPage + 1} / $pages',
                  style: const TextStyle(fontSize: 12),
                ),
                Expanded(
                  child: TextButton(
                    onPressed: currentPage + 1 == pages
                        ? null
                        : () => setState(() => episodePage = currentPage + 1),
                    child: const Text('后 50 集'),
                  ),
                ),
              ],
            ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([c, widget.tasks]),
    builder: (context, _) {
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
          child: LayoutBuilder(
            builder: (context, box) {
              final wide =
                  box.maxWidth >= 960 ||
                  box.maxWidth >= 680 && box.maxWidth > box.maxHeight * 1.4;
              final details = SingleChildScrollView(
                key: const ValueKey('playback-details-scroll'),
                padding: const EdgeInsets.all(12),
                child: _details(),
              );
              if (wide) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, left) => Column(
                            children: [
                              Expanded(
                                child: Center(
                                  child: _player(
                                    (left.maxHeight - 64).clamp(
                                      120,
                                      double.infinity,
                                    ),
                                  ),
                                ),
                              ),
                              _transport(),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      SizedBox(
                        width: box.maxWidth >= 960 ? 360 : box.maxWidth * .38,
                        child: details,
                      ),
                    ],
                  ),
                );
              }
              final height = (box.maxWidth / _aspect).clamp(
                140,
                (box.maxHeight * .55).clamp(140, double.infinity),
              );
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    _player(height.toDouble()),
                    _transport(),
                    Expanded(child: details),
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );
}
