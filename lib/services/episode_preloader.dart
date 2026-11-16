import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../domain/drama.dart';

class PreloadedEpisode {
  PreloadedEpisode(this.media, this.directory);
  final MediaVariant media;
  final Directory directory;
  Future<void> dispose() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        return;
      } catch (_) {
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  }
}

/// Owns only application-created temporary episode directories, never exports.
class EpisodePreloader {
  EpisodePreloader({required this.directory, http.Client Function()? client})
    : _clientFactory = client ?? (() => http.Client());
  final Future<Directory> Function() directory;
  final http.Client Function() _clientFactory;
  http.Client? _active;
  int _generation = 0;
  static const maxBytes = 64 * 1024 * 1024;
  String? lastFailure;
  bool mediaLinkRejected = false;
  bool retryable = true;
  Completer<void>? _abort;
  void cancel() {
    _generation++;
    if (_abort?.isCompleted == false) _abort!.complete();
    _active?.close();
    _active = null;
  }

  Future<PreloadedEpisode?> load(MediaVariant media) async {
    cancel();
    lastFailure = null;
    mediaLinkRejected = false;
    retryable = true;
    final generation = _generation;
    final uri = Uri.tryParse(media.url);
    if (uri == null || !{'http', 'https'}.contains(uri.scheme)) return null;
    Directory? temporary;
    IOSink? sink;
    Timer? deadline;
    final client = _clientFactory();
    final abort = Completer<void>();
    _abort = abort;
    _active = client;
    try {
      final root = await directory();
      await root.create(recursive: true);
      // Recover only our abandoned temporary folders after a prior crash.
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory &&
            p.basename(entity.path).startsWith('next-')) {
          try {
            if (DateTime.now()
                    .difference(await entity.stat().then((s) => s.modified))
                    .inHours >=
                24) {
              await entity.delete(recursive: true);
            }
          } catch (_) {}
        }
      }
      if (generation != _generation) return null;
      temporary = await root.createTemp('next-');
      final file = File(p.join(temporary.path, 'episode.mp4'));
      deadline = Timer(const Duration(seconds: 60), () {
        if (generation == _generation) lastFailure = '缓存下载超时';
        if (!abort.isCompleted) abort.complete();
        client.close();
      });
      final response = await client
          .send(
            http.AbortableRequest('GET', uri, abortTrigger: abort.future)
              ..headers.addAll({
                'Referer': 'https://novel.snssdk.com/',
                'Accept-Encoding': 'identity',
              }),
          )
          .timeout(const Duration(seconds: 20));
      if (generation != _generation) return null;
      final type = response.headers['content-type'] ?? '';
      if ({401, 403, 404, 410}.contains(response.statusCode) ||
          type.startsWith('text/html') ||
          type.startsWith('application/json')) {
        mediaLinkRejected = true;
        lastFailure = '媒体地址失效或返回无效内容';
        return null;
      }
      int? expected =
          response.headers['content-encoding'] == null ||
              response.headers['content-encoding'] == 'identity'
          ? response.contentLength
          : null;
      if (response.statusCode == 206) {
        final range = RegExp(
          r'^bytes 0-(\d+)/(\d+)$',
        ).firstMatch(response.headers['content-range'] ?? '');
        if (range == null || int.parse(range[1]!) + 1 != int.parse(range[2]!)) {
          lastFailure = '服务器只返回部分数据';
          return null;
        }
        expected = int.parse(range[2]!);
      }
      if (!{200, 206}.contains(response.statusCode) ||
          (response.contentLength ?? 0) > maxBytes) {
        lastFailure = '缓存响应不可用或超过大小限制';
        if ((response.contentLength ?? 0) > maxBytes) retryable = false;
        return null;
      }
      sink = file.openWrite();
      var bytes = 0;
      final watch = Stopwatch()..start();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        if (generation != _generation ||
            watch.elapsed > const Duration(seconds: 60)) {
          return null;
        }
        bytes += chunk.length;
        if (bytes > maxBytes) {
          lastFailure = '媒体超过缓存大小限制';
          retryable = false;
          return null;
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (generation != _generation ||
          bytes == 0 ||
          (expected != null && bytes != expected)) {
        if (generation == _generation) lastFailure = '缓存下载不完整';
        return null;
      }
      final result = PreloadedEpisode(
        MediaVariant(
          url: file.uri.toString(),
          quality: media.quality,
          codec: media.codec,
          key: media.key,
          duration: media.duration,
          source: media.source,
          width: media.width,
          height: media.height,
          rotation: media.rotation,
          sizeBytes: bytes,
        ),
        temporary,
      );
      temporary =
          null; // Ownership transfers to playback until the demuxer stops.
      return result;
    } catch (_) {
      if (generation == _generation) lastFailure ??= '缓存连接中断';
      return null;
    } finally {
      deadline?.cancel();
      if (!abort.isCompleted) abort.complete();
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
      if (identical(_active, client)) _active = null;
      if (temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}
