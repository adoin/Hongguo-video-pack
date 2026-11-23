import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/data/api_package.dart';
import 'package:hongguo_studio/data/discovery_client.dart';
import 'package:hongguo_studio/services/api_packages.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Uint8List packageBytes(String version, {String path = '/api/search/v2'}) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema': 1,
          'version': version,
          'search': {
            ...ApiPackage.bundled.search,
            'path': path,
            'keyword': 'q',
            'items': 'entries',
          },
          'recommendations': ApiPackage.bundled.recommendations,
          'playback': ['openhongguo', 'legacy'],
        }),
      ),
    );

ApiPackageDownload download(String version, {String? digest}) {
  final bytes = packageBytes(version);
  return (
    version: version,
    digest: digest ?? 'sha256:${sha256.convert(bytes)}',
    bytes: bytes,
  );
}

void main() {
  test(
    'invalid primary feed falls back to the second fixed HTTPS host',
    () async {
      final valid = download('1.0.0');
      final hosts = <String>[];
      final source = MockClient((request) async {
        hosts.add(request.url.host);
        expect(request.followRedirects, false);
        return http.Response(
          jsonEncode({
            'version': valid.version,
            'digest': hosts.length == 1 ? 'corrupted' : valid.digest,
            'body': base64Encode(valid.bytes),
          }),
          200,
        );
      });
      addTearDown(source.close);
      final result = await fetchStaticApiPackage(source, [
        'https://edge.example/feed.json',
        'https://vps.example/feed.json',
      ], '0.0.0');
      expect(result?.version, '1.0.0');
      expect(hosts, ['edge.example', 'vps.example']);
    },
  );

  test('package cannot choose a different web origin or a traversal path', () {
    for (final path in [
      'https://other.example/api',
      '//localhost/search',
      '/api/../x',
      '/api/%2E%2E',
    ]) {
      expect(
        () => ApiPackage.decode(packageBytes('1.0.0', path: path)),
        throwsFormatException,
      );
    }
    final rules = ApiPackage.decode(packageBytes('1.0.0'));
    final url = rules.searchUri('a&device_id=1', 2);
    expect(url.host, ApiPackage.webHost);
    expect(url.queryParameters, {
      'aid': '8662',
      'q': 'a&device_id=1',
      'page': '2',
    });
  });

  test(
    'verified package controls real web request construction and list parsing',
    () async {
      final rules = ApiPackage.decode(packageBytes('1.0.0'));
      final client = DiscoveryClient(
        apiPackage: () => rules,
        client: MockClient((request) async {
          expect(request.url.path, '/api/search/v2');
          expect(request.url.queryParameters['q'], '重生');
          expect(request.followRedirects, false);
          return http.Response(
            jsonEncode({
              'entries': [],
              'pageNum': 1,
              'totalPages': 1,
              'totalCount': 0,
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final result = await client.search('重生');
      expect(result.page, 1);
      expect(result.total, 0);
    },
  );

  test(
    'rejects wrong checksum and rollback, then starts offline with last verified rules',
    () async {
      final parent = Directory(
        Platform.environment['HONGPUTAO_TEST_TEMP'] ??
            Directory.systemTemp.path,
      );
      final folder = await parent.createTemp('api-package-');
      final file = File('${folder.path}/verified.json');
      addTearDown(() async {
        if (await file.exists()) await file.delete();
        await folder.delete();
      });
      var next = download('1.0.0');
      final store = ApiPackages(
        cache: () async => file,
        fetch: (_) async => next,
      );
      await store.initialize();
      expect(store.current.version, '0.0.0');
      await store.refresh();
      expect(store.current.version, '1.0.0');

      next = download('1.0.1', digest: 'incorrect');
      await store.refresh();
      expect(store.current.version, '1.0.0');
      next = download('0.9.0');
      await store.refresh();
      expect(store.current.version, '1.0.0');

      final restarted = ApiPackages(
        cache: () async => file,
        fetch: (_) async => throw const SocketException('offline'),
      );
      await restarted.initialize();
      expect(restarted.current.version, '1.0.0');
      await restarted.refresh();
      expect(restarted.current.version, '1.0.0');
    },
  );

  test(
    'a package update does not switch endpoints during pagination',
    () async {
      var rules = ApiPackage.decode(packageBytes('1.0.0'));
      final paths = <String>[];
      final discovery = DiscoveryClient(
        apiPackage: () => rules,
        client: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(
            jsonEncode({
              'entries': [],
              'pageNum':
                  int.tryParse(request.url.queryParameters['page'] ?? '') ?? 1,
              'totalPages': 2,
              'totalCount': 0,
            }),
            200,
          );
        }),
      );
      addTearDown(discovery.close);
      await discovery.search('重生');
      rules = ApiPackage.decode(packageBytes('1.0.1', path: '/api/search/v3'));
      await discovery.search('重生', page: 2);
      await discovery.search('重生');
      expect(paths, ['/api/search/v2', '/api/search/v2', '/api/search/v3']);
    },
  );
}
