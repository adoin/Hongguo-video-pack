import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'services/app_logs.dart';

String historySeriesKey(String title) {
  // Only remove the ordinal itself; subtitles and unrelated title text remain.
  return title
      .replaceAllMapped(
        RegExp(r'第\s*[一二三四五六七八九十百千万零〇两\d]+\s*([季部卷篇剧])'),
        (match) => '第${match[1]}',
      )
      .replaceAll(RegExp(r'\s+'), '')
      .toLowerCase();
}

class WatchPoint {
  WatchPoint({
    required this.title,
    this.dramaId = '',
    this.cover = '',
    this.episodeId = '',
    this.episode = 1,
    this.total = 1,
    this.path = '',
    this.positionMs = 0,
    this.durationMs = 0,
    this.watched = false,
    this.fileId = '',
    this.modified,
  });
  String title, dramaId, cover, episodeId, path;
  int episode, total, positionMs, durationMs;
  bool watched;
  String fileId;
  DateTime? modified;
  void updateProgress(
    int position,
    int duration, {
    required bool finalEpisode,
  }) {
    if (duration <= 0 || position < 0) return;
    positionMs = position.clamp(0, duration);
    durationMs = duration;
    watched = watched || (finalEpisode && positionMs / duration > .8);
  }

  bool get local => path.isNotEmpty || fileId.isNotEmpty;
  String get label =>
      '${local ? '合成视频' : '第 $episode 集'} · '
      '${Duration(milliseconds: positionMs).inMinutes}:${(positionMs ~/ 1000 % 60).toString().padLeft(2, '0')}';
  Map<String, dynamic> toJson() => {
    'title': title,
    'dramaId': dramaId,
    'cover': cover,
    'episodeId': episodeId,
    'episode': episode,
    'total': total,
    'path': path,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'watched': watched,
    'fileId': fileId,
    'modified': modified?.toIso8601String(),
  };
  factory WatchPoint.fromJson(Map<String, dynamic> json) => WatchPoint(
    title: json['title'] as String,
    dramaId: json['dramaId'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    episodeId: json['episodeId'] as String? ?? '',
    episode: json['episode'] as int? ?? 1,
    total: json['total'] as int? ?? 1,
    path: json['path'] as String? ?? '',
    positionMs: (json['positionMs'] as int? ?? 0).clamp(0, 1 << 50),
    durationMs: (json['durationMs'] as int? ?? 0).clamp(0, 1 << 50),
    watched: json['watched'] == true,
    fileId: (json['fileId'] as String?)?.isNotEmpty == true
        ? json['fileId'] as String
        : (json['path'] as String? ?? '').isEmpty
        ? ''
        : sha256
              .convert(utf8.encode(p.normalize(json['path'] as String)))
              .toString(),
    modified: DateTime.tryParse(json['modified'] as String? ?? ''),
  );
  WatchPoint copy() => WatchPoint.fromJson(toJson());
}

class WatchEntry {
  WatchEntry({
    required this.key,
    required this.updated,
    this.online,
    List<WatchPoint>? files,
    this.activePath = '',
    this.activeFileId = '',
  }) : files = files ?? [];
  final String key;
  DateTime updated;
  WatchPoint? online;
  final List<WatchPoint> files;
  String activePath;
  String activeFileId;
  WatchPoint get current =>
      files
          .where(
            (f) =>
                activeFileId.isNotEmpty && f.fileId == activeFileId ||
                activePath.isNotEmpty && f.path == activePath,
          )
          .firstOrNull ??
      online ??
      files.first;
  bool get protected => files.isNotEmpty;
  Map<String, dynamic> toJson() => {
    'key': key,
    'updated': updated.toIso8601String(),
    'online': online?.toJson(),
    'files': files.map((f) => f.toJson()).toList(),
    'activePath': activePath,
    'activeFileId': activeFileId,
  };
  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
    key: json['key'] as String,
    updated: DateTime.parse(json['updated'] as String),
    online: json['online'] is Map
        ? WatchPoint.fromJson(Map<String, dynamic>.from(json['online'] as Map))
        : null,
    files: (json['files'] as List? ?? [])
        .map((f) => WatchPoint.fromJson(Map<String, dynamic>.from(f as Map)))
        .toList(),
    activePath: json['activePath'] as String? ?? '',
    activeFileId: json['activeFileId'] as String? ?? '',
  );
}

