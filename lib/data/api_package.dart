import 'dart:convert';
import 'dart:typed_data';

enum PlaybackProvider { openhongguo, legacy }

/// A versioned data package. It cannot introduce code, origins or HTTP methods.
final class ApiPackage {
  ApiPackage._(this.version, this.search, this.recommendations, this.playback);

  static const maxBytes = 16 * 1024;
  static const webHost = 'hongguoduanju.com';
  static final _version = RegExp(
    r'^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$',
  );
  static final _path = RegExp(r'^(?:/[a-zA-Z0-9_-]+)+/?$');
  static final _field = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,31}$');

  final String version;
  final Map<String, String> search, recommendations;
  final List<PlaybackProvider> playback;

  static final bundled = ApiPackage._(
    '0.0.0',
    const {
      'path': '/api/search/result',
      'keyword': 'query',
      'page': 'page',
      'items': 'searchList',
      'currentPage': 'pageNum',
      'totalPages': 'totalPages',
      'total': 'totalCount',
    },
    const {
      'path': '/detail',
      'series': 'series_id',
      'group': 'recommendationGroups',
      'items': 'related_list',
    },
    const [PlaybackProvider.openhongguo],
  );

  factory ApiPackage.decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Invalid API package size');
    }
    final data = _section(jsonDecode(utf8.decode(bytes)), {
      'schema',
      'version',
      'search',
      'recommendations',
      'playback',
    });
    final version = data['version'];
    if (data['schema'] is! int ||
        data['schema'] != 1 ||
        version is! String ||
        !_version.hasMatch(version)) {
      throw const FormatException('Unsupported API package version');
    }
    final search = _rules(data['search'], {
      'path',
      'keyword',
      'page',
      'items',
      'currentPage',
      'totalPages',
      'total',
    });
    final related = _rules(data['recommendations'], {
      'path',
      'series',
      'group',
      'items',
    });
    if (search['keyword'] == search['page'] ||
        search['keyword'] == 'aid' ||
        search['page'] == 'aid') {
      throw const FormatException('Conflicting search query fields');
    }
    final raw = data['playback'];
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > PlaybackProvider.values.length) {
      throw const FormatException('Invalid playback rules');
    }
    final playback = <PlaybackProvider>[];
    for (final value in raw) {
      final provider = switch (value) {
        'openhongguo' => PlaybackProvider.openhongguo,
        'legacy' => PlaybackProvider.legacy,
        _ => throw const FormatException('Unsupported playback provider'),
      };
      if (playback.contains(provider)) {
        throw const FormatException('Duplicate playback provider');
      }
      playback.add(provider);
    }
    return ApiPackage._(version, search, related, List.unmodifiable(playback));
  }

  static bool isVersion(String value) => _version.hasMatch(value);

  static int compareVersions(String left, String right) {
    final a = left.split('.');
    final b = right.split('.');
    for (var i = 0; i < 3; i++) {
      final cmp = int.parse(a[i]).compareTo(int.parse(b[i]));
      if (cmp != 0) return cmp;
    }
    return 0;
  }

  Uri searchUri(String keyword, int page) =>
      Uri.https(webHost, search['path']!, {
        'aid': '8662',
        search['keyword']!: keyword,
        if (page > 1) search['page']!: '$page',
      });

  Uri recommendationsUri(String seriesId) => Uri.https(
    webHost,
    recommendations['path']!,
    {recommendations['series']!: seriesId},
  );

  static Map<String, dynamic> _section(Object? value, Set<String> fields) {
    if (value is! Map<String, dynamic> ||
        value.length != fields.length ||
        !value.keys.every(fields.contains)) {
      throw const FormatException('Unknown or missing API package fields');
    }
    return value;
  }

  static Map<String, String> _rules(Object? value, Set<String> fields) {
    final data = _section(value, fields);
    return Map.unmodifiable(
      data.map((key, rule) {
        if (rule is! String ||
            rule.length > 128 ||
            !(key == 'path' ? _path : _field).hasMatch(rule)) {
          throw const FormatException('Invalid API package rule');
        }
        return MapEntry(key, rule);
      }),
    );
  }
}
