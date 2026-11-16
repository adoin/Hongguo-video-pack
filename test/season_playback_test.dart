import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:hongguo_studio/app_controller.dart';
import 'package:hongguo_studio/playback_view.dart';
import 'package:hongguo_studio/data/hongguo_client.dart';
import 'package:hongguo_studio/domain/drama.dart';
import 'package:hongguo_studio/domain/discovery.dart';
import 'package:hongguo_studio/domain/series_titles.dart';
import 'package:hongguo_studio/playback_controller.dart';
import 'package:hongguo_studio/services/episode_preloader.dart';
import 'playback_controller_test.dart' show FakePlaybackEngine;
import 'preload_test.dart' show WarmFake;

class SeasonSource extends HongguoClient {
  final details = <String>[];
  final media = <String>[];
  @override
  Future<Drama> fetchDrama(String id) async {
    details.add(id);
    return Drama(
      id: id,
      title: id == '1' ? '故事第一季' : '故事第2季',
      episodes: [Episode('$id-1', 1), Episode('$id-2', 2)],
    );
  }

  @override
  Future<List<MediaVariant>> fetchVariants(
    Episode episode, {
    String? seriesId,
  }) async {
    media.add(episode.id);
    return [
      MediaVariant(
        url: 'https://example.com/${episode.id}',
        quality: 1080,
        codec: 'h264',
        width: 1080,
        height: 1920,
      ),
    ];
  }
}

void main() {
  test('background suspension does not complete a season transition', () async {
    final engine = FakePlaybackEngine();
    final c = PlaybackController(engine: engine, client: SeasonSource());
    addTearDown(c.dispose);
    await c.load('1', episode: 2);
    c.setNextSeason(const DramaSummary(id: '2', title: '故事第二季'));
    c.onProgress(const Duration(seconds: 95), const Duration(seconds: 100));
    c.suspendPreload();
    engine.end.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(c.drama!.id, '1');
    expect(c.nextSeasonSeconds, isNull);
    c.onProgress(const Duration(seconds: 99), const Duration(seconds: 100));
    engine.end.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(c.drama!.id, '2');
  });
  for (final size in [const Size(320, 700), const Size(800, 480)]) {
    testWidgets(
      'countdown is visible and cancellable without overflow at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = PlaybackController(
          engine: FakePlaybackEngine(),
          client: SeasonSource(),
        );
        final tasks = StudioController();
        addTearDown(c.dispose);
        addTearDown(tasks.dispose);
        await c.load('1', episode: 2);
        c.setNextSeason(const DramaSummary(id: '2', title: '故事第二季'));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
            theme: ThemeData(platform: TargetPlatform.android),
            home: PlaybackScreen(
              summary: const DramaSummary(id: '1', title: '故事第一季'),
              tasks: tasks,
              controller: c,
              videoBuilder: () => const ColoredBox(color: Colors.black),
              onStitch: (_, _, _) async => false,
              onTasks: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        c.onProgress(const Duration(seconds: 95), const Duration(seconds: 100));
        await tester.pumpAndSettle();
        expect(find.text('5 秒后播放下一季'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(c.nextSeasonSeconds, isNull);
        expect(c.drama!.id, '1');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  test(
    'only a matching immediately next season is eligible, in either numeral form',
    () {
      final title = SeriesTitle('故事第一季');
      expect(title.isNextSeason('故事第2季'), isTrue);
      expect(title.isNextSeason('故事第 二 季'), isTrue);
      expect(title.isNextSeason('故事第三季'), isFalse);
      expect(title.isNextSeason('故事番外第二季'), isFalse);
      expect(title.isNextSeason('故事第二部'), isFalse);
      expect(title.isNextSeason('故事第二季：预告'), isFalse);
      expect(SeriesTitle('故事第一季：雪').isNextSeason('故事第2季：雨'), isFalse);
      expect(SeriesTitle('故事第一季：雪').isNextSeason('故事第2季 雪'), isTrue);
      expect(title.isNextSeason('其他故事第二季'), isFalse);
      expect(SeriesTitle('故事第十一季').isNextSeason('故事第12季'), isTrue);
    },
  );
  test(
    'last five media seconds count down, reuse next-season cache, and start episode one',
    () async {
      final base = Platform.isWindows
          ? Directory('D:/tmp/hongputao-season-tests')
          : Directory.systemTemp;
      await base.create(recursive: true);
      final root = await base.createTemp('case-');
      final file = await File(
        '${root.path}/episode.mp4',
      ).writeAsBytes([1, 2, 3]);
      final warm = WarmFake(
        PreloadedEpisode(
          MediaVariant(url: file.uri.toString(), quality: 1080, codec: 'h264'),
          root,
        ),
      );
      final engine = FakePlaybackEngine(), source = SeasonSource();
      final c = PlaybackController(
        engine: engine,
        client: source,
        preloader: warm,
      );
      addTearDown(c.dispose);
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      await c.load('1', episode: 2);
      c.setNextSeason(const DramaSummary(id: '2', title: '故事第二季'));
      c.onProgress(const Duration(seconds: 80), const Duration(seconds: 100));
      await Future<void>.delayed(Duration.zero);
      expect(warm.calls, 1);
      expect(c.preloadReady, isTrue);
      expect(c.drama!.id, '1');
      c.onProgress(const Duration(seconds: 95), const Duration(seconds: 100));
      expect(c.nextSeasonSeconds, 5);
      c.onProgress(const Duration(seconds: 98), const Duration(seconds: 100));
      expect(c.nextSeasonSeconds, 2);
      final checkpoint = <String>[];
      c.onBeforeChange = () => checkpoint.add(c.drama!.id);
      final switched = Completer<void>();
      c.addListener(() {
        if (c.drama?.id == '2' && !c.loading && !switched.isCompleted) {
          switched.complete();
        }
      });
      c.onProgress(const Duration(seconds: 100), const Duration(seconds: 100));
      await switched.future.timeout(const Duration(seconds: 3));
      expect(c.index, 0);
      expect(engine.starts.last, Duration.zero);
      expect(engine.opened.last.url, file.uri.toString());
      expect(checkpoint.first, '1');
      expect(source.details.where((id) => id == '2').length, 1);
      expect(source.media.where((id) => id == '2-1').length, 1);
      await c.play(1);
    },
  );
  test(
    'cancelling countdown or disabling autoplay keeps the current season',
    () async {
      final engine = FakePlaybackEngine();
      final c = PlaybackController(engine: engine, client: SeasonSource());
      addTearDown(c.dispose);
      await c.load('1', episode: 2);
      c.setNextSeason(const DramaSummary(id: '2', title: '故事第二季'));
      c.onProgress(const Duration(seconds: 95), const Duration(seconds: 100));
      expect(c.nextSeasonSeconds, 5);
      c.cancelNextSeason();
      c.onProgress(const Duration(seconds: 100), const Duration(seconds: 100));
      engine.end.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(c.drama!.id, '1');
      await c.load('1', episode: 2);
      c.setNextSeason(const DramaSummary(id: '2', title: '故事第二季'));
      c.setAutoAdvance(false);
      c.onProgress(const Duration(seconds: 99), const Duration(seconds: 100));
      engine.end.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(c.nextSeasonSeconds, isNull);
      expect(c.drama!.id, '1');
    },
  );
}
