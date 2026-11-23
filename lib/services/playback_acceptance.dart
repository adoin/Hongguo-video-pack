import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/hongguo_client.dart';
import '../data/discovery_client.dart';
import '../domain/drama.dart';
import 'playback_engine.dart';
import 'smoke_check.dart';

/// Real native renderer/decoder verification; no signed URLs or keys in reports.
Future<void> runPlaybackAcceptance() async {
  final directory = await Directory(
    '.local/playback-acceptance',
  ).create(recursive: true);
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'passed': false,
  };
  final engine = NativePlaybackEngine();
  final video = VideoController(engine.player);
  final client = HongguoClient();
  final discovery = DiscoveryClient();
  runApp(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: Video(controller: video)),
      ),
    ),
  );
  try {
    await engine.player.setVolume(0);
    final channel = discovery.theaterChannel;
    final first = await discovery.theater(channel, page: 1);
    if (first.items.isEmpty ||
        first.cursor == null ||
        !first.items.any(
          (item) => item.cover.isNotEmpty && item.firstEpisodeId.isNotEmpty,
        )) {
      throw StateError('剧场首屏缺少有效卡片或游标');
    }
    final next = await discovery.theater(
      channel,
      page: 2,
      cursor: first.cursor,
    );
    final seen = first.items.map((item) => item.id).toSet();
    final unique = next.items.where((item) => !seen.contains(item.id)).length;
    if (unique == 0) throw StateError('剧场分页未返回不同作品');
    report['theater'] = {'first': first.items.length, 'secondNew': unique};
    final drama = await client.fetchDrama('7697459724635098174');
    if (drama.episodes.length < 2) throw StateError('Insufficient episodes');
    final samples = <Map<String, dynamic>>[];
    for (final i in [0, 1, if (drama.episodes.length >= 4) 3]) {
      final media = chooseQuality(
        await client.fetchVariants(drama.episodes[i], seriesId: drama.id),
        1080,
      );
      await engine.open(media);
      await video.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 45),
      );
      if (engine.position.inSeconds < 2) {
        await engine.player.stream.position
            .firstWhere((p) => p.inSeconds >= 2)
            .timeout(const Duration(seconds: 35));
      }
      final frame = await engine.player.screenshot(format: 'image/png');
      if (frame == null ||
          frame.isEmpty ||
          (engine.player.state.width ?? 0) <= 0) {
        throw StateError('No decoded frame');
      }
      await File('${directory.path}/episode-${i + 1}.png').writeAsBytes(frame);
      samples.add({
        'episode': i + 1,
        'quality': media.quality,
        'width': engine.player.state.width,
        'height': engine.player.state.height,
        'seconds': engine.position.inSeconds,
        'frameBytes': frame.length,
      });
      if (i == 0) {
        await runNativeSmokeCheck();
        report['nativeEngineConcurrent'] = true;
        await engine.player.seek(const Duration(seconds: 15));
        await engine.player.stream.position
            .firstWhere((p) => p.inSeconds >= 14)
            .timeout(const Duration(seconds: 20));
        report['seek'] = true;
      }
    }
    report.addAll({'passed': true, 'samples': samples});
  } catch (_) {
    report['error'] = 'Native playback verification failed';
    rethrow;
  } finally {
    client.close();
    discovery.close();
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    await engine.dispose();
    await File(
      '${directory.path}/result.json',
    ).writeAsString(jsonEncode(report));
  }
}
