import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../domain/drama.dart';
import 'request_signer.dart';
import 'media_crypto.dart';
import 'visitor_identity.dart';

typedef Json = Map<String, dynamic>;
Json object(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
String text(dynamic value) => value?.toString() ?? '';
int integer(dynamic value) => int.tryParse(text(value)) ?? 0;

Json decodeApiResponse(http.Response response) {
  if (response.statusCode != 200) {
    throw StateError('来源接口 HTTP ${response.statusCode}，请稍后重试');
  }
  if (response.bodyBytes.isEmpty) throw StateError('来源接口返回空数据，请稍后重试');
  final result = object(jsonDecode(utf8.decode(response.bodyBytes)));
  final code =
      result['Code'] ??
      result['code'] ??
      object(result['BaseResp'])['StatusCode'] ??
      0;
  if (text(code) != '0') throw StateError('来源暂不可用（$code），请稍后重试');
  return result;
}

List<MediaVariant> parsePlaybackInfo(Json info) {
  final raw = info['video_list'];
  final rows = raw is Map
      ? raw.values
      : raw is List
      ? raw
      : <dynamic>[];
  final results = <int, MediaVariant>{};
  for (final row in rows) {
    final item = object(row);
    final codec = text(item['codec_type']).toLowerCase();
    if ({'bytevc2', 'bvc2'}.contains(codec)) continue;
    final width = integer(item['vwidth'] ?? item['width']),
        height = integer(item['vheight'] ?? item['height']);
    final quality = width > 0 && height > 0
        ? min(width, height)
        : integer(
            RegExp(r'\d+').firstMatch(text(item['definition']))?.group(0),
          );
    if (quality <= 0 || text(item['main_url']).isEmpty) continue;
    final url = mediaAddress(text(item['main_url']), text(info['key_seed']));
    final key = text(item['spade_a']).isEmpty
        ? null
        : contentKey(text(item['spade_a']));
    final media = MediaVariant(
      url: url,
      quality: quality,
      codec: codec == 'bytevc1' ? 'hevc' : codec,
      key: key,
      duration: double.tryParse(text(info['video_duration'])) ?? 0,
    );
    if (!results.containsKey(quality) || {'h264', 'avc1'}.contains(codec)) {
      results[quality] = media;
    }
  }
  if (results.isEmpty) throw StateError('该集暂未返回兼容画质，请选择其他分集或稍后重试');
  return results.values.toList()
    ..sort((a, b) => b.quality.compareTo(a.quality));
}

/// App protocol adapter. No third-party parsing service or embedded account.
class HongguoClient {
  HongguoClient({
    http.Client? client,
    RequestSigner? signer,
    VisitorIdentityProvider? identities,
  }) : _http = client ?? http.Client(),
       identities = identities ?? VisitorIdentityStore.shared,
       signer = signer ?? NativeRequestSigner();
  final http.Client _http;
  final RequestSigner signer;
  final VisitorIdentityProvider identities;
  final String deviceId = _deviceId();
  final String installId = _deviceId();
  static const appHost = 'api5-normal-sinfonlineb.fqnovel.com';
  static String _deviceId() =>
      '7${List.generate(15, (_) => Random.secure().nextInt(10)).join()}';

  Future<Json> _post(String path, Json payload) async {
    final now = DateTime.now();
    final query = SplayTreeMap<String, String>.from({
      'aid': '8662',
      'app_name': 'novelread',
      'version_code': '73532',
      'version_name': '7.3.5.32',
      'manifest_version_code': '73532',
      'update_version_code': '73532',
      'channel': 'update_64',
      'device_platform': 'android',
      'os': 'android',
      'ssmix': 'a',
      'device_type': '25053RT47C',
      'device_brand': 'Redmi',
      'language': 'zh',
      'os_api': '36',
      'os_version': '16',
      'resolution': '1280*2772',
      'dpi': '520',
      'ac': 'wifi',
      'device_id': deviceId,
      'iid': installId,
      '_rticket': '${now.millisecondsSinceEpoch}',
    });
    final uri = Uri.https(appHost, path, query);
    final body = jsonEncode(payload);
    final response = await _http
        .post(
          uri,
          body: body,
          headers: {
            'User-Agent':
                'com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)',
            'Accept': 'application/json',
            'Content-Type': 'application/json; charset=utf-8',
            'X-XS-From-Web': '0',
            'Sdk-Version': '2',
            ...signRequest(uri.query, body, now),
          },
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw StateError('红果 App 接口 HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.isEmpty) throw StateError('红果 App 接口返回空数据');
    final result = object(jsonDecode(utf8.decode(response.bodyBytes)));
    final code = result['code'] ?? result['status_code'] ?? 0;
    if (text(code) != '0') throw StateError('红果 App 接口暂不可用（$code）');
    return result;
  }

  Future<Drama> fetchDrama(String input) async {
    final id = seriesIdFromInput(input);
    try {
      final result = await _post('/novel/player/video_detail/v1/', {
        'series_id': id,
      });
      return parseAppDrama(result, id);
    } catch (appError) {
      for (final uri in [
        Uri.https('hongguoduanju.com', '/detail', {'series_id': id}),
        Uri.https('hongguoduanju.com', '/player/$id'),
      ]) {
        try {
          final response = await _http
              .get(
                uri,
                headers: const {
                  'User-Agent': 'Mozilla/5.0',
                  'Accept': 'text/html',
                },
              )
              .timeout(const Duration(seconds: 25));
          if (response.statusCode != 200) {
            throw StateError('网页 HTTP ${response.statusCode}');
          }
          return parseWebDrama(utf8.decode(response.bodyBytes), id);
        } catch (_) {
          continue;
        }
      }
      throw StateError('读取剧集失败：$appError；网页回退也未返回有效分集');
    }
  }

  Future<List<MediaVariant>> fetchVariants(
    Episode episode, {
    String? seriesId,
  }) async {
    final visitor = await identities.get();
    try {
      return await _fetchVariants(episode, visitor);
    } on _RejectedVisitor {
      // Rebuild once only. A rejected new identity must not cause a retry loop.
      final replacement = await identities.get(rejected: visitor);
      try {
        return await _fetchVariants(episode, replacement);
      } on _RejectedVisitor {
        throw const VisitorInitializationException();
      }
    }
  }

  Future<List<MediaVariant>> _fetchVariants(
    Episode episode,
    RegisteredVisitor visitor,
  ) async {
    final body = jsonEncode({
      'biz_param': {
        'detail_page_version': 0,
        'device_level': 3,
        'disable_digg_stat': false,
        'need_all_video_definition': true,
        'need_mp4_align': false,
        'use_os_player': false,
        'use_server_dns': false,
        'video_platform': 1024,
      },
      'mixed_video_id_map': {
        '1004': [episode.id],
      },
    });
    final signed = await signer.sign(body, {
      ...visitor.parameters,
      'ac': 'wifi',
      'channel': 'update_64',
      'aid': '8662',
      'app_name': 'novelread',
      'version_code': '73532',
      'version_name': '7.3.5.32',
      'device_platform': 'android',
      'os': 'android',
      'ssmix': 'a',
      'device_type': '25053RT47C',
      'device_brand': 'Redmi',
      'language': 'zh',
      'os_api': '36',
      'os_version': '16',
      'manifest_version_code': '73532',
      'resolution': '1280*2772',
      'dpi': '520',
      'update_version_code': '73532',
      'host_abi': 'arm64-v8a',
      'dragon_device_type': 'phone',
      'pv_player': '71332',
      'compliance_status': '0',
      'need_personal_recommend': '1',
      'player_so_load': '1',
      'is_android_pad_screen': '0',
    });
    final response = await _http
        .post(signed.url, headers: signed.headers, body: signed.body)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 200 && response.bodyBytes.isEmpty) {
      throw const _RejectedVisitor();
    }
    final result = decodeApiResponse(response);
    final row = object(object(result['data'])[episode.id]);
    dynamic model = row['video_model'];
    if (model is String) model = jsonDecode(model);
    final map = object(model);
    dynamic fallback = map['fallback_api'];
    if (fallback is String && fallback.trimLeft().startsWith('{')) {
      fallback = jsonDecode(fallback);
    }
    if (fallback is Map) fallback = fallback['fallback_api'];
    if (fallback is List) fallback = fallback.firstOrNull;
    final url = Uri.tryParse(text(fallback));
    if (url == null ||
        url.scheme != 'https' ||
        ![
          'volcengineapi.com',
          'byteplusapi.com',
          'fqnovel.com',
          'snssdk.com',
          'qznovelvod.com',
        ].any((d) => url.host == d || url.host.endsWith('.$d'))) {
      throw StateError('视频信息入口不可用，请稍后重试');
    }
    final infoResponse = await _http
        .get(url)
        .timeout(const Duration(seconds: 30));
    final info = object(
      object(decodeApiResponse(infoResponse)['video_info'])['data'],
    );
    return parsePlaybackInfo(info);
  }

  void close() => _http.close();
}

class _RejectedVisitor implements Exception {
  const _RejectedVisitor();
}

Drama parseAppDrama(Json result, String expectedId) {
  final detail = object(object(result['data'])['video_data']);
  if (text(detail['series_id_str'] ?? detail['series_id']) != expectedId) {
    throw const FormatException('接口未返回所请求的剧集');
  }
  final rows = detail['video_list'] as List? ?? [];
  final episodes = rows.map((row) {
    final item = object(row);
    if (item['series_id'] != null && text(item['series_id']) != expectedId) {
      throw const FormatException('分集属于其他剧集');
    }
    final id = text(item['vid']);
    if (!RegExp(r'^\d{1,32}$').hasMatch(id)) {
      throw const FormatException('分集 ID 无效');
    }
    return Episode(id, integer(item['vid_index']));
  }).toList()..sort((a, b) => a.number.compareTo(b.number));
  if (episodes.isEmpty ||
      integer(detail['episode_cnt']) > episodes.length ||
      episodes.map((e) => e.id).toSet().length != episodes.length) {
    throw const FormatException('接口返回的分集不完整或重复');
  }
  for (var i = 0; i < episodes.length; i++) {
    if (episodes[i].number != i + 1) throw const FormatException('分集编号不连续');
  }
  return Drama(
    id: expectedId,
    title: text(detail['series_title'] ?? detail['series_name']),
    cover: text(detail['series_cover']),
    intro: text(detail['series_intro']),
    episodes: episodes,
  );
}

Drama parseWebDrama(String html, String expectedId) {
  final match = RegExp(r'(?:window\.)?_ROUTER_DATA\s*=\s*').firstMatch(html);
  if (match == null) throw const FormatException('网页数据结构已变更');
  // Decode only the balanced JSON object, never evaluate page JavaScript.
  final start = html.indexOf('{', match.end);
  var depth = 0, end = -1;
  var quoted = false, escaped = false;
  for (var i = start; i < html.length; i++) {
    final ch = html[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        quoted = false;
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}' && --depth == 0) {
      end = i + 1;
      break;
    }
  }
  if (start < 0 || end < 0) throw const FormatException('网页 JSON 不完整');
  final loader = object(
    object(jsonDecode(html.substring(start, end)))['loaderData'],
  );
  final page = loader.entries.where(
    (e) =>
        (e.key.startsWith('player_') || e.key == 'detail_page') &&
        object(e.value).containsKey('seriesDetail'),
  );
  if (page.isEmpty) throw const FormatException('网页没有剧集详情');
  final detail = object(object(page.first.value)['seriesDetail']);
  if (text(detail['series_id']) != expectedId) {
    throw const FormatException('网页返回了其他剧集');
  }
  final ids = detail['vid_list'] as List? ?? [];
  if (ids.isEmpty) throw const FormatException('网页没有分集');
  if (integer(detail['episode_cnt']) > ids.length) {
    throw const FormatException('网页未返回完整分集');
  }
  return Drama(
    id: expectedId,
    title: text(detail['series_name']),
    cover: text(detail['series_cover']),
    intro: text(detail['series_intro']),
    source: '网页详情回退',
    episodes: [
      for (var i = 0; i < ids.length; i++) Episode(text(ids[i]), i + 1),
    ],
  );
}

List<MediaVariant> parseVariants(Json model) {
  final raw = model['video_list'];
  final rows = raw is Map
      ? raw.values
      : raw is List
      ? raw
      : <dynamic>[];
  final variants = <int, MediaVariant>{};
  for (final row in rows) {
    final item = object(row), meta = object(object(row)['video_meta']);
    final codec = text(meta['codec_type']).toLowerCase();
    if (codec == 'bytevc2' || text(item['gear_des_key']).contains('bytevc2')) {
      continue;
    }
    final address = text(item['main_url']);
    final uri = Uri.tryParse(address);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      continue;
    }
    final encrypted = object(item['encrypt_info']);
    String? key;
    if (text(encrypted['spade_a']).isNotEmpty ||
        encrypted['encrypt'] == true ||
        encrypted['encryption_method'] == 'cenc-aes-ctr') {
      try {
        key = decodeContentKey(text(encrypted['spade_a']));
      } on FormatException {
        continue;
      }
    }
    final definition = RegExp(r'\d+').firstMatch(text(meta['definition']));
    final width = integer(meta['vwidth']), height = integer(meta['vheight']);
    final quality = definition != null
        ? int.parse(definition.group(0)!)
        : width > 0 && height > 0
        ? min(width, height)
        : max(width, height);
    if (quality <= 0) continue;
    final variant = MediaVariant(
      url: address,
      quality: quality,
      codec: codec,
      key: key,
      duration:
          double.tryParse(text(model['video_duration'] ?? model['duration'])) ??
          0,
    );
    if (!variants.containsKey(quality) || {'h264', 'avc1'}.contains(codec)) {
      variants[quality] = variant;
    }
  }
  if (variants.isEmpty) throw const FormatException('接口没有返回兼容画质，可能需要授权或协议已变更');
  return variants.values.toList()
    ..sort((a, b) => b.quality.compareTo(a.quality));
}

