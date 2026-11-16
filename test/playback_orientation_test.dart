import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/data/hongguo_client.dart';
import 'package:hongguo_studio/playback_orientation.dart';

void main() {
  test(
    'actual source dimensions and rotation choose portrait or landscape fullscreen',
    () {
      for (final row in [
        (1080, 1920, 0, true),
        (1920, 1080, 0, false),
        (1920, 1080, 90, true),
      ]) {
        final media = parsePlaybackInfo({
          'video_list': [
            {
              'vwidth': row.$1,
              'vheight': row.$2,
              'rotation': row.$3,
              'codec_type': 'h264',
              'main_url': 'https://example.com/video',
            },
          ],
        }).single;
        expect(media.width, row.$1);
        expect(media.height, row.$2);
        final orientations = fullscreenOrientations(media.aspectRatio);
        expect(
          orientations,
          row.$4
              ? [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]
              : [
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ],
        );
      }
      expect(fullscreenOrientations(null), isEmpty);
      expect(fullscreenOrientations(1), isEmpty);
    },
  );
}
