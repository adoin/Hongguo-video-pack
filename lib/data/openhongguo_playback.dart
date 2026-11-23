import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:openhongguo/openhongguo.dart' as ohg;
import 'package:path/path.dart' as p;

import '../domain/drama.dart';
import '../domain/discovery.dart';
import '../services/app_storage.dart';

/// Resolves media for the existing episode list. The application owns playback.
final class OpenHongguoPlayback {
  static final shared = OpenHongguoPlayback();
  static bool get isSupported => Platform.isAndroid || Platform.isWindows;

  Future<ohg.OpenhongguoClient>? _androidClient;
  Future<void> _windowsQueue = Future.value();

  Future<List<MediaVariant>> resolve(Episode episode) async {
    if (!RegExp(r'^\d{10,24}$').hasMatch(episode.id)) {
      throw const FormatException('分集标识无效');
    }
    final (model, key) = Platform.isAndroid
        ? await _android(episode.id)
        : await _windows(episode.id);
    final accepted = <int, MediaVariant>{};
    for (final stream in model.streams) {
      final encrypted = stream.protected || model.protected;
      final url = Uri.tryParse(stream.url);
      final quality =
          int.tryParse(
            stream.definition.toLowerCase().replaceFirst(RegExp(r'p$'), ''),
          ) ??
          math.min(stream.width, stream.height);
      if (quality <= 0 ||
          stream.dash ||
          const {'bytevc2', 'bvc2'}.contains(stream.codec) ||
          url == null ||
          url.scheme != 'https' ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty ||
          (encrypted &&
              (key == null || !RegExp(r'^[a-f0-9]{32}$').hasMatch(key)))) {
        continue;
      }
      accepted.putIfAbsent(
        quality,
        () => MediaVariant(
          url: url.toString(),
          key: encrypted ? key : null,
          quality: quality,
          codec: stream.codec == 'bytevc1' ? 'hevc' : stream.codec,
          duration: model.durationSeconds.toDouble(),
          width: stream.width,
          height: stream.height,
          sizeBytes: stream.size,
        ),
      );
    }
    if (accepted.isEmpty) throw StateError('该集暂未返回兼容画质，请稍后重试');
    return accepted.values.toList()
      ..sort((a, b) => b.quality.compareTo(a.quality));
  }

  Future<(ohg.Playback, String?)> _android(String episodeId) async {
    final client = await _androidSdk();
    try {
      final response = await client.resolvePlayback(episodeId);
      return (response.playback, response.contentKey?.key.toLowerCase());
    } on ohg.OpenhongguoException catch (error) {
      throw StateError('播放来源暂不可用（${error.code.wire}）');
    }
  }

  Future<ohg.OpenhongguoClient> _androidSdk() async {
    final opening = _androidClient ??= ohg.OpenhongguoClient.create(
      const ohg.ClientOptions(retryAttempts: 1, deviceResets: 0),
    );
    final ohg.OpenhongguoClient client;
    try {
      client = await opening;
    } catch (_) {
      if (identical(_androidClient, opening)) _androidClient = null;
      throw StateError('播放来源初始化失败，请重试');
    }
    return client;
  }

  Future<(ohg.Playback, String?)> _windows(String episodeId) async {
    final reply = await _windowsCall((profile) => [episodeId, profile]);
    final playback = reply['playback'];
    if (playback is! Map<String, dynamic>) {
      final reason = reply['failure'];
      final safe =
          reason is String && RegExp(r'^[a-z_]{1,32}$').hasMatch(reason);
      throw StateError('播放来源暂不可用（${safe ? reason : "model_unavailable"}）');
    }
    return (
      ohg.Playback.fromJson(playback),
      (reply['key'] as String?)?.toLowerCase(),
    );
  }