Map<String, String> signRequest(String query, String body, DateTime now) {
  final seconds = now.millisecondsSinceEpoch ~/ 1000;
  final bodyHash = md5.convert(utf8.encode(body));
  final bytes = List<int>.filled(20, 0);
  bytes.setRange(0, 4, md5.convert(utf8.encode(query)).bytes);
  bytes.setRange(4, 8, bodyHash.bytes);
  bytes.setRange(12, 16, [0, 6, 11, 28]);
  for (var i = 0; i < 4; i++) {
    bytes[16 + i] = (seconds >> (24 - 8 * i)) & 255;
  }
  const mask = [
    0x44,
    0xb9,
    0xb9,
    0xd9,
    0xa4,
    0xae,
    0xf9,
    0xfc,
    0xa4,
    0x93,
    0xaa,
    0x75,
    0x7c,
    0xa3,
    0xc2,
    0xc4,
    0xa4,
    0x96,
    0x93,
    0x8f,
  ];
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] ^= mask[i];
  }
  for (var i = 0; i < bytes.length; i++) {
    final b =
        (((bytes[i] << 4) | (bytes[i] >> 4)) & 255) ^
        bytes[(i + 1) % bytes.length];
    var reversed = 0;
    for (var bit = 0; bit < 8; bit++) {
      reversed |= ((b >> bit) & 1) << (7 - bit);
    }
    bytes[i] = reversed ^ 255 ^ 20;
  }
  return {
    'X-Gorgon': [
      0x84,
      4,
      0x40,
      0x1c,
      0,
      0,
      ...bytes,
    ].map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    'X-Khronos': '$seconds',
    'X-SS-Req-Ticket': '${now.millisecondsSinceEpoch}',
    'X-SS-STUB': bodyHash.toString().toUpperCase(),
  };
}

