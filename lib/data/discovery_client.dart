import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../domain/discovery.dart';
import 'hongguo_client.dart' show object, text, integer, Json;
import 'app_search_client.dart';
import 'signed_app_search.dart';

/// Public catalogue pages only. Opening a result still loads the full episode
/// list through HongguoClient, never the preview-only IDs from a catalogue.
class DiscoveryClient {
  DiscoveryClient({
    http.Client? client,
    this.appSearch,
    this.searchTimeout = const Duration(seconds: 15),
  }) : _http = client ?? http.Client();
  final http.Client _http;
  AppSearchClient? appSearch;
  final Duration searchTimeout;
  Future<void>? _searchReady;
  bool _appUnavailable = false;
  final _searchBackends = <String, _SearchBackend>{};

  Future<bool> prepareSearchIdentity(Future<File> file) {
    final operation = file.then(loadSearchIdentity);
    _searchReady = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<bool> loadSearchIdentity(File file) async {
    appSearch = null;
    if (!await file.exists()) return false;
    if (await file.length() > 4096) throw const FormatException('本机搜索初始化信息无效');
    final data = object(jsonDecode(await file.readAsString()));
    if (data['version'] != 1) throw const FormatException('本机搜索初始化信息版本不兼容');
    final identity = SearchVisitorIdentity(
      deviceId: text(data['device_id']),
      installId: text(data['iid']),
    );
    final transport = SignedAppSearchTransport(
      identity: identity,
      client: _http,
    );
    appSearch = AppSearchClient(transport.call);
    _appUnavailable = false;
    return true;
  }

  Future<http.Response> _searchResponse(Uri uri) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final abort = Completer<void>();
      try {
        final request =
            http.AbortableRequest('GET', uri, abortTrigger: abort.future)
              ..headers.addAll(const {
                'Accept': 'application/json',
                'User-Agent': 'Mozilla/5.0',
                'Referer': 'https://hongguoduanju.com/',
                'Cache-Control': 'no-cache',
              });
        final response = await _http
            .send(request)
            .then(http.Response.fromStream)
            .timeout(searchTimeout);
        if (attempt == 0 && {502, 503, 504}.contains(response.statusCode)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        return response;
      } catch (error) {
        final transient =
            error is TimeoutException ||
            error is SocketException ||
            error is http.ClientException;
        if (!transient || attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      } finally {
        if (!abort.isCompleted) abort.complete();
      }
    }
    throw StateError('搜索暂不可用，请重试。');
  }

  static const boards = {
    'hot-drama': '总热播榜',
    'hot-real-drama': '真人剧榜',
    'hot-comic-drama': '漫剧榜',
    'hot-ai-drama': 'AI 剧榜',
  };
  static const categories = {
    'comic-drama': '漫剧',
    'real-drama': '真人剧',
    'ai-drama': 'AI 剧',
  };

  Future<String> _get(String path, [Map<String, String>? query]) async {
    final response = await _http
        .get(
          Uri.https('hongguoduanju.com', path, query),
          headers: {'Accept': 'text/html', 'User-Agent': 'Mozilla/5.0'},
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw StateError('剧库暂不可用（HTTP ${response.statusCode}），请重试');
    }
    return utf8.decode(response.bodyBytes);
  }

  File? indexCache;
  void Function(int)? onIndexProgress;
  Future<List<DramaSummary>>? _index;
  DateTime? _indexTime;
  final _searches = <String, List<DramaSummary>>{};
  final _webSessions = <String, Map<int, Set<String>>>{};
  final _details = <String, Future<Json?>>{};

  Future<List<DramaSummary>> _catalogue() async {
    if (_indexTime != null &&
        DateTime.now().difference(_indexTime!).inMinutes >= 30) {
      _index = null;
    }
    final pending = _index ??= _loadIndex();
    try {
      return await pending;
    } catch (_) {
      if (identical(_index, pending)) _index = null;
      rethrow;
    }
  }

  Future<List<DramaSummary>> _loadIndex() async {
    final cache = indexCache;
    if (cache != null && await cache.exists()) {
      try {
        final data = object(jsonDecode(await cache.readAsString()));
        final date = DateTime.parse(text(data['time']));
        final age = DateTime.now().difference(date);
        if (data['version'] == 1 && !age.isNegative && age.inMinutes < 30) {
          final rows = parseSummaries(data['items']);
          _indexTime = date;
          onIndexProgress?.call(rows.length);
          return rows;
        }
      } catch (_) {
        /* A broken cache is rebuilt from the source. */
      }
    }
    final rows = <String, DramaSummary>{};
    // Three sequential feeds, bounded to three HTTP requests in flight.
    await Future.wait(
      categories.keys.map((key) async {
        var page = 1;
        var pages = 1;
        final seen = <String>{};
        do {
          final data = await category(key, page: page);
          if (data.pages > 100 || data.pages < page || data.items.isEmpty) {
            throw const FormatException('分类片库不完整，请稍后重试');
          }
          final fresh = data.items.where((d) => seen.add(d.id)).toList();
          if (fresh.isEmpty) throw const FormatException('来源重复返回相同页面，已停止检索');
          for (final row in fresh) {
            rows[row.id] = row;
          }
          onIndexProgress?.call(rows.length);
          pages = data.pages;
          page++;
        } while (page <= pages);
      }),
    );
    _indexTime = DateTime.now();
    final items = rows.values.toList();
    if (cache != null) {
      try {
        final data = {
          'version': 1,
          'time': _indexTime!.toIso8601String(),
          'items': [
            for (final d in items)
              {
                'series_id': d.id,
                'series_title': d.title,
                'series_cover': d.cover,
                'series_intro': d.intro,
                'episode_cnt': d.episodes,
                'tags': d.tags,
              },
          ],
        };
        await cache.parent.create(recursive: true);
        final temporary = File('${cache.path}.tmp');
        await temporary.writeAsString(jsonEncode(data), flush: true);
        await temporary.rename(cache.path);
      } catch (_) {
        /* In-memory search remains available. */
      }
    }
    return items;
  }

  Future<DiscoveryPage> search(
    String keyword, {
    int page = 1,
    String? relatedTo,
    bool expanded = false,
    bool refresh = true,
  }) async {
    keyword = keyword.trim();
    if (keyword.isEmpty ||
        keyword.runes.length > 80 ||
        RegExp(r'[\x00-\x1f]').hasMatch(keyword) ||
        page < 1 ||
        page > 500) {
      throw const FormatException('请输入 1 至 80 个字符的剧名');
    }
    final key = '$keyword|${relatedTo ?? ''}|${expanded ? 'catalogue' : 'web'}';
    if (!expanded) {
      await _searchReady;
      if (_searchBackends.length >= 16 && !_searchBackends.containsKey(key)) {
        _searchBackends.remove(_searchBackends.keys.first);
      }
      if (page == 1 && refresh) _searchBackends.remove(key);
      final backend = _searchBackends.putIfAbsent(
        key,
        () => _SearchBackend(
          _appUnavailable || relatedTo != null ? null : appSearch,
        ),
      );
      final app = backend.app;
      if (app != null) {
        try {
          return await app.search(keyword, page: page, refresh: refresh);
        } catch (_) {
          if (!identical(_searchBackends[key], backend) || page != 1) rethrow;
          // Preserve the on-disk identity. An unavailable legacy source must not
          // disable the new public search or change backend during pagination.
          _appUnavailable = true;
          backend.app = null;
        }
      }
      if (page == 1 && refresh) _webSessions.remove(key);
      if (_webSessions.length >= 16 && !_webSessions.containsKey(key)) {
        _webSessions.remove(_webSessions.keys.first);
      }
      final session = _webSessions.putIfAbsent(key, () => {});
      final response = await _searchResponse(
        Uri.https('hongguoduanju.com', '/api/search/result', {
          'aid': '8662',
          'query': keyword,
          if (page > 1) 'page': '$page',
        }),
      );
      if (response.statusCode == 403) {
        throw StateError('搜索暂时需要来源验证，请稍后重试。');
      }
      if (response.statusCode != 200) {
        throw StateError('搜索暂不可用（HTTP ${response.statusCode}），请重试。');
      }
      Json data;
      try {
        data = object(jsonDecode(utf8.decode(response.bodyBytes)));
      } on FormatException {
        throw const FormatException('搜索响应无效，请稍后重试。');
      }
      if (data['searchList'] is! List ||
          integer(data['pageNum']) != page ||
          integer(data['totalPages']) < 0) {
        throw const FormatException('搜索数据格式已变化，请稍后重试');
      }
      var rows = parseSummaries(
        (data['searchList'] as List)
            .where(
              (row) =>
                  object(row)['video_data'] is Map ||
                  object(row)['series_id'] != null,
            )
            .toList(),
      );
      if (!identical(_webSessions[key], session)) {
        throw StateError('搜索已被新请求替代');
      }
      final preceding = {
        for (final entry in session.entries)
          if (entry.key < page) ...entry.value,
      };
      final fresh = rows.where((row) => !preceding.contains(row.id)).toList();
      if (rows.isNotEmpty && fresh.isEmpty) {
        throw StateError('来源重复返回相同结果，请重新搜索。');
      }
      session[page] = rows.map((row) => row.id).toSet();
      rows = fresh;
      if (relatedTo != null) {
        rows = rows
            .where(
              (d) =>
                  d.id != relatedTo &&
                  _title(seriesKeyword(d.title)) ==
                      _title(seriesKeyword(keyword)),
            )
            .toList();
      }
      // Preserve the source ranking. No catalogue scan or metric requests on
      // this critical path; publish results as soon as this one request returns.
      return DiscoveryPage(
        rows,
        page: page,
        pages: integer(data['totalPages']).clamp(page, 500),
        total: integer(data['totalCount']),
        sourceTotal: integer(data['totalCount']),
        scope: '红果官网搜索',
      );
    }
    var matches = _searches[key] ?? <DramaSummary>[];
    if (page == 1 || !_searches.containsKey(key)) {
      if (page > 1) throw StateError('搜索已过期，请重新搜索');
      final indexed = await _catalogue();
      final needle = _title(keyword);
      matches = indexed.where((d) => _title(d.title).contains(needle)).toList();
      // Supplement the indexed catalogue with the website's first search batch.
      // Never use its reported total as a page count: ?page=2 repeats page 1.
      try {
        final html = await _get('/search/$keyword');
        final data = routerPage(html, 'search_');
        if (data['isSuccess'] == true && data['query'] == keyword) {
          final merged = {for (final d in matches) d.id: d};
          for (final d in parseSummaries(data['searchList'])) {
            if (_title(d.title).contains(needle)) merged[d.id] = d;
          }
          matches = merged.values.toList();
        }
      } catch (_) {
        /* Catalogue results remain complete within their stated scope. */
      }
      if (relatedTo != null) {
        matches = matches
            .where(
              (d) =>
                  d.id != relatedTo &&
                  _title(seriesKeyword(d.title)) ==
                      _title(seriesKeyword(keyword)),
            )
            .toList();
      }
      matches.sort((a, b) {
        final scoreA = _title(a.title) == needle
            ? 0
            : _title(a.title).startsWith(needle)
            ? 1
            : 2;
        final scoreB = _title(b.title) == needle
            ? 0
            : _title(b.title).startsWith(needle)
            ? 1
            : 2;
        return scoreA == scoreB
            ? a.title.compareTo(b.title)
            : scoreA.compareTo(scoreB);
      });
      if (_searches.length >= 16) _searches.remove(_searches.keys.first);
      _searches[key] = matches;
    }
    const size = 20;
    final pages = ((matches.length + size - 1) ~/ size).clamp(1, 500);
    if (page > pages) throw StateError('没有更多搜索结果');
    return DiscoveryPage(
      matches.skip((page - 1) * size).take(size).toList(),
      page: page,
      pages: pages,
      total: matches.length,
      scope: '官网分类片库索引＋搜索首批补充 · 非全站完整索引',
    );
  }

  String _title(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s：:，,。.!！?？·《》、（）()\-]'), '');

  Future<List<DramaSummary>> enrichMetrics(
    List<DramaSummary> rows, {
    void Function(List<DramaSummary>)? onUpdated,
    bool Function()? shouldContinue,
  }) async {
    final results = [...rows];
    var next = 0;
    await Future.wait(
      List.generate(3, (_) async {
        while (next < rows.length) {
          if (shouldContinue?.call() == false) return;
          final i = next++;
          final row = rows[i];
          if (row.metric.isNotEmpty && !needsCoverLookup(row.cover)) continue;
          results[i] = await _readMetrics(row);
          if (shouldContinue?.call() != false) onUpdated?.call([...results]);
        }
      }),
    );
    return results;
  }

  Future<DramaSummary> _readMetrics(DramaSummary row) async {
    if (_details.length >= 500 && !_details.containsKey(row.id)) {
      _details.clear();
    }
    final pending = _details.putIfAbsent(row.id, () => _loadDetails(row.id));
    final page = await pending;
    if (page == null) {
      // A transient failure must be retried on the next user refresh.
      if (identical(_details[row.id], pending)) _details.remove(row.id);
      return row;
    }
    final detail = object(page['seriesDetail']);
    final candidate = text(detail['series_cover']);
    final uri = Uri.tryParse(candidate);
    final useCover =
        needsCoverLookup(row.cover) &&
        candidate.isNotEmpty &&
        !needsCoverLookup(candidate) &&
        uri != null &&
        {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty;
    final social = object(page['seriesSocialInfo']);
    return row.withMetadata(
      cover: useCover ? candidate : null,
      heat: row.heat.isNotEmpty ? row.heat : heatMetric(social),
      plays: row.plays.isNotEmpty
          ? row.plays
          : countMetric(social['series_play_cnt'] ?? social['play_cnt']),
    );
  }

  Future<Json?> _loadDetails(String id) async {
    try {
      final html = await _get('/detail', {'series_id': id});
      final page = routerPage(html, 'detail_page');
      final detail = object(page['seriesDetail']);
      if (text(detail['series_id_str'] ?? detail['series_id']) != id) {
        return null;
      }
      return page;
    } catch (_) {
      return null;
    }
  }

  Future<List<DramaSummary>> recommendations(String id) async {
    if (!RegExp(r'^\d{1,32}$').hasMatch(id)) {
      throw const FormatException('剧集 ID 无效');
    }
    final html = await _get('/detail', {'series_id': id});
    final page = routerPage(html, 'detail_page');
    final detail = object(page['seriesDetail']);
    if (text(detail['series_id_str'] ?? detail['series_id']) != id) {
      throw const FormatException('相关剧集来源不匹配');
    }
    for (final tag in RegExp(
      r'<script\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final attr = RegExp(r'data-fn-args="([^"]+)"').firstMatch(tag.group(0)!);
      if (attr == null) continue;
      try {
        final args = jsonDecode(decodeAttribute(attr[1]!));
        if (args is! List ||
            args.length < 2 ||
            args[0] != 'detail_page' ||
            args[1] is! List) {
          continue;
        }
        for (final raw in args[1] as List) {
          final item = object(raw);
          if (item['key'] != 'recommendations') continue;
          final values = item['routerDataFnArgs'];
          if (values is! List || values.isEmpty || values.first is! String) {
            continue;
          }
          final data = object(jsonDecode(values.first as String));
          final groups = object(data['recommendationGroups']);
          final rows = groups['related_list'];
          if (rows is List) {
            return parseSummaries(rows).where((row) => row.id != id).toList();
          }
        }
      } catch (_) {
        continue;
      }
    }
    return [];
  }

  Future<DiscoveryPage> ranking(String board, {int page = 1}) async {
    if (!boards.containsKey(board) || page < 1 || page > 500) {
      throw const FormatException('榜单参数无效');
    }
    final html = await _get('/rank/$board', {'page': '$page'});
    return parseRanking(html, board, page);
  }

  Future<DiscoveryPage> category(String category, {int page = 1}) async {
    if (!categories.containsKey(category) || page < 1 || page > 500) {
      throw const FormatException('分类参数无效');
    }
    final html = await _get('/category/$category', {'page': '$page'});
    final data = routerPage(html, 'category_\$');
    final pagination = object(data['pagination']);
    if (data['isSuccess'] != true ||
        data['recommendList'] is! List ||
        integer(pagination['pageNum']) != page) {
      throw const FormatException('分类数据格式已变化，请稍后重试');
    }
    return DiscoveryPage(
      parseSummaries(data['recommendList']),
      page: page,
      pages: integer(pagination['totalPages']),
      total: integer(pagination['total']),
    );
  }

  void close() => _http.close();
}

/// App covers can be signed HEIC/HEIF URLs. Changing their suffix invalidates
/// the signature; resolve a compatible cover through this series' detail page.
bool needsCoverLookup(String address) {
  if (address.isEmpty) return true;
  final path = Uri.tryParse(address)?.path.toLowerCase() ?? '';
  return path.endsWith('.heic') || path.endsWith('.heif');
}

class _SearchBackend {
  _SearchBackend(this.app);
  AppSearchClient? app;
}

Json routerPage(String html, String prefix) {
  final match = RegExp(r'(?:window\.)?_ROUTER_DATA\s*=\s*').firstMatch(html);
  if (match == null) throw const FormatException('剧库页面缺少数据');
  final value = balancedJson(html, html.indexOf('{', match.end));
  final loader = object(object(jsonDecode(value))['loaderData']);
  for (final entry in loader.entries) {
    if (entry.key.startsWith(prefix) && entry.value is Map) {
      return object(entry.value);
    }
  }
  throw const FormatException('剧库页面格式已变化');
}

String balancedJson(String source, int start) {
  if (start < 0) throw const FormatException('页面数据不完整');
  var depth = 0, quoted = false, escaped = false;
  for (var i = start; i < source.length; i++) {
    final c = source[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}' && --depth == 0) {
      return source.substring(start, i + 1);
    }
  }
  throw const FormatException('页面数据不完整');
}

