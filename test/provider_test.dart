import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hongguo_studio/data/hongguo_client.dart';
import 'package:hongguo_studio/domain/drama.dart';
import 'package:hongguo_studio/data/request_signer.dart';
import 'package:hongguo_studio/data/visitor_identity.dart';

class TestVisitors implements VisitorIdentityProvider {
  @override
  Future<RegisteredVisitor> get({RegisteredVisitor? rejected}) async =>
      RegisteredVisitor('1000000000000001', '2000000000000001');
}

class FakeSigner implements RequestSigner {
  @override
  Future<SignedRequest> sign(String body, Map<String, String> device) async =>
      SignedRequest(
        Uri.https(
          'api5-normal-sinfonlineb.fqnovel.com',
          '/novel/player/multi_video_model/v1/',
        ),
        {'X-Gorgon': 'test'},
        body,
      );
}

class VideoTabSigner implements RequestSigner {
  @override
  Future<SignedRequest> sign(String body, Map<String, String> device) async =>
      SignedRequest(
        Uri.https(
          HongguoClient.appHost,
          '/reading/bookapi/video_tab/multi_video_model/v1/',
        ),
        {'x-argus': 'test'},
        '',
        method: 'GET',
      );
}

void main() {
  test(
    'GET video-tab models unwrap correctly and resolve playable variants',
    () async {
      var requests = 0;
      final client = HongguoClient(
        signer: VideoTabSigner(),
        identities: TestVisitors(),
        client: MockClient((request) async {
          requests++;
          expect(request.method, 'GET');
          expect(request.bodyBytes, isEmpty);
          final data = request.url.host == HongguoClient.appHost
              ? {
                  'code': 0,
                  'data': {
                    'video_model_data': {
                      '9': {
                        'video_model': {
                          'fallback_api': {
                            'fallback_api':
                                'https://video.volcengineapi.com/info',
                          },
                        },
                      },
                    },
                  },
                }
              : {
                  'code': 0,
                  'video_info': {
                    'data': {
                      'video_duration': 120,
                      'video_list': [
                        {
                          'vwidth': 1080,
                          'vheight': 1920,
                          'codec_type': 'h264',
                          'main_url': 'https://media.example/video.mp4',
                        },
                      ],
                    },
                  },
                };
          return http.Response(jsonEncode(data), 200);
        }),
      );
      addTearDown(client.close);
      final variants = await client.fetchVariants(const Episode('9', 1));
      expect(variants.single.quality, 1080);
      expect(variants.single.duration, 120);
      expect(requests, 2);
    },
  );
  test('accepts player links and rejects lookalike hosts', () {
    expect(
      seriesIdFromInput('https://hongguoduanju.com/player/123/456'),
      '123',
    );
    expect(
      seriesIdFromInput('https://hongguoduanju.com/detail?series_id=123'),
      '123',
    );
    expect(
      () => seriesIdFromInput('https://hongguoduanju.com.evil.test/player/123'),
      throwsFormatException,
    );
    expect(
      () => seriesIdFromInput('https://user:pass@evil.test/player/123'),
      throwsFormatException,
    );
  });
  test('rejects missing, duplicate and mismatched episodes', () {
    final detail = <String, dynamic>{
      'series_id': '123',
      'episode_cnt': 2,
      'series_title': '测试',
      'video_list': [
        {'vid': '2', 'vid_index': 2},
        {'vid': '1', 'vid_index': 1},
      ],
    };
    final result = {
      'data': {'video_data': detail},
    };
    expect(parseAppDrama(result, '123').episodes.first.id, '1');
    expect(() => parseAppDrama(result, '456'), throwsFormatException);
    detail['episode_cnt'] = 3;
    expect(() => parseAppDrama(result, '123'), throwsFormatException);
    detail['episode_cnt'] = 2;
    detail['video_list'] = [
      {'vid': '1', 'vid_index': 1},
      {'vid': '1', 'vid_index': 2},
    ];
    expect(() => parseAppDrama(result, '123'), throwsFormatException);
  });
  test('selects actual compatible qualities, never invents 1080p', () {
    final options = parseVariants({
      'video_list': {
        'a': {
          'main_url': 'https://media.example/a',
          'video_meta': {'definition': '2160p', 'codec_type': 'bytevc2'},
        },
        'b': {
          'main_url': 'https://media.example/b',
          'video_meta': {'definition': '720p', 'codec_type': 'h264'},
        },
        'c': {
          'main_url': 'https://media.example/c',
          'video_meta': {'definition': '1080p', 'codec_type': 'hevc'},
        },
      },
    });
    expect(options.map((v) => v.quality), [1080, 720]);
    expect(chooseQuality(options, 0).quality, 1080);
    expect(chooseQuality(options, 900).quality, 720);
    expect(chooseQuality(options, 360).quality, 720);
    expect(chooseQuality([options.last], 1080).quality, 720);
    expect(() => decodeContentKey('bad key'), throwsFormatException);
  });
  test('parses escaped braces and quotes in page JSON without evaluating JS', () {
    final data = {
      'loaderData': {
        'player_(series_id)/page': {
          'seriesDetail': {
            'series_id': '123',
            'series_name': '标题 } " 测试',
            'vid_list': ['7', '8'],
          },
        },
      },
    };
    final html =
        '<script>window._ROUTER_DATA=${jsonEncode(data)};malicious();</script>';
    final drama = parseWebDrama(html, '123');
    expect(drama.episodes.length, 2);
    expect(drama.title, '标题 } " 测试');
    expect(() => parseWebDrama(html, '999'), throwsFormatException);
  });
  test('detail page fallback requires the complete episode list', () {
    String html(int count) =>
        'window._ROUTER_DATA=${jsonEncode({
          'loaderData': {
            'detail_page': {
              'seriesDetail': {
                'series_id': '123',
                'series_name': '剧集',
                'episode_cnt': count,
                'vid_list': ['7', '8'],
              },
            },
          },
        })}';
    expect(parseWebDrama(html(2), '123').episodes.length, 2);
    expect(() => parseWebDrama(html(3), '123'), throwsFormatException);
  });
  test(
    'App failure falls back to page details but empty media remains an error',
    () async {
      final client = HongguoClient(
        signer: FakeSigner(),
        identities: TestVisitors(),
        client: MockClient((request) async {
          if (request.url.host == 'hongguoduanju.com') {
            return http.Response(
              'window._ROUTER_DATA=${jsonEncode({
                'loaderData': {
                  'player_x': {
                    'seriesDetail': {
                      'series_id': '123',
                      'series_name': '测试',
                      'vid_list': ['9'],
                    },
                  },
                },
              })};',
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }
          expect(request.headers['X-Gorgon'], isNotEmpty);
          return http.Response('', 200);
        }),
      );
      final drama = await client.fetchDrama('123');
      expect(drama.source, '网页详情回退');
      await expectLater(
        client.fetchVariants(drama.episodes.first),
        throwsA(isA<VisitorInitializationException>()),
      );
      client.close();
    },
  );
}
