import 'dart:async';
import 'package:flutter/foundation.dart';
import 'data/hongguo_client.dart';
import 'domain/drama.dart';
import 'services/episode_preloader.dart';
import 'data/visitor_identity.dart';

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
  }) : client = client ?? HongguoClient() {
    _completed = engine.completed.listen((done) {
      if (done &&
          autoAdvance &&
          !loading &&
          error == null &&
          index + 1 < (drama?.episodes.length ?? 0)) {
        unawaited(play(index + 1));
      }
    });
    _errors = engine.errors.listen((_) {
      if (_disposed || loading) return;
      error = '播放失败，请重试或切换清晰度。';
      notifyListeners();
    });
  }
  final PlaybackEngine engine;
  final HongguoClient client;
  final EpisodePreloader? preloader;
  bool preloadNext = true;
  PreloadedEpisode? _ready, _playingFile;
  List<MediaVariant>? _readyOptions;
  int? _readyIndex;
  String? _preloadAttempt;
  int _preloadGeneration = 0;

  void setPreloadNext(bool value) {
    preloadNext = value;
    if (!value) _cancelPreload();
    notifyListeners();
  }

  void suspendPreload() => _cancelPreload();

  void _cancelPreload() {
    _preloadGeneration++;
    preloader?.cancel();
    final old = _ready;
    _ready = null;
    _readyOptions = null;
    _readyIndex = null;
    if (old != null) unawaited(old.dispose());
    _preloadAttempt = null;
  }

  void onProgress(Duration position, Duration duration) {
    final value = drama;
    if (_disposed ||
        loading ||
        !preloadNext ||
        preloader == null ||
        value == null ||
        duration.inMilliseconds <= 0 ||
        position.inMilliseconds < duration.inMilliseconds * .8 ||
        index + 1 >= value.episodes.length) {
      return;
    }
    final key = '${value.id}:$index:$quality';
    if (_preloadAttempt == key) return;
    _preloadAttempt = key;
    unawaited(_preload(value, index + 1, quality, _preloadGeneration));
  }

  Future<void> _preload(
    Drama value,
    int next,
    int target,
    int generation,
  ) async {
    try {
      final options = await client.fetchVariants(
        value.episodes[next],
        seriesId: value.id,
      );
      if (_disposed || generation != _preloadGeneration) return;
      final cached = await preloader!.load(chooseQuality(options, target));
      if (_disposed || generation != _preloadGeneration) {
        await cached?.dispose();
        return;
      }
      _ready = cached;
      _readyOptions = cached == null ? null : options;
      _readyIndex = cached == null ? null : next;
    } catch (_) {
      /* Playback continues with a fresh stream if preloading fails. */
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
    } catch (_) {
      if (_disposed || generation != _generation) return;
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
    final cached = _readyIndex == episodeIndex ? _ready : null;
    final cachedOptions = cached == null ? null : _readyOptions;
    if (cached != null) {
      _ready = null;
      _readyOptions = null;
      _readyIndex = null;
    }
    _cancelPreload();
    final generation = ++_generation;
    index = episodeIndex;
    loading = true;
    error = null;
    notifyListeners();
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
          await engine.open(media, start: start);
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
