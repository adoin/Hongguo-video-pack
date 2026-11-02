import 'dart:async';
import 'app_logs.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'app_storage.dart';

class StableVersion implements Comparable<StableVersion> {
  StableVersion(this.major, this.minor, this.patch);
  final int major, minor, patch;
  static StableVersion? parse(String value) {
    final match = RegExp(
      r'^[vV]?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
    ).firstMatch(value);
    if (match == null) return null;
    return StableVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
    );
  }

  @override
  int compareTo(StableVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final result = pair.$1.compareTo(pair.$2);
      if (result != 0) return result;
    }
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch';
}

class ReleaseAsset {
  ReleaseAsset({
    required this.name,
    required this.size,
    required this.url,
    this.digest,
  });
  final String name;
  final int size;
  final Uri url;
  final String? digest;
}

class AppRelease {
  AppRelease({
    required this.tag,
    required this.version,
    required this.notes,
    this.installer,
    this.checksums,
    this.source = 'GitHub',
    this.repository = 'adoin/Hongguo-video-pack',
  });
  final String tag, notes;
  final StableVersion version;
  final ReleaseAsset? installer, checksums;
  final String source, repository;
  Uri get page => Uri.https(
    source == 'Gitee' ? 'gitee.com' : 'github.com',
    source == 'Gitee'
        ? '/$repository/releases'
        : '/$repository/releases/tag/$tag',
  );
}

enum UpdateSource {
  automatic('自动（同版本优先 Gitee）'),
  gitee('Gitee'),
  github('GitHub');

  const UpdateSource(this.label);
  final String label;
}

class _ReleaseResult {
  const _ReleaseResult(this.release, this.success);
  final AppRelease? release;
  final bool success;
}

class AppUpdater extends ChangeNotifier {
  AppUpdater({
    http.Client? client,
    http.Client Function()? downloadClient,
    Future<String> Function()? versionReader,
    Future<Directory> Function()? directory,
    String? platform,
    this.giteeRepository = const String.fromEnvironment(
      'HONGPUTAO_GITEE_REPOSITORY',
      defaultValue: 'adoin/Hongguo-video-pack',
    ),
  }) : _client = client ?? http.Client(),
       _downloadClient = downloadClient ?? http.Client.new,
       _versionReader =
           versionReader ??
           (() async => (await PackageInfo.fromPlatform()).version),
       _directory =
           directory ??
           (() async => Directory(
             p.join((await appSupportDirectory()).path, 'data', 'updates'),
           )),
       platform = platform ?? Platform.operatingSystem;
  final http.Client _client;
  final http.Client Function() _downloadClient;
  final Future<String> Function() _versionReader;
  final Future<Directory> Function() _directory;
  final String platform;
  final String giteeRepository;
  String currentVersion = '', status = '仅检查 GitHub 正式版', error = '';
  AppRelease? release;
  bool checking = false,
      downloading = false,
      _disposed = false,
      _cancelled = false;
  double? progress;
  File? readyFile;
  String? _expectedHash;
  http.Client? _transfer;
  bool get hasUpdate {
    final local = StableVersion.parse(currentVersion);
    return local != null &&
        release != null &&
        release!.version.compareTo(local) > 0;
  }

  String _lastLoggedError = '';
  void _notify() {
    if (error.isNotEmpty && error != _lastLoggedError) {
      AppLogs.shared.add(LogLevel.warning, '更新', error);
    }
    _lastLoggedError = error;
    if (!_disposed) notifyListeners();
  }

  static Uri _assetUrl(String tag, String name) => Uri.https(
    'github.com',
    '/adoin/Hongguo-video-pack/releases/download/$tag/$name',
  );

  Future<http.Response> _get(Uri uri) async {
    final response = await _client
        .get(
          uri,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'Hongputao-Updater',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException('release request failed');
    }
    return response;
  }

  UpdateSource selectedSource = UpdateSource.automatic;
  final _sources = <UpdateSource, _ReleaseResult>{};
  bool get allSourcesFailed =>
      _sources.isNotEmpty && _sources.values.every((value) => !value.success);
  String sourceStatus(UpdateSource source) {
    final result = _sources[source];
    if (result == null) return checking ? '检查中…' : '尚未检查';
    if (!result.success) return '暂不可用';
    return result.release == null
        ? '暂无正式版安装包'
        : '正式版 ${result.release!.version}';
  }