class WatchHistory extends ChangeNotifier {
  WatchHistory({this.limit = 50, DateTime Function()? now})
    : now = now ?? DateTime.now;
  int limit;
  final DateTime Function() now;
  final _entries = <String, WatchEntry>{};
  final _dismissed = <String>{};
  final _deleted = <String, DateTime>{};
  final _deletedFiles = <String, DateTime>{};
  String _origin = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  DateTime limitUpdated = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  File? _file;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  bool _notificationQueued = false;
  String? error;
  List<WatchEntry> get entries => _entries.values.toList()
    ..sort((a, b) {
      final date = b.updated.compareTo(a.updated);
      return date == 0 ? a.key.compareTo(b.key) : date;
    });
  String keyFor(WatchPoint point) => point.local && point.title == '本地合集'
      ? 'file:${point.fileId.isNotEmpty ? point.fileId : fileFor(point.path)?.fileId ?? _fileId(point.path)}'
      : 'series:${historySeriesKey(point.title)}';
  WatchPoint? onlineFor(String id) => _entries.values
      .map((e) => e.online)
      .whereType<WatchPoint>()
      .where((point) => point.dramaId == id)
      .firstOrNull
      ?.copy();
  WatchPoint? fileFor(String path) => _entries.values
      .expand((e) => e.files)
      .where((point) => point.path == path)
      .firstOrNull
      ?.copy();

  Future<void> initialize(File file) async {
    if (_file != null) return;
    _file = file;
    for (final candidate in [file, File('${file.path}.bak')]) {
      if (!await candidate.exists()) continue;
      try {
        final json = jsonDecode(await candidate.readAsString()) as Map;
        if (json['origin'] is String) _origin = json['origin'] as String;
        if (json['limit'] is int) {
          limit = (json['limit'] as int).clamp(1, 10000);
        }
        limitUpdated =
            DateTime.tryParse(json['limitUpdated'] as String? ?? '') ??
            limitUpdated;
        _readTimes(json['deleted'], _deleted);
        _readTimes(json['deletedFiles'], _deletedFiles);
        final loaded = <String, WatchEntry>{};
        for (final raw in json['entries'] as List? ?? []) {
          try {
            var entry = WatchEntry.fromJson(
              Map<String, dynamic>.from(raw as Map),
            );
            if (entry.online != null || entry.files.isNotEmpty) {
              final originals = (raw)['files'] as List? ?? [];
              for (var i = 0; i < entry.files.length; i++) {
                if ((originals[i] as Map)['fileId'] == null ||
                    (originals[i] as Map)['fileId'] == '') {
                  entry.files[i].fileId = _fileId(entry.files[i].path);
                }
              }
              if (entry.activeFileId.isEmpty && entry.activePath.isNotEmpty) {
                entry.activeFileId =
                    entry.files
                        .where((f) => f.path == entry.activePath)
                        .firstOrNull
                        ?.fileId ??
                    '';
              }
              if (entry.key.startsWith('file:')) {
                entry = WatchEntry.fromJson({
                  ...entry.toJson(),
                  'key': keyFor(entry.current),
                });
              }
              loaded[entry.key] = entry;
            }
          } catch (_) {
            /* One invalid record must not discard the others. */
          }
        }
        loaded.addAll(_entries);
        _entries.addAll(loaded);
        _dismissed.addAll(
          (json['dismissed'] as List? ?? []).whereType<String>(),
        );
        break;
      } catch (_) {
        error = '观看记录读取失败，正在尝试备份。';
        AppLogs.shared.add(LogLevel.warning, '观看记录', error!);
      }
    }
    await pruneMissing();
  }

  void record(WatchPoint point, {bool importing = false, DateTime? date}) {
    if (_disposed || (importing && _dismissed.contains(point.path))) return;
    final value = point.copy();
    if (value.local && point.fileId.isEmpty) {
      value.fileId = fileFor(value.path)?.fileId ?? _fileId(value.path);
    }
    value.modified = date ?? now();
    final key = keyFor(value);
    if (importing && _deleted.containsKey(key)) return;
    final entry = _entries.putIfAbsent(
      key,
      () => WatchEntry(key: key, updated: date ?? now()),
    );
    if (value.local) {
      final old = entry.files.indexWhere(
        (f) =>
            f.fileId == value.fileId ||
            value.path.isNotEmpty && f.path == value.path,
      );
      if (importing && old >= 0) return;
      if (old >= 0) {
        entry.files[old] = value;
      } else {
        entry.files.add(value);
      }
      if (!importing || entry.online == null && entry.files.length == 1) {
        entry.activePath = value.path;
        entry.activeFileId = value.fileId;
      }
      if (!importing) _dismissed.remove(value.path);
    } else {
      entry.online = value;
      entry.activePath = '';
      entry.activeFileId = '';
    }
    if (!importing) entry.updated = now();
    if (!importing) {
      _deleted.remove(key);
      _deletedFiles.remove(value.fileId);
    }
    _trim();
    _changed();
  }

