import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:openhongguo/openhongguo.dart' as ohg;
import 'package:path/path.dart' as p;

import '../domain/drama.dart';
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
    try {
      final response = await client.resolvePlayback(episodeId);
      return (response.playback, response.contentKey?.key.toLowerCase());
    } on ohg.OpenhongguoException catch (error) {
      throw StateError('播放来源暂不可用（${error.code.wire}）');
    }
  }

  Future<(ohg.Playback, String?)> _windows(String episodeId) {
    final operation = _windowsQueue.then((_) => _windowsRequest(episodeId));
    _windowsQueue = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<(ohg.Playback, String?)> _windowsRequest(String episodeId) async {
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
    final child = await Process.start(helper.path, [episodeId, profile.path]);
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
      final reply = jsonDecode(utf8.decode(output)) as Map<String, dynamic>;
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
    } finally {
      child.kill();
      await errors;
    }
  }
}