  void _adopt(AppRelease? value) {
    if (release?.tag != value?.tag || release?.source != value?.source) {
      readyFile = null;
      _expectedHash = null;
    }
    release = value;
  }

  void _selectRelease() {
    if (selectedSource != UpdateSource.automatic) {
      final result = _sources[selectedSource];
      _adopt(result?.release);
      if (result == null || !result.success) {
        error = '${selectedSource.label} 暂不可用，请重试或选择其他来源。';
      }
    } else {
      final gitee = _sources[UpdateSource.gitee]?.release;
      final github = _sources[UpdateSource.github]?.release;
      _adopt(
        gitee != null &&
                (github == null || gitee.version.compareTo(github.version) >= 0)
            ? gitee
            : github,
      );
    }
    if (allSourcesFailed) error = 'GitHub 和 Gitee 均检查失败，请检查网络后重试。';
    status = release == null
        ? (error.isEmpty ? '暂未找到可用正式版' : '未能完成检查')
        : hasUpdate
        ? '发现正式版 ${release!.version}（${release!.source}）'
        : '当前无需更新（${release!.source} 正式版 ${release!.version}）';
  }

  void selectSource(UpdateSource source) {
    if (checking || downloading || _disposed) return;
    selectedSource = source;
    error = '';
    _selectRelease();
    _notify();
  }

  Future<_ReleaseResult> _probe(Future<AppRelease?> Function() read) async {
    try {
      return _ReleaseResult(
        await read().timeout(const Duration(seconds: 25)),
        true,
      );
    } catch (_) {
      return const _ReleaseResult(null, false);
    }
  }

  Future<void> check({bool githubOnly = false}) async {
    if (checking || downloading || _disposed) return;
    checking = true;
    error = '';
    status = '正在检查 GitHub 和 Gitee 正式版…';
    _notify();
    try {
      currentVersion = await _versionReader();
      if (StableVersion.parse(currentVersion) == null) {
        throw const FormatException('unsupported local version');
      }
      if (githubOnly) {
        final result = await _probe(_githubLatest);
        _sources[UpdateSource.github] = result;
        _adopt(result.release);
        if (!result.success) error = 'GitHub 暂不可用，请稍后重试。';
        status = hasUpdate
            ? '发现正式版 ${release!.version}（GitHub）'
            : 'GitHub 检查完成';
      } else {
        // Start both requests before awaiting either; one failed source cannot suppress the other.
        final results = await Future.wait([
          _probe(_giteeLatest),
          _probe(_githubLatest),
        ]);
        if (_disposed) return;
        _sources[UpdateSource.gitee] = results[0];
        _sources[UpdateSource.github] = results[1];
        _selectRelease();
      }
    } catch (_) {
      error = '无法读取当前版本或检查更新，请稍后重试。';
      status = '未能完成检查';
    } finally {
      checking = false;
      _notify();
    }
  }

  Future<AppRelease?> _githubLatest() async {
    final candidates = <AppRelease>[];
    for (var page = 1; page <= 20; page++) {
      final response = await _get(
        Uri.https(
          'api.github.com',
          '/repos/adoin/Hongguo-video-pack/releases',
          {'per_page': '100', 'page': '$page'},
        ),
      );
      final rows = jsonDecode(response.body) as List;
      for (final row in rows.whereType<Map>()) {
        if (row['draft'] != false || row['prerelease'] != false) continue;
        final tag = row['tag_name'] as String? ?? '';
        final version = StableVersion.parse(tag);
        if (version == null) continue;
        final assets = <String, ReleaseAsset>{};
        for (final raw in (row['assets'] as List? ?? []).whereType<Map>()) {
          final name = raw['name'] as String? ?? '';
          final size = raw['size'] as int? ?? 0;
          if (size <= 0 || raw['state'] != 'uploaded') continue;
          // Construct the repository URL ourselves; never execute arbitrary URLs from metadata.
          final url = _assetUrl(tag, name);
          if (raw['browser_download_url'] != url.toString()) continue;
          assets[name] = ReleaseAsset(
            name: name,
            size: size,
            url: url,
            digest: raw['digest'] as String?,
          );
        }
        final name = platform == 'windows'
            ? 'Hongputao-Windows-$version-Setup.exe'
            : platform == 'android'
            ? 'Hongputao-Android-arm64-$version.apk'
            : '';
        candidates.add(
          AppRelease(
            tag: tag,
            version: version,
            notes: row['body'] as String? ?? '',
            installer: assets[name],
            checksums: assets['SHA256SUMS.txt'],
          ),
        );
      }
      if (rows.length < 100) break;
      if (page == 20) {
        throw const FormatException('release listing too large');
      }
    }
    candidates.sort((a, b) => b.version.compareTo(a.version));
    return candidates.firstOrNull;
  }