  void _trim() {
    while (_entries.values.where((e) => !e.protected).length > limit) {
      final candidates = _entries.values.where((e) => !e.protected).toList()
        ..sort((a, b) {
          final watched = (a.current.watched ? 0 : 1).compareTo(
            b.current.watched ? 0 : 1,
          );
          return watched != 0 ? watched : a.updated.compareTo(b.updated);
        });
      if (candidates.isEmpty) break;
      _entries.remove(candidates.first.key);
      _deleted[candidates.first.key] = now();
    }
  }

  Future<void> pruneMissing() async {
    // Snapshot before awaiting; do not discard a concurrently added file.
    final missing = <String>{};
    for (final path
        in _entries.values.expand((e) => e.files).map((f) => f.path).toSet()) {
      if (path.isNotEmpty && !await File(path).exists()) missing.add(path);
    }
    for (final entry in _entries.values.toList()) {
      final removed = entry.files
          .where((f) => missing.contains(f.path))
          .toList();
      for (final point in removed) {
        _deletedFiles[point.fileId] = now();
      }
      entry.files.removeWhere((f) => missing.contains(f.path));
      if (removed.isNotEmpty) entry.updated = now();
      if (missing.contains(entry.activePath)) entry.activePath = '';
      if (entry.online == null && entry.files.isEmpty) {
        _entries.remove(entry.key);
        _deleted[entry.key] = now();
      }
    }
    _trim();
    _changed();
    await flush();
  }

  Future<void> remove(String key) async {
    final entry = _entries.remove(key);
    _deleted[key] = now();
    if (entry != null) _dismissed.addAll(entry.files.map((f) => f.path));
    _changed();
    await flush();
  }

  void _changed() {
    if (_disposed) return;
    if (!_notificationQueued) {
      _notificationQueued = true;
      scheduleMicrotask(() {
        _notificationQueued = false;
        if (!_disposed) notifyListeners();
      });
    }
    unawaited(flush());
  }

