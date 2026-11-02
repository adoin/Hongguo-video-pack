import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../watch_history.dart';
import 'app_logs.dart';

class WebDavConfig {
  const WebDavConfig({
    this.url = '',
    this.username = '',
    this.password = '',
    this.enabled = false,
    this.automatic = true,
  });
  final String url, username, password;
  final bool enabled, automatic;
  Map<String, dynamic> toJson() => {
    'url': url,
    'username': username,
    'password': password,
    'enabled': enabled,
    'automatic': automatic,
  };
  factory WebDavConfig.fromJson(Map j) => WebDavConfig(
    url: j['url'] as String? ?? '',
    username: j['username'] as String? ?? '',
    password: j['password'] as String? ?? '',
    enabled: j['enabled'] == true,
    automatic: j['automatic'] != false,
  );
  Uri get root {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        username.contains(':')) {
      throw const FormatException('请输入不含账号和查询参数的 WebDAV 目录地址。');
    }
    return uri.replace(
      path: uri.path.endsWith('/') ? uri.path : '${uri.path}/',
    );
  }
}

abstract class SyncCredentialStore {
  Future<WebDavConfig?> read();
  Future<void> write(WebDavConfig config);
}

class SecureSyncCredentials implements SyncCredentialStore {
  static const _storage = FlutterSecureStorage(
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );
  static const _key = 'hongputao.webdav.v1';
  @override
  Future<WebDavConfig?> read() async {
    final value = await _storage.read(key: _key);
    return value == null
        ? null
        : WebDavConfig.fromJson(jsonDecode(value) as Map);
  }

  @override
  Future<void> write(WebDavConfig config) =>
      _storage.write(key: _key, value: jsonEncode(config.toJson()));
}

