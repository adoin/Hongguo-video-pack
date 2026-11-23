import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/data/discovery_client.dart';
import 'package:hongguo_studio/data/openhongguo_playback.dart';
import 'package:hongguo_studio/discovery_controller.dart';
import 'package:hongguo_studio/discovery_view.dart';
import 'package:hongguo_studio/domain/discovery.dart';

const firstCard = {
  'id': '100000000000000001',
  'title': '剧场测试作品',
  'cover_url': 'https://images.example/first.jpg',
  'description': '一段简介',
  'episode_count': 8,
  'vid': '100000000000000002',
  'rec_text': '4390万热度',
  'play_count': 200,
  'vertical': true,
};

class _TheaterClient extends DiscoveryClient {
  @override
  bool get theaterSupported => true;
  String channel = '找剧';
  final calls = <(String, String?)>[];
  @override
  String get theaterChannel => channel;
  @override
  Future<DiscoveryPage> theater(
    String channel, {
    String? cursor,
    required int page,
  }) async {
    calls.add((channel, cursor));
    return parseTheaterFeed(
      {
        'items': cursor == null
            ? [firstCard]
            : [
                firstCard,
                {
                  'id': '100000000000000009',
                  'title': '第二页作品',
                  'vertical': false,
                },
              ],
        'has_more': cursor == null,
        'cursor': cursor == null ? 'opaque-next' : '',
      },
      page: page,
      previousCursor: cursor,
    );
  }
}

void main() {
  test('homepage cards keep their own metrics and first episode hint', () {
    final page = parseTheaterFeed({
      'items': [firstCard, firstCard],
      'has_more': true,
      'cursor': 'opaque-next',
    }, page: 1);
    expect(page.items.single.firstEpisodeId, '100000000000000002');
    expect(page.items.single.metric, '4390万热度');
    expect(page.items.single.plays, '200');
    expect(
      page.items.single.withMetadata(heat: '').firstEpisodeId,
      '100000000000000002',
    );
    expect(page.cursor, 'opaque-next');
  });

  testWidgets(
    'theater shows masonry and keeps channel and cursor across refresh of rules',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = _TheaterClient();
      final controller = DiscoveryController(client: client);
      addTearDown(controller.dispose);
      await controller.show(DiscoveryMode.theater);
      client.channel = '首页漫剧';
      await controller.refresh(more: true);
      expect(client.calls, [('找剧', null), ('找剧', 'opaque-next')]);
      expect(controller.items.map((row) => row.title), ['剧场测试作品', '第二页作品']);
      DramaSummary? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DiscoveryView(
                controller: controller,
                onPick: (_) {},
                onPlay: (row) => selected = row,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(MasonryGridView), findsOneWidget);
      expect(find.text('4390万热度'), findsOneWidget);
      final button = find.text('播放').first;
      await tester.ensureVisible(button);
      await tester.tap(button);
      expect(selected?.firstEpisodeId, '100000000000000002');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
