import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'data/hongguo_client.dart';
import 'domain/drama.dart';
import 'services/media_engine.dart';
import 'data/request_signer.dart';
import 'data/visitor_identity.dart';
import 'watch_history.dart';
import 'services/app_logs.dart';

class StudioController extends ChangeNotifier {
  StudioController({HongguoClient? client, MediaEngine? engine})
    : client = client ?? HongguoClient(),
      engine = engine ?? MediaEngine() {
    watchHistory.addListener(notifyListeners);
  }
  final watchHistory = WatchHistory();
  final HongguoClient client;
  final MediaEngine engine;
  Drama? drama;
  final selected = <int>{};
  List<MediaVariant> variants = [];
  final localFiles = <String>[];
  final events = <String>[];
  final history = <Map<String, dynamic>>[];
  bool loading = false, busy = false, normalize = true;
  bool preloadNext = true;
  Future<Directory> playbackCacheDirectory() async {
    final store = _store;
    if (store == null) throw StateError('播放缓存尚未初始化');
    return Directory(p.join(store.parent.path, 'data', 'playback-cache'));
  }

  void setPreloadNext(bool value) {
    preloadNext = value;
    _save();
    notifyListeners();
  }

  int quality = 0;
  double progress = 0;
  String status = '粘贴一部短剧，开始你的第一个合集。';
  String lastInput = 'https://hongguoduanju.com/player/7671966197985856536';
  String? error, output;
  String outputDirectory = '';
  File? _store;
  Timer? _saveTimer;
  bool _disposed = false;
  Future<void> _persistTail = Future.value();
  String? _restoreId;
  List<int> _restoreSelection = [];
  int _restoreQuality = 0;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> initialize(File store, String defaultOutput) async {
    _store = store;
    outputDirectory = defaultOutput;
    try {
      if (await store.exists()) {
        final data = jsonDecode(await store.readAsString()) as Map;
        lastInput = data['lastInput'] as String? ?? lastInput;
        _restoreId = data['dramaId'] as String?;
        _restoreSelection = (data['selected'] as List? ?? [])
            .whereType<int>()
            .where((n) => n > 0)
            .toList();
        _restoreQuality = data['quality'] as int? ?? 0;
        if (!Platform.isAndroid) {
          outputDirectory = data['directory'] as String? ?? defaultOutput;
        }
        normalize = data['normalize'] != false;
        preloadNext = data['preloadNext'] != false;
        for (final item in data['history'] as List? ?? []) {
          if (item is Map &&
              item['title'] is String &&
              item['path'] is String &&
              item['date'] is String &&
              DateTime.tryParse(item['date'] as String) != null &&
              item['count'] is int) {
            final entry = Map<String, dynamic>.from(item);
            entry['date'] = DateTime.parse(
              item['date'] as String,
            ).toIso8601String();
            if (await File(entry['path'] as String).exists()) {
              history.add(entry);
            }
          }
        }
        if (data['busy'] == true) status = '上次任务已中断；重新读取后可继续，已下载分集会自动复用。';
      }
    } catch (failure, stack) {
      AppLogs.shared.add(
        LogLevel.warning,
        '设置',
        '工作区配置读取失败',
        error: failure,
        stack: stack,
      );
      status = '已恢复默认设置，现有导出文件不受影响。';
    }
    await Directory(outputDirectory).create(recursive: true);
    await watchHistory.initialize(
      File(p.join(store.parent.path, 'data', 'watch-history.json')),
    );
    for (final entry in history.reversed) {
      watchHistory.record(
        WatchPoint(
          title: entry['title'] as String,
          path: entry['path'] as String,
        ),
        importing: true,
        date: DateTime.tryParse(entry['date'] as String),
      );
    }
    await watchHistory.flush();
    notifyListeners();
  }

