import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'data/hongguo_client.dart';
import 'domain/drama.dart';
import 'services/episode_preloader.dart';
import 'data/visitor_identity.dart';
import 'services/app_logs.dart';
import 'domain/discovery.dart';
import 'domain/series_titles.dart';

abstract class PlaybackEngine {
  Stream<bool> get completed;
  Stream<String> get errors;
  Duration get position;
  Future<void> open(MediaVariant media, {Duration start = Duration.zero});
  Future<void> pause();
  Future<void> dispose();
}

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.engine,
    HongguoClient? client,
    this.preloader,
    this.preloadRetryDelay = const Duration(seconds: 2),
  }) : client = client ?? HongguoClient() {
    _completed = engine.completed.listen((done) {
      if (done &&
          autoAdvance &&
          !_suspended &&
          !loading &&
          error == null &&
          drama != null) {
        if (index + 1 < drama!.episodes.length) {
          unawaited(play(index + 1));
        } else if (_seasonArmed && !_seasonCancelled) {
          unawaited(playNextSeason(automatic: true));
        }
      }
    });
    _errors = engine.errors.listen((failure) {
      if (_disposed || loading) return;
      AppLogs.shared.add(LogLevel.error, '播放器', '播放引擎错误', error: failure);
      error = '播放失败，请重试或切换清晰度。';
      notifyListeners();
    });
  }
  final PlaybackEngine engine;
  final HongguoClient client;
  final EpisodePreloader? preloader;
  final Duration preloadRetryDelay;
  bool preloadNext = true;
  PreloadedEpisode? _ready, _playingFile;
  List<MediaVariant>? _readyOptions;
  int? _readyIndex;
  String? _preloadAttempt;
  int _preloadGeneration = 0;
  Future<void>? _preloadTask;
  String? _targetDramaId;
  int? _targetIndex, _targetQuality;
  DateTime? _optionsTime, _retryAfter;
  int _attempts = 0;
  bool preloading = false;
  bool get preloadReady => _ready != null;
  bool get playbackInfoReady => _readyOptions != null;
  MediaVariant? currentMedia;
  DramaSummary? nextSeason;
  Drama? _preparedSeason;
  Future<Drama>? _preparingSeason;
  int? nextSeasonSeconds;
  bool _seasonArmed = false, _seasonCancelled = false, _switchingSeason = false;
  bool get changingSeason => _switchingSeason;

  void setNextSeason(DramaSummary? value) {
    if (value != null &&
        (drama == null ||
            !SeriesTitle(drama!.title).isNextSeason(value.title) ||
            value.id == drama!.id)) {
      value = null;
    }
    if (nextSeason?.id == value?.id) return;
    nextSeason = value;
    _preparedSeason = null;
    _preparingSeason = null;
    nextSeasonSeconds = null;
    _seasonArmed = false;
    if (_targetDramaId != null && _targetDramaId != drama?.id) _cancelPreload();
    if (!_disposed) notifyListeners();
  }

  void cancelNextSeason() {
    _seasonCancelled = true;
    _seasonArmed = false;
    nextSeasonSeconds = null;
    notifyListeners();
  }

  void setPreloadNext(bool value) {
    preloadNext = value;
    if (!value) _cancelPreload();
    notifyListeners();
  }

  bool _suspended = false;
  void suspendPreload() {
    _suspended = true;
    _seasonArmed = false;
    nextSeasonSeconds = null;
    _cancelPreload();
    if (!_disposed) notifyListeners();
  }

  void _cancelPreload() {
    _preloadGeneration++;
    preloader?.cancel();
    final old = _ready;
    _ready = null;
    _readyOptions = null;
    _readyIndex = null;
    if (old != null) unawaited(old.dispose());
    _preloadAttempt = null;
    _preloadTask = null;
    _targetDramaId = null;
    _targetIndex = null;
    _targetQuality = null;
    _optionsTime = null;
    _retryAfter = null;
    _attempts = 0;
    preloading = false;
  }

  void onProgress(Duration position, Duration duration) {
    _suspended = false;
    final value = drama;
    if (_disposed ||
        loading ||
        error != null ||
        value == null ||
        duration.inMilliseconds <= 0) {
      return;
    }
    final isLast = index == value.episodes.length - 1;
    final remaining = duration.inMilliseconds - position.inMilliseconds;
    final countdown =
        isLast &&
            autoAdvance &&
            nextSeason != null &&
            !_seasonCancelled &&
            remaining <= 5000
        ? (remaining / 1000).ceil().clamp(0, 5)
        : null;
    if (nextSeasonSeconds != countdown) {
      nextSeasonSeconds = countdown;
      _seasonArmed = countdown != null;
      notifyListeners();
    }
    if (countdown == 0 && !_switchingSeason) {
      unawaited(playNextSeason(automatic: true));
      return;
    }
    if (_disposed ||
        loading ||
        !preloadNext ||
        preloader == null ||
        duration.inMilliseconds <= 0 ||
        position.inMilliseconds < duration.inMilliseconds * .8 ||
        isLast && nextSeason == null) {
      return;
    }
    final targetId = isLast ? nextSeason!.id : value.id;
    final targetIndex = isLast ? 0 : index + 1;
    final key = '$targetId:$targetIndex:$quality';
    if (_preloadAttempt != key) {
      _cancelPreload();
      _preloadAttempt = key;
      _targetDramaId = targetId;
      _targetIndex = targetIndex;
      _targetQuality = quality;
    }
    if (preloading ||
        _ready != null ||
        _attempts >= 2 ||
        _retryAfter != null && DateTime.now().isBefore(_retryAfter!)) {
      return;
    }
    _attempts++;
    preloading = true;
    notifyListeners();
    _preloadTask = _preloadTarget(
      value,
      targetIndex,
      quality,
      _preloadGeneration,
      isLast,
    );
    unawaited(_preloadTask!);
  }

  Future<void> _preloadTarget(
    Drama value,
    int next,
    int targetQuality,
    int generation,
    bool season,
  ) async {
    try {
      final target = season ? await _resolveNextSeason() : value;
      if (_disposed || generation != _preloadGeneration) return;
      final options = await client.fetchVariants(
        target.episodes[next],
        seriesId: target.id,
      );
      if (_disposed || generation != _preloadGeneration) return;
      final chosen = chooseQuality(options, targetQuality);
      _readyOptions = options;
      _readyIndex = next;
      _optionsTime = DateTime.now();
      final cached = chosen.sizeBytes > EpisodePreloader.maxBytes
          ? null
          : await preloader!.load(chosen);
      if (_disposed || generation != _preloadGeneration) {
        await cached?.dispose();
        return;
      }
      _ready = cached;
      if (chosen.sizeBytes > EpisodePreloader.maxBytes || !preloader!.retryable) {
        _attempts = 2;
      }
      if (cached == null &&
          chosen.sizeBytes <= EpisodePreloader.maxBytes &&
          preloader!.mediaLinkRejected) {
        _readyOptions = null;
        _readyIndex = null;
        _optionsTime = null;
      }
      if (cached == null) {
        AppLogs.shared.add(
          LogLevel.warning,
          '预加载',
          chosen.sizeBytes > EpisodePreloader.maxBytes
              ? '媒体超过缓存上限，保留播放信息。'
              : preloader!.lastFailure ?? '媒体缓存未就绪，保留播放信息。',
        );
      }
    } catch (failure) {
      AppLogs.shared.add(LogLevel.warning, '预加载', '下一集预加载失败', error: failure);
      /* Playback continues with a fresh stream if preloading fails. */
    } finally {
      if (!_disposed && generation == _preloadGeneration) {
        preloading = false;
        _retryAfter = DateTime.now().add(preloadRetryDelay);
        notifyListeners();
      }
    }
  }

  Future<Drama> _resolveNextSeason() {
    if (_preparedSeason?.id == nextSeason?.id && _preparedSeason != null) {
      return Future.value(_preparedSeason);
    }
    final candidate = nextSeason;
    if (candidate == null) return Future.error(StateError('没有可确认的下一季'));
    if (_preparingSeason != null) return _preparingSeason!;
    final origin = drama;
    late final Future<Drama> task;
    task = client
        .fetchDrama(candidate.id)
        .then((value) {
          if (value.id != candidate.id ||
              value.episodes.isEmpty ||
              origin == null ||
              !SeriesTitle(origin.title).isNextSeason(value.title)) {
            throw StateError('下一季信息不匹配');
          }
          if (nextSeason?.id == candidate.id && drama?.id == origin.id) {
            _preparedSeason = value;
          }
          return value;
        })
        .whenComplete(() {
          if (identical(_preparingSeason, task)) _preparingSeason = null;
        });
    _preparingSeason = task;
    return task;
  }

  Future<void> playNextSeason({bool automatic = false}) async {
    if (_disposed || _switchingSeason || nextSeason == null) return;
    _switchingSeason = true;
    notifyListeners();
    final generation = _generation;
    try {
      final next = await _resolveNextSeason();
      if (automatic && (!autoAdvance || _seasonCancelled || _suspended)) return;
      if (_disposed || generation != _generation || next.id != nextSeason?.id) {
        return;
      }
      onBeforeChange?.call();
      loading = true;
      drama = next;
      selected.clear();
      selected.add(next.episodes.first.number);
      _seasonCancelled = false;
      _seasonArmed = false;
      nextSeasonSeconds = null;
      await play(0);
      if (error == null && nextSeason?.id == next.id) {
        nextSeason = null;
        _preparedSeason = null;
      }
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        _seasonArmed = false;
        _seasonCancelled = true;
        nextSeasonSeconds = null;
        AppLogs.shared.add(LogLevel.warning, '连播', '下一季准备失败', error: failure);
        notifyListeners();
      }
    } finally {
      _switchingSeason = false;
      if (!_disposed) notifyListeners();
    }
  }

  late final StreamSubscription<bool> _completed;
  late final StreamSubscription<String> _errors;
  Drama? drama;
  List<MediaVariant> variants = [];
  final selected = <int>{};
  int index = 0, quality = 0;
  bool loading = false, autoAdvance = true, _disposed = false;
  String? error;
  int _generation = 0;
  Future<void> _openTail = Future.value();
  void Function()? onBeforeChange;

  Future<void> load(
    String id, {
    int episode = 1,
    String episodeId = '',
    Duration start = Duration.zero,
  }) async {
    _cancelPreload();
    nextSeason = null;
    _preparedSeason = null;
    _preparingSeason = null;
    _seasonCancelled = false;
    _seasonArmed = false;
    nextSeasonSeconds = null;
    final generation = ++_generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final value = await client.fetchDrama(id);
      if (_disposed || generation != _generation) return;
      if (value.episodes.isEmpty) throw StateError('来源未返回分集');
      drama = value;
      selected.clear();
      selected.add(value.episodes.first.number);
      var restored = value.episodes.indexWhere(
        (e) => episodeId.isNotEmpty && e.id == episodeId,
      );
      if (restored < 0) {
        restored = value.episodes.indexWhere((e) => e.number == episode);
      }
      await play(restored < 0 ? 0 : restored, start: start);
    } catch (failure) {
      if (_disposed || generation != _generation) return;
      AppLogs.shared.add(LogLevel.error, '播放', '分集读取失败', error: failure);
      error = '读取分集失败，请重试。';
      loading = false;
      notifyListeners();
    }
  }

  Future<void> play(int episodeIndex, {Duration start = Duration.zero}) async {
    final value = drama;
    if (_disposed ||
        value == null ||
        episodeIndex < 0 ||
        episodeIndex >= value.episodes.length) {
      return;
    }
    onBeforeChange?.call();
    _suspended = false;
    final generation = ++_generation;
    if (index != episodeIndex) _seasonCancelled = false;
    nextSeasonSeconds = null;
    _seasonArmed = false;
    index = episodeIndex;
    loading = true;
    error = null;
    notifyListeners();
    final matches =
        _targetDramaId == value.id &&
        _targetIndex == episodeIndex &&
        _targetQuality == quality;
    if (matches && _preloadTask != null && preloading) {
      await _preloadTask!.timeout(
        const Duration(milliseconds: 1200),
        onTimeout: () {},
      );
    }
    if (_disposed || generation != _generation) return;
    var cached = matches && _readyIndex == episodeIndex ? _ready : null;
    final cachedOptions =
        matches &&
            _readyIndex == episodeIndex &&
            (_ready != null ||
                _optionsTime != null &&
                    DateTime.now().difference(_optionsTime!) <
                        const Duration(minutes: 2))
        ? _readyOptions
        : null;
    if (cached != null) {
      try {
        if (Uri.parse(cached.media.url).scheme != 'file' ||
            !await File.fromUri(Uri.parse(cached.media.url)).exists()) {
          await cached.dispose();
          cached = null;
        }
      } catch (_) {
        await cached?.dispose();
        cached = null;
      }
    }
    if (_disposed || generation != _generation) {
      await cached?.dispose();
      return;
    }
    if (cached != null && identical(_ready, cached)) _ready = null;
    _cancelPreload();
    try {
      final options =
          cachedOptions ??
          await client.fetchVariants(
            value.episodes[episodeIndex],
            seriesId: value.id,
          );
      if (_disposed || generation != _generation) {
        await cached?.dispose();
        return;
      }
      final media = chooseQuality(options, quality);
      currentMedia = media;
      variants = options;
      final next = _openTail.then((_) async {
        if (_disposed || generation != _generation) {
          await cached?.dispose();
          return;
        }
        try {
          await engine.open(cached?.media ?? media, start: start);
        } catch (_) {
          if (cached == null) rethrow;
          final fresh = await client.fetchVariants(
            value.episodes[episodeIndex],
            seriesId: value.id,
          );
          if (_disposed || generation != _generation) {
            await cached?.dispose();
            return;
          }
          final replacement = chooseQuality(fresh, quality);
          await engine.open(replacement, start: start);
          variants = fresh;
          currentMedia = replacement;
          await cached?.dispose();
          cached = null;
        }
        final previous = _playingFile;
        _playingFile = cached;
        await previous?.dispose();
      });
      _openTail = next.catchError((_) {});
      await next;
      if (_disposed || generation != _generation) return;
      loading = false;
      notifyListeners();
    } catch (failure) {
      AppLogs.shared.add(LogLevel.error, '播放', '播放准备失败', error: failure);
      if (!identical(_playingFile, cached)) await cached?.dispose();
      if (_disposed || generation != _generation) return;
      error = failure is VisitorInitializationException
          ? failure.toString()
          : '播放准备失败，请重试或切换清晰度。';
      loading = false;
      notifyListeners();
    }
  }

  Future<void> setQuality(int value) {
    final position = engine.position;
    quality = value;
    return play(index, start: position);
  }

  void toggleSelection(int number) {
    selected.contains(number) ? selected.remove(number) : selected.add(number);
    notifyListeners();
  }

  void selectAll(bool all) {
    selected.clear();
    if (all) selected.addAll(drama?.episodes.map((e) => e.number) ?? <int>[]);
    notifyListeners();
  }

  void selectRange(int first, int last) {
    if (drama == null ||
        first < 1 ||
        last < first ||
        last > drama!.episodes.last.number) {
      return;
    }
    selected.clear();
    selected.addAll(
      drama!.episodes
          .where((e) => e.number >= first && e.number <= last)
          .map((e) => e.number),
    );
    notifyListeners();
  }

  void setAutoAdvance(bool value) {
    autoAdvance = value;
    if (!value) {
      nextSeasonSeconds = null;
      _seasonArmed = false;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelPreload();
    _generation++;
    unawaited(_completed.cancel());
    unawaited(_errors.cancel());
    unawaited(
      _openTail.then((_) async {
        await engine.dispose();
        await _playingFile?.dispose();
      }),
    );
    client.close();
    super.dispose();
  }
}
