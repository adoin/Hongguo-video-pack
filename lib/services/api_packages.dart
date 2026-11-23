import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/api_package.dart';
import 'app_logs.dart';
import 'app_storage.dart';

typedef ApiPackageDownload = ({String version, String digest, Uint8List bytes});

final class ApiPackages {
  ApiPackages({required this.cache, required this.fetch});

  static final shared = ApiPackages(
    cache: () async => File(
      p.join((await appSupportDirectory()).path, 'data', 'api-package.json'),
    ),
    fetch: _GithubPackages().latest,
  );

  final Future<File> Function() cache;
  final Future<ApiPackageDownload?> Function(String currentVersion) fetch;
  ApiPackage _current = ApiPackage.bundled;
  ApiPackage get current => _current;
  Future<void>? _refresh;

  Future<void> initialize() async {
    try {
      final file = await cache();
      if (!await file.exists() ||
          await file.length() > ApiPackage.maxBytes * 2) {
        return;
      }
      final saved =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final bytes = base64Decode(saved['body'] as String);
      final package = _verify(bytes, saved['digest'] as String);
      if (ApiPackage.compareVersions(package.version, _current.version) > 0) {
        _current = package;
      }
    } on Object {
      AppLogs.shared.add(LogLevel.debug, 'API 包', '无法读取本地规则包');
    }
  }

  Future<void> refresh() =>
      _refresh ??= _download().whenComplete(() => _refresh = null);

  Future<void> _download() async {
    try {
      final result = await fetch(_current.version);
      if (result == null) return;
      final package = _verify(result.bytes, result.digest);
      if (result.version != package.version) {
        throw const FormatException('API package tag mismatch');
      }
      if (ApiPackage.compareVersions(package.version, _current.version) <= 0) {
        return;
      }
      final file = await cache();
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.pending');
      try {
        await pending.writeAsString(
          jsonEncode({
            'digest': result.digest,
            'body': base64Encode(result.bytes),
          }),
          flush: true,
        );
        await pending.rename(file.path);
      } finally {
        if (await pending.exists()) await pending.delete();
      }
      _current = package;
    } on Object {
      AppLogs.shared.add(LogLevel.debug, 'API 包', '检查更新失败，保留当前规则');
    }
  }

  static ApiPackage _verify(Uint8List bytes, String digest) {
    if (bytes.length > ApiPackage.maxBytes ||
        digest != 'sha256:${sha256.convert(bytes)}') {
      throw const FormatException('Invalid API package digest');
    }
    return ApiPackage.decode(bytes);
  }
}

final class _GithubPackages {
  static const _repo = 'adoin/Hongputao-api';
  static const _filename = 'hongputao-api.json';
  static const _metadataLimit = 128 * 1024;
  static const _timeout = Duration(seconds: 6);

  Future<ApiPackageDownload?> latest(String currentVersion) async {
    const edge = String.fromEnvironment('HONGPUTAO_API_FEED');
    const vps = String.fromEnvironment('HONGPUTAO_API_FALLBACK_FEED');
    final configured = [edge, vps].where((value) => value.isNotEmpty).toList();
    if (configured.isNotEmpty) return _staticLatest(currentVersion, configured);
    if (!Platform.isWindows || !await _hasGithubCli()) {
      return _staticLatest(currentVersion, [
        'https://adoin.github.io/Hongputao-api/feed.json',
      ]);
    }
    final metadata = await _ghBytes([
      'api',
      'repos/$_repo/releases/latest',
    ], _metadataLimit);
    final release = jsonDecode(utf8.decode(metadata)) as Map<String, dynamic>;
    final tag = release['tag_name'];
    if (release['draft'] != false ||
        release['prerelease'] != false ||
        tag is! String ||
        !tag.startsWith('v') ||
        !ApiPackage.isVersion(tag.substring(1))) {
      throw const FormatException('Invalid API package release');
    }
    final version = tag.substring(1);
    if (ApiPackage.compareVersions(version, currentVersion) <= 0) return null;
    final asset = (release['assets'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((a) => a['name'] == _filename);
    final digest = asset['digest'];
    final id = asset['id'];
    if (asset['state'] != 'uploaded' ||
        asset['size'] is! int ||
        (asset['size'] as int) > ApiPackage.maxBytes ||
        id is! int ||
        digest is! String) {
      throw const FormatException('Invalid API package attachment');
    }
    final bytes = await _ghBytes([
      'api',
      'repos/$_repo/releases/assets/$id',
      '-H',
      'Accept: application/octet-stream',
    ], ApiPackage.maxBytes);
    return (version: version, digest: digest, bytes: bytes);
  }

  Future<ApiPackageDownload?> _staticLatest(
    String version,
    List<String> urls,
  ) async {
    final client = http.Client();
    try {
      return await fetchStaticApiPackage(
        client,
        urls,
        version,
        timeout: _timeout,
      );
    } finally {
      client.close();
    }
  }

  Future<bool> _hasGithubCli() async {
    final Process child;
    try {
      child = await Process.start('gh.exe', [
        'auth',
        'status',
        '--hostname',
        'github.com',
      ]);
    } on ProcessException catch (error) {
      if (error.errorCode == 2 || error.errorCode == 3) return false;
      rethrow;
    }
    try {
      final output = _readBytes(child.stdout, 8192);
      final errors = _readBytes(child.stderr, 8192);
      final result = await Future.wait([output, errors]).timeout(_timeout);
      if (await child.exitCode.timeout(_timeout) == 0) return true;
      final message = utf8.decode(result[0] + result[1], allowMalformed: true);
      if (message.contains('not logged into any GitHub hosts')) return false;
      throw StateError('GitHub CLI auth check failed');
    } finally {
      child.kill();
    }
  }

  Future<Uint8List> _ghBytes(List<String> arguments, int limit) async {
    final child = await Process.start('gh.exe', arguments);
    final errors = child.stderr.drain<void>();
    try {
      final bytes = await _readBytes(child.stdout, limit).timeout(_timeout);
      if (await child.exitCode.timeout(_timeout) != 0) {
        throw StateError('GitHub CLI request failed');
      }
      return bytes;
    } finally {
      child.kill();
      await errors;
    }
  }
}

Future<Uint8List> _readBytes(Stream<List<int>> stream, int limit) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (chunk.length > limit - builder.length) {
      throw const FormatException('API package response too large');
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Tries each build-configured host in order, including on invalid content.
Future<ApiPackageDownload?> fetchStaticApiPackage(
  http.Client client,
  List<String> urls,
  String currentVersion, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  for (final url in urls.take(2)) {
    final abort = Completer<void>();
    try {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !uri.path.endsWith('/feed.json')) {
        throw const FormatException('Invalid API feed URL');
      }
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['accept'] = 'application/json';
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        throw StateError('API package feed HTTP ${response.statusCode}');
      }
      final data = await _readBytes(
        response.stream,
        ApiPackage.maxBytes * 2,
      ).timeout(timeout);
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final digest = json['digest'] as String;
      final bytes = base64Decode(json['body'] as String);
      final package = ApiPackages._verify(bytes, digest);
      if (json['version'] != package.version) {
        throw const FormatException('API package feed version mismatch');
      }
      if (ApiPackage.compareVersions(package.version, currentVersion) <= 0) {
        return null;
      }
      return (version: package.version, digest: digest, bytes: bytes);
    } on Object {
      // A failed origin cannot displace an already verified package.
    } finally {
      abort.complete();
    }
  }
  return null;
}
