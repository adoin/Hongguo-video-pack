import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hongguo_studio/domain/drama.dart';
import 'package:hongguo_studio/playback_controller.dart';
import 'package:hongguo_studio/app_controller.dart';
import 'package:hongguo_studio/services/episode_preloader.dart';
import 'playback_controller_test.dart'
    show FakePlaybackEngine, FakePlaybackClient;

class WarmFake extends EpisodePreloader {
  WarmFake(this.result) : super(directory: () async => Directory('unused'));
  final PreloadedEpisode? result;
  int calls = 0;
  @override
  Future<PreloadedEpisode?> load(MediaVariant media) async {
    calls++;
    return result;
  }
}

class PendingWarm extends EpisodePreloader {
  PendingWarm() : super(directory: () async => Directory('unused'));
  final result = Completer<PreloadedEpisode?>();
  @override
  Future<PreloadedEpisode?> load(MediaVariant media) => result.future;
}

void main() {
  late Directory root;
  setUp(() async {
    final base = Directory(
      Platform.isWindows
          ? 'D:/tmp/hongputao-preload-tests'
          : '${Directory.systemTemp.path}/hongputao-preload-tests',
    );
    await base.create(recursive: true);
    root = await base.createTemp('case-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'preload preference persists independently of playback lifetime',
    () async {
      final store = File('${root.path}/workspace.json');
      final c = StudioController();
      await c.initialize(store, '${root.path}/exports');
      c.setPreloadNext(false);
      await c.flush();
      c.dispose();
      final restored = StudioController();
      addTearDown(restored.dispose);
      await restored.initialize(store, '${root.path}/exports');
      expect(restored.preloadNext, isFalse);
    },
  );

  test('cancelled partial network media is removed', () async {
    final stream = StreamController<List<int>>();
    final started = Completer<void>();
    final preloader = EpisodePreloader(
      directory: () async => root,
      client: () => MockClient.streaming((_, _) async {
        started.complete();
        return http.StreamedResponse(stream.stream, 200, contentLength: 8);
      }),
    );
    final download = preloader.load(
      const MediaVariant(
        url: 'https://example.com/clip',
        quality: 720,
        codec: 'h264',
      ),
    );
    await started.future;
    stream.add([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);
    preloader.cancel();
    await stream.close();
    expect(await download, isNull);
    expect(await root.list().isEmpty, isTrue);
  });

  test(
    '80 percent prepares one next episode, reuses it and releases after switching',
    () async {
      final cache = await Directory('${root.path}/next').create();
      final file = await File(
        '${cache.path}/episode.mp4',
      ).writeAsBytes([1, 2, 3]);
      final preloader = WarmFake(
        PreloadedEpisode(
          MediaVariant(url: file.uri.toString(), quality: 1080, codec: 'hevc'),
          cache,
        ),
      );
      final source = FakePlaybackClient(), engine = FakePlaybackEngine();
      final c = PlaybackController(
        engine: engine,
        client: source,
        preloader: preloader,
      );
      addTearDown(c.dispose);
      await c.load('123');
      c.onProgress(const Duration(seconds: 79), const Duration(seconds: 100));
      expect(preloader.calls, 0);
      c.onProgress(const Duration(seconds: 80), const Duration(seconds: 100));
      c.onProgress(const Duration(seconds: 90), const Duration(seconds: 100));
      await Future<void>.delayed(Duration.zero);
      expect(preloader.calls, 1);
      await c.play(1);
      expect(engine.opened.last.url, file.uri.toString());
      expect(source.calls.where((id) => id == '2').length, 1);
      expect(await file.exists(), isTrue);
      await c.play(2);
      expect(await cache.exists(), isFalse);
    },
  );

  test('disabled or failed preloading does not disturb playback', () async {
    final preloader = WarmFake(null);
    final c = PlaybackController(
      engine: FakePlaybackEngine(),
      client: FakePlaybackClient(),
      preloader: preloader,
    );
    addTearDown(c.dispose);
    await c.load('123');
    c.setPreloadNext(false);
    c.onProgress(const Duration(seconds: 90), const Duration(seconds: 100));
    await Future<void>.delayed(Duration.zero);
    expect(preloader.calls, 0);
    c.setPreloadNext(true);
    c.onProgress(const Duration(seconds: 90), const Duration(seconds: 100));
    await Future<void>.delayed(Duration.zero);
    expect(preloader.calls, 1);
    expect(c.error, isNull);
    await c.play(1);
    expect(c.error, isNull);
  });

  test(
    'downloads encrypted bytes intact and preserves per-episode key',
    () async {
      final preloader = EpisodePreloader(
        directory: () async => root,
        client: () =>
            MockClient((_) async => http.Response.bytes([1, 2, 3, 4], 200)),
      );
      final result = await preloader.load(
        const MediaVariant(
          url: 'https://example.com/clip',
          quality: 1080,
          codec: 'hevc',
          key: '0123456789abcdef0123456789abcdef',
        ),
      );
      expect(result, isNotNull);
      expect(await File.fromUri(Uri.parse(result!.media.url)).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      expect(result.media.key, '0123456789abcdef0123456789abcdef');
      await result.dispose();
      expect(await root.list().isEmpty, isTrue);
    },
  );

  test('oversize content never stays in cache', () async {
    final preloader = EpisodePreloader(
      directory: () async => root,
      client: () => MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          const Stream.empty(),
          200,
          contentLength: EpisodePreloader.maxBytes + 1,
        ),
      ),
    );
    expect(
      await preloader.load(
        const MediaVariant(
          url: 'https://example.com/clip',
          quality: 720,
          codec: 'h264',
        ),
      ),
      isNull,
    );
    expect(await root.list().isEmpty, isTrue);
  });
  test(
    'a rejected media URL is refreshed rather than reused at switching',
    () async {
      final source = FakePlaybackClient();
      final warm = EpisodePreloader(
        directory: () async => root,
        client: () => MockClient((_) async => http.Response('', 403)),
      );
      final c = PlaybackController(
        engine: FakePlaybackEngine(),
        client: source,
        preloader: warm,
      );
      addTearDown(c.dispose);
      await c.load('123');
      final finished = Completer<void>();
      c.addListener(() {
        if (!c.preloading &&
            source.calls.contains('2') &&
            !finished.isCompleted) {
          finished.complete();
        }
      });
      c.onProgress(const Duration(seconds: 90), const Duration(seconds: 100));
      await finished.future.timeout(const Duration(seconds: 3));
      expect(warm.mediaLinkRejected, isTrue);
      expect(c.playbackInfoReady, isFalse);
      await c.play(1);
      expect(source.calls.where((id) => id == '2').length, 2);
    },
  );
  test(
    'a complete 206 response is reusable but a partial response is not',
    () async {
      for (final complete in [true, false]) {
        final preloader = EpisodePreloader(
          directory: () async => root,
          client: () => MockClient(
            (_) async => http.Response.bytes(
              [1, 2, 3, 4],
              206,
              headers: {
                'content-range': complete ? 'bytes 0-3/4' : 'bytes 0-3/8',
              },
            ),
          ),
        );
        final result = await preloader.load(
          const MediaVariant(
            url: 'https://example.com/clip',
            quality: 720,
            codec: 'h264',
            width: 720,
            height: 1280,
          ),
        );
        if (complete) {
          expect(result, isNotNull);
          expect(result!.media.aspectRatio, 720 / 1280);
          await result.dispose();
        } else {
          expect(result, isNull);
          expect(preloader.lastFailure, isNotNull);
        }
      }
    },
  );
  test(
    'failed downloads retain resolved media and only retry up to twice',
    () async {
      final warm = WarmFake(null), source = FakePlaybackClient();
      final c = PlaybackController(
        engine: FakePlaybackEngine(),
        client: source,
        preloader: warm,
        preloadRetryDelay: Duration.zero,
      );
      addTearDown(c.dispose);
      await c.load('123');
      for (var i = 0; i < 3; i++) {
        c.onProgress(const Duration(seconds: 90), const Duration(seconds: 100));
        await Future<void>.delayed(Duration.zero);
      }
      expect(warm.calls, 2);
      expect(c.playbackInfoReady, isTrue);
      final requests = source.calls.where((id) => id == '2').length;
      await c.play(1);
      expect(source.calls.where((id) => id == '2').length, requests);
    },
  );
  test(
    'switching joins an in-flight next-episode preload instead of discarding it',
    () async {
      final directory = await Directory('${root.path}/join').create();
      final file = await File(
        '${directory.path}/episode.mp4',
      ).writeAsBytes([1, 2, 3]);
      final warm = PendingWarm(),
          engine = FakePlaybackEngine(),
          source = FakePlaybackClient();
      final c = PlaybackController(
        engine: engine,
        client: source,
        preloader: warm,
      );
      addTearDown(c.dispose);
      await c.load('123');
      c.onProgress(const Duration(seconds: 90), const Duration(seconds: 100));
      await Future<void>.delayed(Duration.zero);
      final change = c.play(1);
      warm.result.complete(
        PreloadedEpisode(
          MediaVariant(url: file.uri.toString(), quality: 1080, codec: 'hevc'),
          directory,
        ),
      );
      await change;
      expect(engine.opened.last.url, file.uri.toString());
      expect(source.calls.where((id) => id == '2').length, 1);
      await c.play(2);
    },
  );
}