  Future<AppRelease?> _giteeLatest() async {
    if (!RegExp(
      r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$',
    ).hasMatch(giteeRepository)) {
      throw const FormatException('mirror repository unavailable');
    }
    final releases = <AppRelease>[];
    for (var page = 1; page <= 20; page++) {
      final response = await _client
          .get(
            Uri.https('gitee.com', '/api/v5/repos/$giteeRepository/releases', {
              'per_page': '100',
              'page': '$page',
            }),
            headers: const {'User-Agent': 'Hongputao-Updater'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        throw const HttpException('mirror unavailable');
      }
      final rows = jsonDecode(utf8.decode(response.bodyBytes)) as List;
      for (final row in rows.whereType<Map>()) {
        final tag = row['tag_name'] as String? ?? '';
        final version = StableVersion.parse(tag);
        if (row['prerelease'] != false ||
            row['draft'] == true ||
            version == null) {
          continue;
        }
        final assets = <String, ReleaseAsset>{};
        for (final raw in (row['assets'] as List? ?? []).whereType<Map>()) {
          final name = raw['name'] as String? ?? '';
          final expected = Uri.https(
            'gitee.com',
            '/$giteeRepository/releases/download/$tag/$name',
          );
          if (raw['browser_download_url'] != expected.toString()) continue;
          assets[name] = ReleaseAsset(name: name, size: 0, url: expected);
        }
        final name = platform == 'windows'
            ? 'Hongputao-Windows-$version-Setup.exe'
            : platform == 'android'
            ? 'Hongputao-Android-arm64-$version.apk'
            : '';
        if (assets[name] == null || assets['SHA256SUMS.txt'] == null) continue;
        releases.add(
          AppRelease(
            tag: tag,
            version: version,
            notes: row['body'] as String? ?? '',
            source: 'Gitee',
            repository: giteeRepository,
            installer: assets[name],
            checksums: assets['SHA256SUMS.txt'],
          ),
        );
      }
      if (rows.length < 100) break;
      if (page == 20) throw const FormatException('mirror listing too large');
    }
    releases.sort((a, b) => b.version.compareTo(a.version));
    return releases.firstOrNull;
  }

  Future<String> _checksum(AppRelease value) async {
    final asset = value.installer!;
    final digest = asset.digest;
    if (digest != null &&
        RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      return digest.substring(7).toLowerCase();
    }
    final sums = value.checksums;
    if (sums == null || sums.size > 65536) {
      throw const FormatException('missing checksums');
    }
    final response = await _get(sums.url);
    if (response.bodyBytes.length > 65536) {
      throw const FormatException('large checksums');
    }
    for (final line in const LineSplitter().convert(
      utf8.decode(response.bodyBytes),
    )) {
      final match = RegExp(
        r'^([a-fA-F0-9]{64})\s+\*?(.+)$',
      ).firstMatch(line.replaceFirst('\uFEFF', ''));
      if (match != null && match[2] == asset.name) {
        return match[1]!.toLowerCase();
      }
    }
    throw const FormatException('missing asset checksum');
  }

  void cancel() {
    _cancelled = true;
    _transfer?.close();
  }

  Future<void> download() async {
    if (downloading || checking || _disposed) return;
    final mirrored =
        selectedSource == UpdateSource.automatic && release?.source == 'Gitee';
    final attemptedRelease = release;
    final attemptedVersion = release?.version;
    await _downloadSingle();
    if (mirrored &&
        !_cancelled &&
        !_disposed &&
        readyFile == null &&
        error.isNotEmpty) {
      status = '国内镜像暂不可用，正在切换 GitHub…';
      _notify();
      await check(githubOnly: true);
      if (hasUpdate &&
          error.isEmpty &&
          attemptedVersion != null &&
          release!.version.compareTo(attemptedVersion) >= 0) {
        await _downloadSingle();
      } else if (error.isEmpty) {
        _adopt(attemptedRelease);
        error = '国内下载失败，GitHub 暂未提供相同或更新版本。可手动选择来源重试。';
        _notify();
      }
    }
  }

  Future<void> _downloadSingle() async {
    if (!hasUpdate || downloading || checking || _disposed) return;
    final value = release!, asset = release!.installer;
    if (asset == null) {
      error = '该正式版的本平台安装包尚未就绪，请稍后重试。';
      _notify();
      return;
    }
    downloading = true;
    _cancelled = false;
    error = '';
    progress = null;
    readyFile = null;
    status = '正在准备下载…';
    _notify();
    File? partial;
    IOSink? sink;
    try {
      if (asset.size > 1024 * 1024 * 1024) {
        throw const FormatException('oversized package');
      }
      final hash = await _checksum(value);
      if (_cancelled) throw const HttpException('cancelled');
      final directory = await _directory();
      await directory.create(recursive: true);
      final target = File(p.join(directory.path, asset.name));
      if (!p.isWithin(directory.absolute.path, target.absolute.path)) {
        throw const FormatException('invalid path');
      }
      partial = File('${target.path}.part');
      if (await target.exists() &&
          (asset.size == 0 || await target.length() == asset.size) &&
          (await sha256.bind(target.openRead()).first).toString() == hash) {
        readyFile = target;
        _expectedHash = hash;
        status = '安装包已校验，可安装';
        return;
      }
      _transfer = _downloadClient();
      final request = http.Request('GET', asset.url)
        ..headers['User-Agent'] = 'Hongputao-Updater';
      final response = await _transfer!
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 ||
          asset.size > 0 &&
              response.contentLength != null &&
              response.contentLength != asset.size) {
        throw const HttpException('bad package response');
      }
      sink = partial.openWrite();
      var received = 0;
      final expectedSize = asset.size > 0 ? asset.size : response.contentLength;
      if (expectedSize != null && expectedSize > 1024 * 1024 * 1024) {
        throw const FormatException('oversized mirror package');
      }
      await for (final bytes in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (_cancelled || _disposed) throw const HttpException('cancelled');
        received += bytes.length;
        if (received > (expectedSize ?? 1024 * 1024 * 1024)) {
          throw const FormatException('package too large');
        }
        sink.add(bytes);
        progress = expectedSize != null && expectedSize > 0
            ? received / expectedSize
            : null;
        status = '正在下载安装包…';
        _notify();
      }
      await sink.close();
      sink = null;
      if (_cancelled ||
          received == 0 ||
          expectedSize != null && received != expectedSize) {
        throw const HttpException('incomplete package');
      }
      status = '正在校验安装包…';
      _notify();
      if ((await sha256.bind(partial.openRead()).first).toString() != hash) {
        throw const FormatException('checksum mismatch');
      }
      if (_cancelled || _disposed) throw const HttpException('cancelled');
      readyFile = await partial.rename(target.path);
      _expectedHash = hash;
      status = '安装包已校验，可安装';
    } catch (_) {
      error = _cancelled ? '' : '下载或校验失败，请重试；不会运行未通过校验的安装包。';
      status = _cancelled ? '已取消下载' : '更新包未准备完成';
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        /* Keep failed packages untrusted. */
      }
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } catch (_) {
        /* A leftover .part is never offered for installation. */
      }
      _transfer?.close();
      _transfer = null;
      downloading = false;
      _notify();
    }
  }

  Future<File> verifyForInstall() async {
    final file = readyFile, hash = _expectedHash;
    if (!hasUpdate ||
        file == null ||
        hash == null ||
        !await file.exists() ||
        (await sha256.bind(file.openRead()).first).toString() != hash) {
      readyFile = null;
      _notify();
      throw const FormatException('unverified installer');
    }
    return file;
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    _client.close();
    super.dispose();
  }
}