  Future<void> flush() {
    final file = _file;
    if (file == null) return _tail;
    final payload = jsonEncode({
      'version': 1,
      'origin': _origin,
      'entries': entries.map((e) => e.toJson()).toList(),
      'dismissed': _dismissed.toList(),
      'limit': limit,
      'limitUpdated': limitUpdated.toIso8601String(),
      'deleted': _writeTimes(_deleted),
      'deletedFiles': _writeTimes(_deletedFiles),
    });
    _tail = _tail.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(payload, flush: true);
        await temp.rename(file.path);
        await file.copy('${file.path}.bak');
        error = null;
      } catch (_) {
        error = '观看记录保存失败，请检查本地存储空间。';
        AppLogs.shared.add(LogLevel.error, '观看记录', error!);
      }
    });
    return _tail;
  }

  void setLimit(int value) {
    if (value < 1 || value > 10000) {
      throw const FormatException('记录条数应为 1 到 10000。');
    }
    limit = value;
    limitUpdated = now();
    _trim();
    _changed();
  }

  String _fileId(String path) =>
      sha256.convert(utf8.encode('$_origin:${p.normalize(path)}')).toString();
  static String _entryOrder(WatchEntry entry) => jsonEncode({
    'online': entry.online == null
        ? null
        : {...entry.online!.toJson(), 'cover': ''},
    'active': entry.activeFileId,
  });

  static void _readTimes(dynamic raw, Map<String, DateTime> target) {
    if (raw is! Map) return;
    for (final item in raw.entries) {
      final date = DateTime.tryParse(item.value.toString());
      if (item.key is String &&
          date != null &&
          (target[item.key] == null || date.isAfter(target[item.key]!))) {
        target[item.key as String] = date;
      }
    }
  }

  static Map<String, String> _writeTimes(Map<String, DateTime> values) =>
      values.map((k, v) => MapEntry(k, v.toIso8601String()));

  Map<String, dynamic> syncSnapshot() => {
    'version': 1,
    'limit': limit,
    'limitUpdated': limitUpdated.toIso8601String(),
    'deleted': _writeTimes(_deleted),
    'deletedFiles': _writeTimes(_deletedFiles),
    'entries': entries
        .map(
          (entry) => {
            ...entry.toJson(),
            'activePath': '',
            'online': entry.online == null
                ? null
                : {...entry.online!.toJson(), 'cover': ''},
            'files': entry.files
                .map((f) => {...f.toJson(), 'path': '', 'cover': ''})
                .toList(),
          },
        )
        .toList(),
  };

  void mergeSync(Map<String, dynamic> data) {
    if (data['version'] != 1 ||
        data['entries'] is! List ||
        (data['entries'] as List).length > 10000) {
      throw const FormatException('同步记录格式或版本不支持。');
    }
    // Parse completely before changing local state.
    final incoming = (data['entries'] as List)
        .map(
          (raw) => WatchEntry.fromJson(Map<String, dynamic>.from(raw as Map)),
        )
        .toList();
    final rawSettingTime = data['limitUpdated'];
    if (rawSettingTime != null &&
            (rawSettingTime is! String ||
                DateTime.tryParse(rawSettingTime) == null) ||
        data['limit'] != null &&
            (data['limit'] is! int ||
                (data['limit'] as int) < 1 ||
                (data['limit'] as int) > 10000) ||
        incoming.map((e) => e.key).toSet().length != incoming.length) {
      throw const FormatException('同步设置无效。');
    }
    for (final name in ['deleted', 'deletedFiles']) {
      final values = data[name];
      if (values != null &&
          (values is! Map ||
              values.entries.any(
                (entry) =>
                    entry.key is! String ||
                    entry.value is! String ||
                    DateTime.tryParse(entry.value as String) == null,
              ))) {
        throw const FormatException('同步删除记录无效。');
      }
    }
    if (incoming.any(
      (e) =>
          e.online == null && e.files.isEmpty ||
          e.files.length > 10000 ||
          e.online?.local == true ||
          e.files.any((f) => !RegExp(r'^[a-f0-9]{64}$').hasMatch(f.fileId)) ||
          !e.key.startsWith('series:') &&
              !RegExp(r'^file:[a-f0-9]{64}$').hasMatch(e.key),
    )) {
      throw const FormatException('同步记录无效。');
    }
    final localPaths = {
      for (final entry in _entries.values)
        for (final f in entry.files) f.fileId: f.path,
    };
    _readTimes(data['deleted'], _deleted);
    _readTimes(data['deletedFiles'], _deletedFiles);
    final settingTime = DateTime.tryParse(
      data['limitUpdated'] as String? ?? '',
    );
    if (settingTime != null &&
        settingTime.isAfter(limitUpdated) &&
        data['limit'] is int) {
      limit = (data['limit'] as int).clamp(1, 10000);
      limitUpdated = settingTime;
    }
    for (final remote in incoming) {
      final old = _entries[remote.key];
      final chosen =
          old == null ||
              remote.updated.isAfter(old.updated) ||
              remote.updated.isAtSameMomentAs(old.updated) &&
                  _entryOrder(remote).compareTo(_entryOrder(old)) > 0
          ? remote
          : old;
      final files = <String, WatchPoint>{};
      for (final entry in [?old, remote]) {
        for (final point in entry.files) {
          final date = point.modified ?? entry.updated;
          final prior = files[point.fileId];
          if (prior == null ||
              date.isAfter(prior.modified!) ||
              date.isAtSameMomentAs(prior.modified!) &&
                  point.positionMs > prior.positionMs) {
            files[point.fileId] = point.copy()
              ..modified = date
              ..watched = point.watched || (prior?.watched ?? false);
          } else {
            prior.watched = prior.watched || point.watched;
          }
        }
      }
      final merged = WatchEntry.fromJson(chosen.toJson());
      if (merged.online?.cover.isEmpty == true &&
          old?.online?.dramaId == merged.online?.dramaId) {
        merged.online!.cover = old!.online!.cover;
      }
      if (old?.online?.dramaId == remote.online?.dramaId &&
          merged.online != null) {
        merged.online!.watched =
            (old?.online?.watched ?? false) ||
            (remote.online?.watched ?? false);
      }
      merged.files.clear();
      for (final file in files.values) {
        if (_deletedFiles[file.fileId] != null &&
            !_deletedFiles[file.fileId]!.isBefore(file.modified!)) {
          continue;
        }
        file.path = localPaths[file.fileId] ?? '';
        merged.files.add(file);
      }
      merged.activePath = '';
      if (merged.online != null || merged.files.isNotEmpty) {
        _entries[merged.key] = merged;
      }
    }
    for (final entry in _entries.values) {
      entry.files.removeWhere(
        (f) =>
            _deletedFiles[f.fileId] != null &&
            !_deletedFiles[f.fileId]!.isBefore(f.modified ?? entry.updated),
      );
    }
    _entries.removeWhere(
      (key, entry) =>
          entry.online == null && entry.files.isEmpty ||
          _deleted[key] != null && !_deleted[key]!.isBefore(entry.updated),
    );
    _trim();
    _changed();
  }

  void linkFile(WatchPoint point, String path) {
    final linked = point.copy()..path = path;
    record(linked);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