String decodeAttribute(String value) => value
    .replaceAll('&quot;', '"')
    .replaceAll('&#34;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

DiscoveryPage parseRanking(String html, String board, int page) {
  final route = 'rank_$board/page';
  final loader = routerPage(html, route);
  if (integer(loader['pageNum']) != page) {
    throw const FormatException('榜单分页不匹配');
  }
  var content = object(loader['content']);
  if (content.isEmpty) {
    for (final tag in RegExp(
      r'<script\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final attrs = <String, String>{};
      for (final m in RegExp(
        r'''([\w-]+)=["'](.*?)["'](?=\s|>)''',
        dotAll: true,
      ).allMatches(tag[0]!)) {
        attrs[m[1]!] = decodeAttribute(m[2]!);
      }
      final raw = attrs['data-fn-args'];
      if (raw == null) continue;
      final name = attrs['data-fn-name'];
      if (name != 'mergeLoaderData' && name != 'r') continue;
      final args = jsonDecode(raw) as List;
      if (args.isEmpty || args.first != route) continue;
      if (name == 'r' && args.length == 3 && args[1] == 'content') {
        content = object(args[2]);
      } else if (name == 'mergeLoaderData' &&
          args.length == 2 &&
          args[1] is List) {
        for (final field in args[1]) {
          final f = object(field);
          if (f['key'] == 'content' && f['routerDataFnName'] == 'p') {
            final values = f['routerDataFnArgs'] as List? ?? [];
            if (values.length == 1 && values.first is String) {
              content = object(jsonDecode(values.first as String));
            }
          }
        }
      }
      if (content.isNotEmpty) break;
    }
  }
  final pagination = object(content['pagination']);
  if (content['isSuccess'] != true ||
      content['rankList'] is! List ||
      integer(pagination['pageNum']) != page ||
      integer(pagination['totalPages']) < page) {
    throw const FormatException('榜单数据格式已变化，请稍后重试');
  }
  return DiscoveryPage(
    parseSummaries(content['rankList']),
    page: page,
    pages: integer(pagination['totalPages']),
    updated: text(loader['updatedText']),
  );
}

List<DramaSummary> parseSummaries(dynamic value) {
  if (value is! List) throw const FormatException('剧集列表格式异常');
  final seen = <String>{};
  final result = <DramaSummary>[];
  for (final row in value) {
    final outer = object(row);
    final item = outer['video_data'] is Map
        ? object(outer['video_data'])
        : outer;
    final id = text(
      item['series_id_str'] ??
          item['series_id'] ??
          item['seriesId'] ??
          item['id'],
    );
    final title = text(
      item['series_title'] ?? item['series_name'] ?? item['title'],
    );
    if (!RegExp(r'^\d{1,32}$').hasMatch(id) ||
        title.trim().isEmpty ||
        !seen.add(id)) {
      continue;
    }
    final tags = <String>[
      for (final t in item['tags'] as List? ?? [])
        if (t is String) t,
      for (final t in item['category_list'] as List? ?? [])
        text(object(t)['name']),
    ].where((s) => s.isNotEmpty).toSet().toList();
    final cover = text(
      item['series_cover'] ?? item['cover'],
    ).replaceAll(r'\u002F', '/');
    final uri = Uri.tryParse(cover);
    result.add(
      DramaSummary(
        id: id,
        title: title,
        cover: uri?.scheme == 'https' ? cover : '',
        intro: text(item['series_intro'] ?? item['description']),
        episodes: integer(
          item['episode_cnt'] ?? (item['episodeVids'] as List?)?.length,
        ),
        tags: tags,
        rank: integer(item['rank']),
        heat: heatMetric(item),
        plays: countMetric(item['series_play_cnt'] ?? item['play_cnt']),
      ),
    );
  }
  if (value.isNotEmpty && result.isEmpty) {
    throw const FormatException('列表未返回可识别的剧集');
  }
  return result;
}

String countMetric(dynamic value) {
  final raw = text(value);
  final number = num.tryParse(raw);
  if (number == null || !number.isFinite || number < 0) return '';
  if (number >= 100000000) return '${(number / 100000000).toStringAsFixed(1)}亿';
  if (number >= 10000) return '${(number / 10000).toStringAsFixed(1)}万';
  return number.toInt().toString();
}

String heatMetric(Json item) {
  final hot = object(item['hot_score_data']);
  final label = text(item['heatText'] ?? hot['text']);
  if (label.isNotEmpty && label != '未知') return label;
  return countMetric(hot['score']);
}
