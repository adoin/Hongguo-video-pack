import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

enum LogLevel { debug, info, warning, error }

class LogEntry {
  LogEntry(this.time, this.level, this.source, this.message);
  final DateTime time;
  final LogLevel level;
  final String source, message;
  String get text =>
      '${time.toLocal().toIso8601String()} [${level.name.toUpperCase()}] $source: $message';
  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'level': level.name,
    'source': source,
    'message': message,
  };
}

class AppLogs extends ChangeNotifier {
  static final shared = AppLogs();
  final entries = <LogEntry>[];
  bool full = false;
  File? _file;
  Timer? _timer;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  static String redact(String input) => input
      .replaceAll(
        RegExp(r'''(?:https?|file)://[^\s<>"']+''', caseSensitive: false),
        '[链接已隐藏]',
      )
      .replaceAll(
        RegExp(
          r'''(?:authorization|set-cookie|cookie|password|passwd|token|device_id|iid|spade_a|decryption_key)\s*["']?\s*[:=]\s*[^\r\n]+''',
          caseSensitive: false,
        ),
        '[敏感字段已隐藏]',
      )
      .replaceAll(RegExp(r'\b\d{16,}\b'), '[标识已隐藏]')
      .replaceAll(RegExp(r'\b[a-fA-F0-9]{32,}\b'), '[密钥已隐藏]')
      .replaceAll(RegExp(r'[A-Za-z]:\\[^\r\n]+'), '[本地路径已隐藏]')
      .replaceAll(
        RegExp(r'/(?:Users|home|data/user|data/data|storage|sdcard)/[^\r\n]+'),
        '[本地路径已隐藏]',
      );

  Future<void> initialize(File file) async {
    if (_file != null) return;
    _file = file;
    try {
      if (await file.exists() && await file.length() <= 2 * 1024 * 1024) {
        final data = jsonDecode(await file.readAsString()) as Map;
        full = data['full'] == true;
        final restored = <LogEntry>[];
        for (final raw in (data['entries'] as List? ?? []).take(2000)) {
          try {
            final row = raw as Map;
            restored.add(
              LogEntry(
                DateTime.parse(row['time'] as String),
                LogLevel.values.byName(row['level'] as String),
                redact(row['source'] as String),
                redact(row['message'] as String),
              ),
            );
          } catch (_) {
            /* Skip a damaged row. */
          }
        }
        entries.insertAll(0, restored);
      }
    } catch (_) {
      add(LogLevel.warning, '日志', '上次日志无法读取。');
    }
    _trim();
    _notify();
  }

  void add(
    LogLevel level,
    String source,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    if (_disposed || (!full && level.index < LogLevel.warning.index)) return;
    final detail =
        '$message${error == null ? '' : '\n${error.runtimeType}: $error'}'
        '${stack == null ? '' : '\n$stack'}';
    final safe = redact(detail);
    entries.add(
      LogEntry(
        DateTime.now().toUtc(),
        level,
        redact(source),
        safe.length > 6000 ? safe.substring(0, 6000) : safe,
      ),
    );
    _trim();
    _notify();
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), flush);
  }

  void _trim() {
    if (entries.length > 1000) entries.removeRange(0, entries.length - 1000);
    var size = entries.fold<int>(0, (n, e) => n + utf8.encode(e.text).length);
    while (size > 768 * 1024 && entries.isNotEmpty) {
      size -= utf8.encode(entries.removeAt(0).text).length;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setFull(bool value) {
    full = value;
    _notify();
    unawaited(flush());
  }

  Future<void> clear() async {
    entries.clear();
    _notify();
    await flush();
  }

  Future<void> flush() {
    _timer?.cancel();
    final file = _file;
    if (file == null) return _tail;
    final payload = jsonEncode({
      'version': 1,
      'full': full,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
    _tail = _tail.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(payload, flush: true);
        await temporary.rename(file.path);
      } catch (_) {
        /* Keep the in-memory log usable when storage is unavailable. */
      }
    });
    return _tail;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

class LoggedHttpClient extends http.BaseClient {
  LoggedHttpClient([http.Client? client]) : _client = client ?? http.Client();
  final http.Client _client;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final timer = Stopwatch()..start();
    final name =
        request.url.path.startsWith('/novel/') ||
            request.url.path.startsWith('/api/') ||
            request.url.path.startsWith('/service/2/')
        ? request.url.path
        : '资源请求';
    try {
      final response = await _client.send(request);
      AppLogs.shared.add(
        response.statusCode >= 500
            ? LogLevel.error
            : response.statusCode >= 400
            ? LogLevel.warning
            : LogLevel.debug,
        'HTTP',
        '${request.method} $name · ${response.statusCode} · ${timer.elapsedMilliseconds} ms',
      );
      return response;
    } catch (error, stack) {
      AppLogs.shared.add(
        LogLevel.debug,
        'HTTP',
        '${request.method} $name 失败',
        error: error,
        stack: stack,
      );
      rethrow;
    }
  }

  @override
  void close() => _client.close();
}
