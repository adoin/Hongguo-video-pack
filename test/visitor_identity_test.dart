import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hongguo_studio/data/visitor_identity.dart';

void main() {
  late Directory directory;
  late File profile;
  setUp(() async {
    final base = Platform.isWindows
        ? Directory('D:/tmp/hongputao-visitor-tests')
        : Directory.systemTemp;
    await base.create(recursive: true);
    directory = await base.createTemp('identity-');
    profile = File('${directory.path}/visitor.json');
  });
  tearDown(() async => directory.delete(recursive: true));
  http.Response registered(int n) => http.Response(
    jsonEncode({
      'device_id_str': '100000000000000$n',
      'install_id_str': '200000000000000$n',
    }),
    200,
  );

  test('registration envelope matches an independent protocol vector', () {
    expect(
      base64Encode(
        encodeVisitorRegistration(
          utf8.encode('{}'),
          seed: List.generate(32, (i) => i),
        ),
      ),
      'dGMFEAAAAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh80Zmw8N0/YPCOVtrT2/+/E8HScZMo5injmTjf/aH8fVk+D/l7PB6wGVWrK+0swnUQ4OI6O3ZsiMKWP02HvNYXyx9CqmAXE/lN82SjE2dmjTsqKFQP9u5ttwPkhmfUiAVU=',
    );
  });

  test(
    'concurrent callers register once and restart reuses the local identity',
    () async {
      var calls = 0;
      final response = Completer<http.Response>();
      final store = VisitorIdentityStore(
        file: () async => profile,
        client: MockClient((r) async {
          calls++;
          expect(r.url.host, 'log5-applog.fqnovel.com');
          expect(r.headers['log-encode-type'], 'gzip');
          expect(r.bodyBytes.take(6), [0x74, 0x63, 5, 16, 0, 0]);
          return response.future;
        }),
      );
      final results = List.generate(5, (_) => store.get());
      response.complete(registered(1));
      final visitors = await Future.wait(results);
      expect(calls, 1);
      expect(visitors.every((v) => identical(v, visitors.first)), isTrue);
      final restarted = VisitorIdentityStore(
        file: () async => profile,
        client: MockClient((_) async => throw StateError('Must use disk')),
      );
      expect((await restarted.get()).deviceId, visitors.first.deviceId);
    },
  );

  test('failed registration preserves disk and can be retried', () async {
    await profile.writeAsString('{invalid old profile');
    var calls = 0;
    final store = VisitorIdentityStore(
      file: () async => profile,
      client: MockClient(
        (_) async => ++calls <= 2
            ? http.Response('{"device_id":0,"install_id":0}', 200)
            : registered(2),
      ),
    );
    await expectLater(
      store.get(),
      throwsA(isA<VisitorInitializationException>()),
    );
    expect(await profile.readAsString(), '{invalid old profile');
    expect((await store.get()).deviceId, '1000000000000002');
    expect(calls, 3);
  });

  test(
    'concurrent stale rejections rebuild once without discarding the replacement',
    () async {
      var calls = 0;
      final store = VisitorIdentityStore(
        file: () async => profile,
        client: MockClient((_) async => registered(++calls)),
      );
      final old = await store.get();
      final refreshed = await Future.wait(
        List.generate(4, (_) => store.get(rejected: old)),
      );
      expect(calls, 2);
      expect(refreshed.every((v) => v.deviceId == '1000000000000002'), isTrue);
      expect((await store.get(rejected: old)).deviceId, '1000000000000002');
      expect(calls, 2);
    },
  );

  test(
    'registration 403 is not retried and never writes a fake identity',
    () async {
      var calls = 0;
      final store = VisitorIdentityStore(
        file: () async => profile,
        client: MockClient((_) async {
          calls++;
          return http.Response('', 403);
        }),
      );
      await expectLater(
        store.get(),
        throwsA(isA<VisitorInitializationException>()),
      );
      expect(calls, 1);
      expect(await profile.exists(), isFalse);
    },
  );
}