String decodeContentKey(String encoded) {
  try {
    final raw = base64.decode(base64.normalize(encoded));
    if (raw.length < 3 || raw.length > 1024) throw const FormatException();
    final tagLength = (raw[0] ^ raw[1] ^ raw[2]) - 48;
    final length = raw.length - tagLength - 1;
    if (tagLength < 1 || length < 33 || length >= raw.length) {
      throw const FormatException();
    }
    final seed =
        raw[raw.length - tagLength - 2] ^ raw[raw.length - tagLength - 1];
    final tag = String.fromCharCodes(
      raw.sublist(raw.length - tagLength).map((v) => v ^ seed),
    );
    if (tag == 'app_v2' || tag == 'web_v2') {
      throw const FormatException('不支持的媒体协议');
    }
    final previous = [250, 85];
    final decoded = <int>[];
    for (var i = 0; i < length; i++) {
      final b = raw[i + 1];
      final ones = i.toRadixString(2).replaceAll('0', '').length;
      decoded.add(((previous[i % 2] ^ b) - 21 - ones) & 255);
      previous[i % 2] = b;
    }
    final pad = int.parse(String.fromCharCode(decoded.first), radix: 36);
    if (length - pad - 1 != 32) throw const FormatException();
    final key = String.fromCharCodes(decoded.sublist(1, 33));
    if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(key)) {
      throw const FormatException();
    }
    return key;
  } catch (_) {
    throw const FormatException('媒体授权数据无效或协议版本不支持');
  }
}
