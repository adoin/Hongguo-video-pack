class Episode {
  const Episode(this.id, this.number);
  final String id;
  final int number;
}

class Drama {
  const Drama({
    required this.id,
    required this.title,
    required this.episodes,
    this.cover = '',
    this.intro = '',
    this.source = 'App 接口',
  });
  final String id, title, cover, intro, source;
  final List<Episode> episodes;
}

class MediaVariant {
  const MediaVariant({
    required this.url,
    required this.quality,
    required this.codec,
    this.key,
    this.duration = 0,
    this.downloadable = true,
    this.source = 'App 接口',
    this.width = 0,
    this.height = 0,
    this.rotation = 0,
    this.sizeBytes = 0,
  });
  final String url, codec;
  final String? key;
  final int quality;
  final double duration;
  final bool downloadable;
  final String source;
  final int width, height, rotation, sizeBytes;
  double? get aspectRatio => width <= 0 || height <= 0
      ? null
      : rotation.abs() % 180 == 90
      ? height / width
      : width / height;
  String get label => '${quality}P · ${codec.toUpperCase()}';
}

MediaVariant chooseQuality(List<MediaVariant> variants, int target) {
  if (variants.isEmpty) throw StateError('没有可用的清晰度');
  final ordered = [...variants]..sort((a, b) => b.quality.compareTo(a.quality));
  if (target == 0) return ordered.first;
  return ordered.firstWhere(
    (v) => v.quality <= target,
    orElse: () => ordered.last,
  );
}

String seriesIdFromInput(String input) {
  final value = input.trim();
  if (RegExp(r'^\d{1,32}$').hasMatch(value)) return value;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      !{'hongguoduanju.com', 'www.hongguoduanju.com'}.contains(uri.host)) {
    throw const FormatException('请输入红果播放页链接或数字剧集 ID');
  }
  final parts = uri.pathSegments;
  final id = parts.length >= 2 && parts.first == 'player'
      ? parts[1]
      : uri.queryParameters['series_id'] ?? '';
  if (!RegExp(r'^\d{1,32}$').hasMatch(id)) {
    throw const FormatException('链接中没有有效的剧集 ID');
  }
  return id;
}
