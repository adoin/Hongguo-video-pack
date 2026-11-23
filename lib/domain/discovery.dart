class DramaSummary {
  const DramaSummary({
    required this.id,
    required this.title,
    this.cover = '',
    this.intro = '',
    this.episodes = 0,
    this.tags = const [],
    this.rank = 0,
    this.heat = '',
    this.plays = '',
    this.firstEpisodeId = '',
    this.vertical,
  });
  final String id, title, cover, intro, heat, plays;
  final String firstEpisodeId;
  final bool? vertical;
  final int episodes, rank;
  final List<String> tags;
  String get metric => heat.isNotEmpty
      ? (heat.contains('热度') ? heat : '$heat 热度')
      : plays.isNotEmpty
      ? '$plays 次播放'
      : '';
  DramaSummary withMetrics({String? heat, String? plays}) =>
      withMetadata(heat: heat, plays: plays);

  DramaSummary withMetadata({String? cover, String? heat, String? plays}) =>
      DramaSummary(
        id: id,
        title: title,
        cover: cover ?? this.cover,
        intro: intro,
        episodes: episodes,
        tags: tags,
        rank: rank,
        heat: heat ?? this.heat,
        plays: plays ?? this.plays,
        firstEpisodeId: firstEpisodeId,
        vertical: vertical,
      );
}

class DiscoveryPage {
  const DiscoveryPage(
    this.items, {
    this.page = 1,
    this.pages = 1,
    this.total = 0,
    this.updated = '',
    this.scope = '',
    this.canExpand = false,
    this.sourceTotal = 0,
    this.totalPagesKnown = true,
    this.cursor,
  });
  final List<DramaSummary> items;
  final int page, pages, total;
  final String updated, scope;
  final bool canExpand;
  final bool totalPagesKnown;
  final String? cursor;
  final int sourceTotal;
  bool get hasMore => page < pages;
}

String seriesKeyword(String title) => title
    .replaceAll(RegExp(r'[：:]?\s*第[一二三四五六七八九十百零〇两\d]+[季部卷篇].*$'), '')
    .trim();
