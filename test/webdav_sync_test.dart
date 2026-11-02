import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hongguo_studio/watch_history.dart';
import 'package:hongguo_studio/services/webdav_sync.dart';

class MemoryCredentials implements SyncCredentialStore {
  WebDavConfig? value;
  @override
  Future<WebDavConfig?> read() async => value;
  @override
  Future<void> write(WebDavConfig config) async {
    value = config;
  }
}

const config = WebDavConfig(
  url: 'https://dav.example/root/',
  username: 'test',
  password: 'secret',
  enabled: true,
  automatic: false,
);

void main() {
  test('invalid sync settings cannot partially apply deletions', () {
    final history = WatchHistory();
    addTearDown(history.dispose);
    history.record(WatchPoint(title: '保留', dramaId: '9'));
    final original = history.syncSnapshot();
    final key = history.entries.single.key;
    expect(
      () => history.mergeSync({
        ...original,
        'limitUpdated': 42,
        'deleted': {
          key: DateTime.now().add(const Duration(days: 1)).toIso8601String(),
        },
      }),
      throwsFormatException,
    );
    expect(history.onlineFor('9'), isNotNull);
    expect(history.syncSnapshot(), original);
  });
  test(
    'same local path on unrelated devices does not identify the same video',
    () {
      final a = WatchHistory(), b = WatchHistory();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      a.record(WatchPoint(title: '本地合集', path: r'C:\videos\movie.mp4'));
      b.record(WatchPoint(title: '本地合集', path: r'C:\videos\movie.mp4'));
      expect(a.entries.single.key, isNot(b.entries.single.key));
      a.mergeSync(b.syncSnapshot());
      expect(a.entries.length, 2);
    },
  );
  test('equal-timestamp updates converge on both devices', () {
    final date = DateTime.utc(2026, 11, 2);
    final a = WatchHistory(now: () => date), b = WatchHistory(now: () => date);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    a.record(WatchPoint(title: '同名', dramaId: '4', positionMs: 100));
    b.record(WatchPoint(title: '同名', dramaId: '4', positionMs: 900));
    final left = a.syncSnapshot(), right = b.syncSnapshot();
    a.mergeSync(right);
    b.mergeSync(left);
    expect(a.onlineFor('4')!.positionMs, b.onlineFor('4')!.positionMs);
  });
  test(
    'real HTTP WebDAV round trip synchronizes two independent clients',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? document;
      var version = 0;
      server.listen((request) async {
        if (request.headers.value('Authorization') !=
            'Basic ${base64Encode(utf8.encode('user:pass'))}') {
          request.response.statusCode = 401;
          await request.response.close();
          return;
        }
        if (request.method == 'MKCOL') {
          request.response.statusCode = 201;
        } else if (request.method == 'GET') {
          if (document == null) {
            request.response.statusCode = 404;
          } else {
            request.response.headers.set('ETag', '"$version"');
            request.response.write(document);
          }
        } else if (request.method == 'PUT') {
          final body = await utf8.decoder.bind(request).join();
          final match = request.headers.value('If-Match');
          if (document != null && match != '"$version"') {
            request.response.statusCode = 412;
          } else {
            document = body;
            version++;
            request.response.statusCode = 201;
          }
        } else {
          request.response.statusCode = 405;
        }
        await request.response.close();
      });
      final a = WatchHistory(), b = WatchHistory();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final first = WebDavSync(history: a, credentials: MemoryCredentials()),
          second = WebDavSync(history: b, credentials: MemoryCredentials());
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final endpoint = WebDavConfig(
        url: 'http://127.0.0.1:${server.port}/dav/',
        username: 'user',
        password: 'pass',
        enabled: true,
        automatic: false,
      );
      await first.initialize();
      await second.initialize();
      await first.save(endpoint);
      await second.save(endpoint);
      a.record(
        WatchPoint(title: '真实网络', dramaId: '8', episode: 9, positionMs: 12345),
      );
      await first.sync();
      expect(first.error, isNull);
      await second.sync();
      expect(second.error, isNull);
      expect(b.onlineFor('8')!.positionMs, 12345);
      expect(b.onlineFor('8')!.episode, 9);
    },
  );
  test(
    'two devices merge progress, deletions, limits and portable local records',
    () async {
      var now = DateTime.utc(2026, 11, 2);
      final a = WatchHistory(now: () => now), b = WatchHistory(now: () => now);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      a.record(
        WatchPoint(title: '故事第一季', dramaId: '1', episode: 2, positionMs: 4000),
      );
      a.record(
        WatchPoint(
          title: '本地合集',
          path: r'C:\private\movie.mp4',
          positionMs: 5000,
        ),
      );
      final snapshot = a.syncSnapshot();
      expect(jsonEncode(snapshot), isNot(contains('private')));
      b.mergeSync(snapshot);
      final local = b.entries.firstWhere((e) => e.current.local).current;
      expect(local.path, isEmpty);
      expect(local.positionMs, 5000);
      await b.pruneMissing(); // A remote file is unavailable, not deleted here.
      expect(b.entries.length, 2);
      now = now.add(const Duration(seconds: 1));
      b.linkFile(local, '/local/movie.mp4');
      b.record(
        WatchPoint(title: '故事第一季', dramaId: '1', episode: 3, positionMs: 10000),
      );
      b.setLimit(75);
      a.mergeSync(b.syncSnapshot());
      expect(a.onlineFor('1')!.episode, 3);
      expect(a.limit, 75);
      expect(
        a.entries.firstWhere((e) => e.current.local).current.path,
        r'C:\private\movie.mp4',
      );
      now = now.add(const Duration(seconds: 1));
      await a.remove(a.entries.firstWhere((e) => e.online != null).key);
      b.mergeSync(a.syncSnapshot());
      expect(b.onlineFor('1'), isNull);
      b.mergeSync(snapshot);
      expect(b.onlineFor('1'), isNull);
    },
  );

  test(
    'conflicting cloud writes refetch and merge rather than overwrite',
    () async {
      var now = DateTime.utc(2026, 11, 2);
      final history = WatchHistory(now: () => now),
          remote = WatchHistory(now: () => now);
      addTearDown(history.dispose);
      addTearDown(remote.dispose);
      history.record(WatchPoint(title: '本机', dramaId: '1'));
      remote.record(WatchPoint(title: '云端', dramaId: '2'));
      var tag = 1, puts = 0;
      Map<String, dynamic>? uploaded;
      final sync = WebDavSync(
        history: history,
        credentials: MemoryCredentials(),
        client: MockClient((r) async {
          expect(r.followRedirects, isFalse);
          expect(
            r.headers['Authorization'],
            'Basic ${base64Encode(utf8.encode('test:secret'))}',
          );
          if (r.method == 'MKCOL') return http.Response('', 405);
          if (r.method == 'GET') {
            return http.Response(
              jsonEncode(remote.syncSnapshot()),
              200,
              headers: {
                'etag': '"$tag"',
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }
          expect(r.method, 'PUT');
          expect(r.headers['If-Match'], '"$tag"');
          if (++puts == 1) {
            now = now.add(const Duration(seconds: 1));
            remote.record(WatchPoint(title: '并发更新', dramaId: '3'));
            tag++;
            return http.Response('', 412);
          }
          uploaded = jsonDecode(r.body) as Map<String, dynamic>;
          return http.Response('', 204);
        }),
      );
      addTearDown(sync.dispose);
      await sync.initialize();
      await sync.save(config);
      await sync.sync();
      expect(sync.error, isNull);
      expect(puts, 2);
      expect((uploaded!['entries'] as List).length, 3);
      expect(history.entries.length, 3);
    },
  );

  test(
    'bad cloud data is not uploaded and does not change local progress',
    () async {
      final history = WatchHistory();
      addTearDown(history.dispose);
      history.record(WatchPoint(title: '保留', dramaId: '1', positionMs: 1234));
      var puts = 0;
      final sync = WebDavSync(
        history: history,
        credentials: MemoryCredentials(),
        client: MockClient((r) async {
          if (r.method == 'MKCOL') return http.Response('', 201);
          if (r.method == 'PUT') {
            puts++;
            return http.Response('', 204);
          }
          return http.Response(
            '{"version":999,"entries":[]}',
            200,
            headers: {'etag': '"1"'},
          );
        }),
      );
      addTearDown(sync.dispose);
      await sync.initialize();
      await sync.save(config);
      await sync.sync();
      expect(sync.error, isNotNull);
      expect(puts, 0);
      expect(history.onlineFor('1')!.positionMs, 1234);
    },
  );

  test('record changes during upload are scheduled again', () async {
    final history = WatchHistory();
    addTearDown(history.dispose);
    final started = Completer<void>(), finish = Completer<void>();
    var puts = 0;
    final credentials = MemoryCredentials();
    final sync = WebDavSync(
      history: history,
      credentials: credentials,
      delay: const Duration(milliseconds: 5),
      client: MockClient((r) async {
        if (r.method == 'MKCOL') return http.Response('', 201);
        if (r.method == 'GET') return http.Response('', 404);
        expect(r.headers['If-None-Match'], '*');
        puts++;
        if (puts == 1) {
          started.complete();
          await finish.future;
        }
        return http.Response('', 201);
      }),
    );
    addTearDown(sync.dispose);
    await sync.initialize();
    await sync.save(
      const WebDavConfig(url: 'https://dav.example/root/', enabled: true),
    );
    await started.future;
    history.record(WatchPoint(title: '上传时新进度', dramaId: '7', positionMs: 7000));
    finish.complete();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(puts, 2);
    expect(sync.error, isNull);
  });

  test(
    'custom limit persists and existing media records survive trimming',
    () async {
      final base = Platform.isWindows
          ? Directory('D:/tmp/hongputao-webdav-tests')
          : Directory.systemTemp;
      await base.create(recursive: true);
      final dir = await base.createTemp('limit-');
      addTearDown(() => dir.delete(recursive: true));
      final history = WatchHistory();
      addTearDown(history.dispose);
      final file = File('${dir.path}/video.mp4');
      await file.writeAsString('sample');
      final store = File('${dir.path}/history.json');
      await history.initialize(store);
      history.record(WatchPoint(title: '本地合集', path: file.path));
      for (var i = 0; i < 5; i++) {
        history.record(
          WatchPoint(title: '故事$i', dramaId: '$i', watched: i == 4),
        );
      }
      history.setLimit(2);
      await history.flush();
      expect(history.entries.where((e) => !e.protected).length, 2);
      expect(history.fileFor(file.path), isNotNull);
      expect(history.onlineFor('4'), isNull);
      final restarted = WatchHistory();
      addTearDown(restarted.dispose);
      await restarted.initialize(store);
      expect(restarted.limit, 2);
      await restarted.flush();
    },
  );
}
