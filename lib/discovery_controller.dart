import 'dart:math';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'data/discovery_client.dart';
import 'domain/discovery.dart';
import 'services/app_logs.dart';

enum DiscoveryMode { ranking, search, comic, random, related }

class DiscoveryController extends ChangeNotifier {
  DiscoveryController({DiscoveryClient? client})
    : client = client ?? DiscoveryClient();
  final DiscoveryClient client;
  DiscoveryMode mode = DiscoveryMode.ranking;
  String board = 'hot-drama', category = 'comic-drama', query = '';
  String? relatedId, error;
  bool loading = false, expandedSearch = false;
  int indexedCount = 0;
  DiscoveryPage? result;
  List<DramaSummary> items = [];
  int _request = 0;
  bool _disposed = false;
  final _random = Random();
  final _seen = <String>{};
  final _randomPages = <String, int>{};

  Future<void> show(
    DiscoveryMode value, {
    String? keyword,
    String? excludeId,
  }) async {
    mode = value;
    expandedSearch = false;
    query = keyword ?? query;
    if (value != DiscoveryMode.related || excludeId != null) {
      relatedId = excludeId;
    }
    result = null;
    items = [];
    await refresh();
  }

  Future<void> expandSearch() async {
    expandedSearch = true;
    await refresh();
  }

  Future<void> refresh({bool more = false, int? searchPage}) async {
    final token = ++_request;
    final requestedMode = mode;
    final requestedCategory = category;
    final requestedQuery = query;
    if (!more &&
        {DiscoveryMode.search, DiscoveryMode.related}.contains(requestedMode)) {
      items = [];
      result = null;
    }
    loading = true;
    error = null;
    indexedCount = 0;
    client.onIndexProgress = (count) {
      if (!_disposed && token == _request) {
        indexedCount = count;
        notifyListeners();
      }
    };
    notifyListeners();
    try {
      AppLogs.shared.add(LogLevel.info, '发现', '开始读取 ${requestedMode.name}');
      final page = more && result != null ? result!.page + 1 : 1;
      DiscoveryPage data;
      switch (requestedMode) {
        case DiscoveryMode.ranking:
          data = await client.ranking(board, page: page);
        case DiscoveryMode.search:
        case DiscoveryMode.related:
          data = await client.search(
            requestedQuery,
            page: searchPage ?? 1,
            expanded: expandedSearch,
            refresh: searchPage == null,
            relatedTo: requestedMode == DiscoveryMode.related
                ? relatedId
                : null,
          );
        case DiscoveryMode.comic:
          data = await client.category('comic-drama', page: page);
        case DiscoveryMode.random:
          final count = _randomPages[requestedCategory];
          final first = await client.category(
            requestedCategory,
            page: count == null ? 1 : 1 + _random.nextInt(count),
          );
          _randomPages[requestedCategory] = first.pages.clamp(1, 500);
          data = count == null && first.pages > 1
              ? await client.category(
                  requestedCategory,
                  page: 2 + _random.nextInt(first.pages - 1),
                )
              : first;
      }
      if (_disposed || token != _request) return;
      var rows = data.items;
      if (requestedMode == DiscoveryMode.random) {
        final unseen = rows.where((d) => !_seen.contains(d.id)).toList()
          ..shuffle(_random);
        rows = unseen.take(12).toList();
        // Exhausting a sampled page is visible; don't pretend old picks are new.
        _seen.addAll(rows.map((d) => d.id));
        if (_seen.length > 2000) _seen.clear();
      }
      final old = more ? items : <DramaSummary>[];
      final ids = old.map((d) => d.id).toSet();
      items = [...old, ...rows.where((d) => ids.add(d.id))];
      result = data;
      if ({
            DiscoveryMode.search,
            DiscoveryMode.related,
          }.contains(requestedMode) &&
          items.any((d) => d.metric.isEmpty || needsCoverLookup(d.cover))) {
        unawaited(_enrich(items.toList(), token));
      }
    } catch (e) {
      AppLogs.shared.add(
        LogLevel.error,
        '发现',
        '来源读取失败（${requestedMode.name}）',
        error: e,
      );
      if (!_disposed && token == _request) {
        error = e is FormatException
            ? e.message
            : e is StateError
            ? e.message.toString()
            : '读取失败，请检查网络后重试。来源页面也可能暂时不可用。';
      }
    } finally {
      if (!_disposed && token == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _enrich(List<DramaSummary> rows, int token) async {
    try {
      final updated = await client.enrichMetrics(
        rows,
        shouldContinue: () => !_disposed && token == _request,
        onUpdated: (updated) {
          if (_disposed || token != _request) return;
          items = updated;
          notifyListeners();
        },
      );
      if (_disposed || token != _request) return;
      items = updated;
      notifyListeners();
    } catch (_) {
      /* Missing covers/statistics never hide a valid search result. */
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    client.close();
    super.dispose();
  }
}
