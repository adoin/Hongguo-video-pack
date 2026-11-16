import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/app_controller.dart';
import 'package:hongguo_studio/data/discovery_client.dart';
import 'package:hongguo_studio/domain/discovery.dart';
import 'package:hongguo_studio/playback_controller.dart';
import 'package:hongguo_studio/playback_view.dart';
import 'package:hongguo_studio/related_controller.dart';
import 'playback_controller_test.dart'
    show FakePlaybackEngine, FakePlaybackClient;

class RelatedWidgetSource extends DiscoveryClient {
  @override
  Future<List<DramaSummary>> recommendations(String id) async => [];
  @override
  Future<DiscoveryPage> search(
    String keyword, {
    int page = 1,
    String? relatedTo,
    bool expanded = false,
    bool refresh = true,
  }) async => const DiscoveryPage([
    DramaSummary(id: '999', title: '示例剧集第二季', episodes: 80),
  ]);
}

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'mobile related results and persistent preload toggle at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final tasks = StudioController();
        final c = PlaybackController(
          engine: FakePlaybackEngine(),
          client: FakePlaybackClient(),
        );
        final related = RelatedController(client: RelatedWidgetSource());
        addTearDown(tasks.dispose);
        addTearDown(c.dispose);
        addTearDown(related.dispose);
        await c.load('123');
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: PlaybackScreen(
              summary: const DramaSummary(id: '123', title: '示例剧集'),
              tasks: tasks,
              controller: c,
              relatedController: related,
              videoBuilder: () => const SizedBox(),
              onStitch: (_, _, _) async => false,
              onTasks: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('preload-next-switch'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(c.preloadNext, isFalse);
        expect(tasks.preloadNext, isFalse);
        await tester.ensureVisible(find.text('相关推荐'));
        await tester.tap(find.text('相关推荐'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('相关剧集'));
        await tester.pumpAndSettle();
        expect(find.text('示例剧集第二季'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
