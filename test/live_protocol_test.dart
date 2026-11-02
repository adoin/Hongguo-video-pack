import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/data/hongguo_client.dart';
import 'package:hongguo_studio/data/visitor_identity.dart';
import 'package:hongguo_studio/services/episode_preloader.dart';
import 'support/cli_signer.dart';

void main() {
  test(
    'live multi-video protocol returns a usable media variant',
    () async {
      final base = Platform.isWindows
          ? Directory('D:/tmp/hongputao-visitor-tests')
          : Directory.systemTemp;
      await base.create(recursive: true);
      final folder = await base.createTemp('live-');
      final client = HongguoClient(
        signer: CliSigner(),
        identities: VisitorIdentityStore(
          file: () async => File('${folder.path}/visitor.json'),
        ),
      );
      try {
        final drama = await client.fetchDrama('7671966197985856536');
        final variants = await client.fetchVariants(
          drama.episodes.first,
          seriesId: drama.id,
        );
        expect(drama.episodes.length, 100);
        expect(
          variants.any(
            (v) => v.quality == 1080 && v.downloadable && v.key?.length == 32,
          ),
          isTrue,
        );
        expect(variants.first.duration, greaterThan(100));
        if (Platform.environment['HONGGUO_LIVE_MEDIA_TEST'] == '1') {
          final preloader = EpisodePreloader(
            directory: () async => Directory('${folder.path}/cache'),
          );
          final next = await client.fetchVariants(
            drama.episodes[1],
            seriesId: drama.id,
          );
          final cached = await preloader.load(next.first);
          expect(cached, isNotNull);
          final media = cached!.media;
          final bytes = await File.fromUri(Uri.parse(media.url)).length();
          var decoded = 0.0;
          try {
            final process = await Process.start(
              Platform.environment['HONGGUO_FFMPEG']!,
              [
                '-hide_banner',
                '-loglevel',
                'error',
                '-nostdin',
                '-threads',
                '2',
                if (media.key != null) ...['-decryption_key', media.key!],
                '-i',
                File.fromUri(Uri.parse(media.url)).path,
                '-t',
                '2',
                '-map',
                '0:v:0',
                '-map',
                '0:a:0?',
                '-threads',
                '2',
                '-progress',
                'pipe:1',
                '-f',
                'null',
                '-',
              ],
            );
            final output = process.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .listen((line) {
                  if (line.startsWith('out_time_us=')) {
                    decoded =
                        (double.tryParse(line.split('=').last) ?? 0) / 1000000;
                  }
                });
            final errors = process.stderr.drain<void>();
            expect(
              await process.exitCode.timeout(const Duration(seconds: 30)),
              0,
            );
            await output.cancel();
            await errors;
            expect(decoded, greaterThanOrEqualTo(2));
            debugPrint(
              jsonEncode({
                'independentRegistration': true,
                'nextEpisodeBytes': bytes,
                'quality': media.quality,
                'decodedSeconds': decoded,
              }),
            );
          } on VisitorInitializationException catch (failure) {
            fail('Visitor initialization failed: ${failure.reason}');
          } finally {
            await cached.dispose();
            expect(await cached.directory.exists(), isFalse);
            preloader.cancel();
          }
        }
      } finally {
        client.close();
        await folder.delete(recursive: true);
      }
    },
    skip: Platform.environment['HONGGUO_LIVE_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