class WebDavFailure implements Exception {
  const WebDavFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class WebDavSync extends ChangeNotifier {
  WebDavSync({
    required this.history,
    SyncCredentialStore? credentials,
    http.Client? client,
    this.delay = const Duration(seconds: 30),
  }) : credentials = credentials ?? SecureSyncCredentials(),
       _client = client ?? http.Client() {
    history.addListener(_historyChanged);
  }
  final WatchHistory history;
  final SyncCredentialStore credentials;
  final http.Client _client;
  final Duration delay;
  WebDavConfig config = const WebDavConfig();
  bool busy = false, _initialized = false, _disposed = false, _merging = false;
  String? error;
  DateTime? lastSync;
  String _baseline = '';
  Timer? _timer;
  static const maxBytes = 4 * 1024 * 1024;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      config = await credentials.read() ?? const WebDavConfig();
    } catch (e, s) {
      error = 'WebDAV 配置无法读取，请重新保存。';
      AppLogs.shared.add(LogLevel.error, '同步', error!, error: e, stack: s);
    }
    _baseline = jsonEncode(history.syncSnapshot());
    _notify();
    if (config.enabled && config.automatic) unawaited(sync());
  }

  Future<void> save(WebDavConfig value) async {
    if (busy) throw const WebDavFailure('同步进行中，请稍后保存。');
    if (value.enabled) value.root;
    try {
      await credentials.write(
        value,
      ); // Never persist a password in workspace.json.
    } catch (failure, stack) {
      error = 'WebDAV 配置保存失败，请检查系统凭据存储。';
      AppLogs.shared.add(
        LogLevel.error,
        '同步',
        error!,
        error: failure,
        stack: stack,
      );
      _notify();
      throw WebDavFailure(error!);
    }
    config = value;
    error = null;
    _timer?.cancel();
    _notify();
    if (value.enabled && value.automatic) unawaited(sync());
  }

  void _historyChanged() {
    if (_merging ||
        !_initialized ||
        _disposed ||
        !config.enabled ||
        !config.automatic) {
      return;
    }
    if (jsonEncode(history.syncSnapshot()) == _baseline) return;
    _timer ??= Timer(delay, () {
      _timer = null;
      unawaited(sync());
    });
  }

  void resume() {
    if (_initialized && config.enabled && config.automatic) unawaited(sync());
  }

  Future<void> test(WebDavConfig value) async {
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      final response = await _request(
        value,
        'PROPFIND',
        value.root,
        headers: {'Depth': '0'},
      );
      if (!{200, 207}.contains(response.statusCode)) _fail(response.statusCode);
      AppLogs.shared.add(LogLevel.info, '同步', 'WebDAV 连接测试成功。');
    } catch (e, s) {
      error = e is FormatException ? e.message : _message(e);
      AppLogs.shared.add(LogLevel.error, '同步', error!, error: e, stack: s);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> sync() async {
    if (busy || _disposed || !config.enabled) return;
    _timer?.cancel();
    _timer = null;
    busy = true;
    error = null;
    _notify();
    try {
      final folder = config.root.resolve('Hongputao/');
      final uri = folder.resolve('watch-history-v1.json');
      final mkcol = await _request(config, 'MKCOL', folder);
      if (!{200, 201, 204, 405}.contains(mkcol.statusCode)) {
        _fail(mkcol.statusCode);
      }
      for (var attempt = 0; attempt < 3; attempt++) {
        final remote = await _request(config, 'GET', uri);
        final fresh = remote.statusCode == 404;
        if (!fresh && remote.statusCode != 200) _fail(remote.statusCode);
        String? tag;
        if (!fresh) {
          tag = remote.headers['etag'];
          if (tag == null || tag.startsWith('W/')) {
            throw const WebDavFailure('服务器未提供安全合并所需的记录版本，无法覆盖云端数据。');
          }
          final data = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(remote.bodyBytes)) as Map,
          );
          _merging = true;
          try {
            history.mergeSync(data);
            await history.flush();
          } finally {
            _merging = false;
          }
        }
        final payload = jsonEncode(history.syncSnapshot());
        if (utf8.encode(payload).length > maxBytes) {
          throw const WebDavFailure('同步记录超过 4 MiB，请减少记录后重试。');
        }
        final saved = await _request(
          config,
          'PUT',
          uri,
          body: payload,
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            if (fresh) 'If-None-Match': '*' else 'If-Match': tag!,
          },
        );
        if ({409, 412}.contains(saved.statusCode)) continue;
        if (!{200, 201, 204}.contains(saved.statusCode)) {
          _fail(saved.statusCode);
        }
        _baseline = payload;
        lastSync = DateTime.now();
        AppLogs.shared.add(LogLevel.info, '同步', '观看记录同步完成。');
        return;
      }
      throw const WebDavFailure('其他设备正在更新记录，请稍后重试。');
    } catch (e, s) {
      error = _message(e);
      AppLogs.shared.add(LogLevel.error, '同步', error!, error: e, stack: s);
    } finally {
      busy = false;
      _notify();
      if (error == null) _historyChanged();
    }
  }

  Future<http.Response> _request(
    WebDavConfig value,
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final abort = Completer<void>();
    final timer = Timer(const Duration(seconds: 20), () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request =
          http.AbortableRequest(method, uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers.addAll({
              'Authorization':
                  'Basic ${base64Encode(utf8.encode('${value.username}:${value.password}'))}',
              ...headers,
            });
      if (body != null) request.bodyBytes = utf8.encode(body);
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if ((response.contentLength ?? 0) > maxBytes) {
        throw const WebDavFailure('云端响应过大，已停止读取。');
      }
      final bytes = BytesBuilder();
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const WebDavFailure('云端响应过大，已停止读取。');
        }
        bytes.add(chunk);
      }
      return http.Response.bytes(
        bytes.takeBytes(),
        response.statusCode,
        headers: response.headers,
      );
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
    }
  }

  Never _fail(int code) => throw WebDavFailure(switch (code) {
    401 || 403 => 'WebDAV 认证或权限不足，请检查账号和应用密码。',
    301 || 302 || 307 || 308 => 'WebDAV 地址发生跳转，请填写最终目录地址。',
    409 => 'WebDAV 上级目录不存在，请检查目录地址。',
    _ => 'WebDAV 请求失败（HTTP $code）。',
  });
  String _message(Object e) => e is WebDavFailure
      ? e.message
      : e is FormatException
      ? '云端记录格式无效，未覆盖本地数据。'
      : e is TimeoutException ||
            e is SocketException ||
            e is http.ClientException
      ? '同步连接失败或超时，请检查网络后重试。'
      : '同步失败，请检查配置与本地存储。';
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    history.removeListener(_historyChanged);
    _client.close();
    super.dispose();
  }
}