  void _save() {
    if (_store == null || _disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), flush);
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    final historySaved = watchHistory.flush();
    final store = _store;
    if (store == null) return historySaved;
    final payload = jsonEncode({
      'lastInput': lastInput,
      'directory': outputDirectory,
      'normalize': normalize,
      'preloadNext': preloadNext,
      'busy': busy,
      'history': history,
      'dramaId': drama?.id,
      'selected': selected.toList()..sort(),
      'quality': quality,
    });
    _persistTail = _persistTail.then((_) async {
      try {
        await store.parent.create(recursive: true);
        final temp = File('${store.path}.tmp');
        await temp.writeAsString(payload, flush: true);
        await temp.rename(store.path);
      } catch (failure, stack) {
        AppLogs.shared.add(
          LogLevel.error,
          '设置',
          '工作区配置保存失败',
          error: failure,
          stack: stack,
        );
        /* Media export remains valid even if preferences cannot be saved. */
      }
    });
    return Future.wait([_persistTail, historySaved]).then((_) {});
  }

  Future<void> clearCache() async {
    if (busy || loading || outputDirectory.isEmpty) return;
    try {
      final directory = Directory(p.join(outputDirectory, '.hongguo-cache'));
      if (await directory.exists()) {
        final root = await Directory(outputDirectory).resolveSymbolicLinks();
        final cache = await directory.resolveSymbolicLinks();
        if (!p.isWithin(root, cache)) throw StateError('缓存位置异常，已停止清理');
        await directory.delete(recursive: true);
      }
      log('已清理下载缓存，导出的 MP4 文件保留');
    } catch (e) {
      error = friendlyError(e);
      notifyListeners();
    }
  }

  void log(String message) {
    AppLogs.shared.add(LogLevel.info, '任务', message);
    events.insert(
      0,
      '${DateTime.now().toIso8601String().substring(11, 19)}  $message',
    );
    if (events.length > 60) events.removeLast();
    status = message;
    _save();
    notifyListeners();
  }

  Future<void> load(String input) async {
    if (loading || busy) return;
    loading = true;
    error = null;
    variants = [];
    drama = null;
    selected.clear();
    output = null;
    quality = 0;
    lastInput = input.trim();
    notifyListeners();
    try {
      drama = await client.fetchDrama(input);
      var desiredQuality = 0;
      if (_restoreId == drama!.id && _restoreSelection.isNotEmpty) {
        selected.addAll(
          drama!.episodes
              .where((e) => _restoreSelection.contains(e.number))
              .map((e) => e.number),
        );
        desiredQuality = _restoreQuality;
      } else {
        selected.addAll(drama!.episodes.take(2).map((e) => e.number));
      }
      _restoreId = null;
      log('已读取 ${drama!.title} · ${drama!.episodes.length} 集');
      await checkQuality(drama!.episodes.first);
      if (variants.any((v) => v.quality == desiredQuality)) {
        quality = desiredQuality;
      }
    } catch (e) {
      error = friendlyError(e);
      log('读取失败，请检查链接或稍后重试');
      AppLogs.shared.add(LogLevel.error, '剧集', '剧集读取失败', error: e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> checkQuality(Episode episode) async {
    try {
      variants = await client.fetchVariants(episode, seriesId: drama!.id);
      if (!variants.any((v) => v.quality == quality)) quality = 0;
      error = null;
      log(
        '第 ${episode.number} 集兼容画质：${variants.map((v) => v.label).join(' / ')}',
      );
    } catch (e) {
      variants = [];
      quality = 0;
      error = friendlyError(e);
      log('取流暂不可用，可重试检测');
      AppLogs.shared.add(LogLevel.error, '取流', '画质检测失败', error: e);
    }
  }

  Future<void> retryQuality() async {
    if (loading || busy || drama == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      await checkQuality(
        drama!.episodes.firstWhere(
          (e) => selected.contains(e.number),
          orElse: () => drama!.episodes.first,
        ),
      );
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void toggle(int number) {
    if (busy || loading) return;
    selected.contains(number) ? selected.remove(number) : selected.add(number);
    notifyListeners();
  }

  void selectAll(bool all) {
    if (busy || loading) return;
    selected.clear();
    if (all && drama != null) {
      selected.addAll(drama!.episodes.map((e) => e.number));
    }
    notifyListeners();
  }

  void selectEpisodes(Set<int> numbers) {
    if (busy || loading || drama == null) return;
    selected.clear();
    selected.addAll(
      drama!.episodes
          .where((e) => numbers.contains(e.number))
          .map((e) => e.number),
    );
    notifyListeners();
  }

  void selectRange(int first, int last) {
    if (busy ||
        loading ||
        drama == null ||
        first < 1 ||
        last < first ||
        last > drama!.episodes.length) {
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

  void setQuality(int value) {
    quality = value;
    notifyListeners();
  }

  void setNormalize(bool value) {
    normalize = value;
    _save();
    notifyListeners();
  }

  void setDirectory(String value) {
    outputDirectory = value;
    _save();
    notifyListeners();
  }

  void addFiles(List<String> paths) {
    for (final file in paths) {
      if (!localFiles.contains(file)) localFiles.add(file);
    }
    log('已导入 ${localFiles.length} 段本地素材，按列表顺序拼接');
  }

  void removeFile(int index) {
    if (!busy) {
      localFiles.removeAt(index);
      notifyListeners();
    }
  }

  void moveFile(int index, int delta) {
    final to = index + delta;
    if (busy || to < 0 || to >= localFiles.length) return;
    final file = localFiles.removeAt(index);
    localFiles.insert(to, file);
    notifyListeners();
  }

  Future<void> assemble({bool local = false}) async {
    if (busy || loading || outputDirectory.isEmpty) return;
    if (local
        ? localFiles.isEmpty
        : drama == null || selected.isEmpty || variants.isEmpty) {
      return;
    }
    busy = true;
    progress = 0;
    error = null;
    output = null;
    engine.reset();
    _save();
    notifyListeners();
    try {
      if (Platform.isAndroid) {
        await NativeRequestSigner.channel.invokeMethod('startTask');
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final folder = await Directory(outputDirectory).create(recursive: true);
      final rawTitle = local ? '本地合集' : drama!.title;
      final title = rawTitle
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
          .trim();
      final destination = p.join(
        folder.path,
        '${title.isEmpty ? '合集' : title}-$stamp.mp4',
      );
      final inputs = local ? [...localFiles] : <String>[];
      if (!local) {
        final episodes = drama!.episodes
            .where((e) => selected.contains(e.number))
            .toList();
        for (var i = 0; i < episodes.length; i++) {
          engine.checkCancelled();
          final episode = episodes[i];
          final wanted = chooseQuality(variants, quality).quality;
          final cacheDir = await Directory(
            p.join(folder.path, '.hongguo-cache', drama!.id, '$wanted'),
          ).create(recursive: true);
          final path = p.join(cacheDir.path, '${episode.id}.mp4');
          var cached = false;
          if (await File(path).exists()) {
            try {
              final metadata = await engine.probe(path);
              final streams = metadata['streams'] as List? ?? [];
              cached =
                  streams.any((s) => s['codec_type'] == 'video') &&
                  (double.tryParse(
                            '${(metadata['format'] as Map?)?['duration']}',
                          ) ??
                          0) >
                      0;
            } catch (_) {
              engine.checkCancelled();
            }
          }
          if (cached) {
            log('复用第 ${episode.number} 集 · 已下载');
          } else {
            for (var attempt = 1; attempt <= 3; attempt++) {
              try {
                engine.checkCancelled();
                log(
                  '解析第 ${episode.number} 集（${i + 1}/${episodes.length}）${attempt > 1 ? ' · 重试 $attempt/3' : ''}',
                );
                final options = await client.fetchVariants(
                  episode,
                  seriesId: drama!.id,
                );
                engine.checkCancelled();
                final media = chooseQuality(options, wanted);
                if (media.quality != wanted) {
                  throw StateError(
                    '第 ${episode.number} 集缺少 ${wanted}P，请降低目标清晰度后重试',
                  );
                }
                log('下载第 ${episode.number} 集 · ${media.label}');
                await engine.download(media, path, (part) {
                  progress = (i + part) / episodes.length * .85;
                  notifyListeners();
                });
                break;
              } on JobCancelled {
                rethrow;
              } catch (_) {
                if (attempt == 3) rethrow;
                await Future<void>.delayed(Duration(seconds: attempt * 2));
              }
            }
          }
          inputs.add(path);
          progress = (i + 1) / episodes.length * .85;
          notifyListeners();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      engine.checkCancelled();
      log('正在校验素材并拼接导出…');
      final start = local ? 0.0 : .85;
      await engine.merge(
        inputs,
        destination,
        (part) {
          progress = start + part * (1 - start);
          notifyListeners();
        },
        normalize: normalize,
        onStatus: log,
      );
      output = destination;
      progress = 1;
      history.insert(0, {
        'title': rawTitle,
        'path': destination,
        'date': DateTime.now().toIso8601String(),
        'count': inputs.length,
      });
      watchHistory.record(WatchPoint(title: rawTitle, path: destination));
      log('导出完成 · ${p.basename(destination)}');
    } on JobCancelled {
      log('任务已取消，已下载分集保留，下次可直接继续');
    } catch (e) {
      error = friendlyError(e);
      log('任务未完成；已下载分集保留，可重新执行');
      AppLogs.shared.add(LogLevel.error, '任务', '拼接任务失败', error: e);
    } finally {
      if (Platform.isAndroid) {
        try {
          await NativeRequestSigner.channel.invokeMethod('stopTask');
        } catch (_) {}
      }
      busy = false;
      await flush();
      notifyListeners();
    }
  }

  Future<void> cancel() async {
    log('正在取消任务…');
    await engine.cancel();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _disposed = true;
    watchHistory.removeListener(notifyListeners);
    watchHistory.dispose();
    client.close();
    super.dispose();
  }
}

String friendlyError(Object error) {
  if (error is VisitorInitializationException) return error.toString();
  if (error is StateError) return error.message.toString();
  if (error is TimeoutException || error is SocketException) {
    return '网络连接超时，请检查网络后重试。已下载分集会保留。';
  }
  if (error is FileSystemException) return '无法读写文件，请检查目录权限与剩余空间。';
  if (error is PlatformException) return error.message ?? '系统操作未完成，请重试。';
  if (error is FormatException) return '链接或来源数据格式异常，请检查输入或稍后重试。';
  return '操作未完成，请检查网络和素材后重试。';
}