  Future<DiscoveryPage> discover(
    String channel, {
    String? cursor,
    required int page,
  }) async {
    if (cursor != null && cursor.length > 4096) {
      throw const FormatException('剧场分页游标无效');
    }
    Map<String, dynamic> feed;
    if (Platform.isAndroid) {
      final client = await _androidSdk();
      try {
        final result = await client.discover(
          ohg.DiscoverOptions(channel: channel, cursor: cursor ?? ''),
        );
        feed = {
          'items': result.items
              .map((item) => item.toJson())
              .toList(growable: false),
          'has_more': result.hasMore,
          'cursor': result.cursor,
        };
      } on ohg.OpenhongguoException catch (error) {
        throw StateError('剧场暂不可用（${error.code.wire}）');
      }
    } else if (Platform.isWindows) {
      final response = await _windowsCall(
        (profile) => ['discover', profile, channel, cursor ?? ''],
      );
      final value = response['feed'];
      if (value is! Map<String, dynamic>) throw StateError('剧场暂不可用，请刷新重试');
      feed = value;
    } else {
      throw UnsupportedError('当前平台不支持剧场');
    }
    return parseTheaterFeed(feed, page: page, previousCursor: cursor);
  }

  Future<Map<String, dynamic>> _windowsCall(
    List<String> Function(String profile) arguments,
  ) {
    final operation = _windowsQueue.then((_) => _windowsRequest(arguments));
    _windowsQueue = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<Map<String, dynamic>> _windowsRequest(
    List<String> Function(String profile) arguments,
  ) async {
    final dir = await appSupportDirectory();
    final profile = File(p.join(dir.path, 'data', 'playback-visitor.json'));
    await profile.parent.create(recursive: true);
    final helper = File(
      p.join(
        p.dirname(Platform.resolvedExecutable),
        'runtime',
        'openhongguo-playback.exe',
      ),
    );
    if (!await helper.exists()) throw StateError('缺少播放组件，请重新安装');
    final child = await Process.start(helper.path, arguments(profile.path));
    final errors = child.stderr.drain<void>();
    try {
      final output = await child.stdout
          .fold<List<int>>(<int>[], (bytes, chunk) {
            if (bytes.length + chunk.length > 256 * 1024) {
              throw const FormatException('播放组件响应超出限制');
            }
            return bytes..addAll(chunk);
          })
          .timeout(const Duration(seconds: 30));
      if (await child.exitCode.timeout(const Duration(seconds: 3)) != 0) {
        throw StateError('播放组件执行失败');
      }
      return jsonDecode(utf8.decode(output)) as Map<String, dynamic>;
    } finally {
      child.kill();
      await errors;
    }
  }
}

/// Catalog previews provide an initial episode hint, never a full episode list.
DiscoveryPage parseTheaterFeed(
  Map<String, dynamic> feed, {
  required int page,
  String? previousCursor,
}) {
  final raw = feed['items'];
  if (raw is! List) throw const FormatException('剧场响应格式无效');
  final ids = <String>{};
  final cards = <DramaSummary>[];
  final idPattern = RegExp(r'^\d{10,24}$');
  for (final row in raw) {
    if (row is! Map<String, dynamic>) continue;
    final id = row['id'];
    final title = row['title'];
    if (id is! String ||
        !idPattern.hasMatch(id) ||
        title is! String ||
        title.trim().isEmpty ||
        !ids.add(id)) {
      continue;
    }
    final cover = Uri.tryParse(row['cover_url'] as String? ?? '');
    final clip = row['vid'];
    final count = row['play_count'];
    cards.add(
      DramaSummary(
        id: id,
        title: title,
        cover:
            cover != null &&
                cover.scheme == 'https' &&
                cover.host.isNotEmpty &&
                cover.userInfo.isEmpty
            ? cover.toString()
            : '',
        intro: row['description'] as String? ?? '',
        episodes: row['episode_count'] as int? ?? 0,
        heat: row['rec_text'] as String? ?? '',
        plays: count is int && count > 0 ? '$count' : '',
        firstEpisodeId: clip is String && idPattern.hasMatch(clip) ? clip : '',
        vertical: row['vertical'] as bool?,
      ),
    );
  }
  final next = feed['cursor'];
  final cursor =
      feed['has_more'] == true &&
          next is String &&
          next.isNotEmpty &&
          next.length <= 4096 &&
          next != previousCursor
      ? next
      : null;
  return DiscoveryPage(
    cards,
    page: page,
    pages: cursor == null ? page : page + 1,
    totalPagesKnown: false,
    cursor: cursor,
  );
}
