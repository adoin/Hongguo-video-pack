import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/app_controller.dart';
import 'package:hongguo_studio/domain/discovery.dart';
import 'package:hongguo_studio/playback_controller.dart';
import 'package:hongguo_studio/playback_view.dart';
import 'playback_controller_test.dart'
    show FakePlaybackEngine, FakePlaybackClient;

void main() {
  for (final width in [1320.0, 800.0, 390.0, 320.0]) {
    testWidgets('playback, stitching and task entry at $width', (tester) async {
      tester.view.physicalSize = Size(width, width == 800 ? 480 : 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = FakePlaybackEngine();
      final c = PlaybackController(
        engine: engine,
        client: FakePlaybackClient(),
      );
      final tasks = StudioController();
      await c.load('123');
      if (Platform.environment['HONGGUO_CAPTURE_UI'] == '1' &&
          Platform.isWindows) {
        await tester.runAsync(() async {
          final loader = FontLoader('Microsoft YaHei');
          loader.addFont(
            Future.value(
              ByteData.sublistView(
                await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
              ),
            ),
          );
          await loader.load();
          final icons = FontLoader('MaterialIcons');
          icons.addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  'D:/envs/flutter-sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
                ).readAsBytes(),
              ),
            ),
          );
          await icons.load();
        });
      }
      var stitched = <int>{}, taskVisits = 0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('player-capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: 'Microsoft YaHei',
              platform: width < 900
                  ? TargetPlatform.android
                  : TargetPlatform.windows,
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFFC20032),
              ),
            ),
            home: PlaybackScreen(
              summary: const DramaSummary(id: '123', title: '示例剧集'),
              tasks: tasks,
              controller: c,
              videoBuilder: () => const ColoredBox(color: Colors.black),
              onStitch: (_, selection, _) async {
                stitched = selection;
                return true;
              },
              onTasks: () => taskVisits++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (Platform.environment['HONGGUO_CAPTURE_UI'] == '1') {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('player-capture')),
          );
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final captureRoot =
              Platform.environment['HONGGUO_CAPTURE_DIRECTORY'] ?? '.local/qa';
          await Directory(captureRoot).create(recursive: true);
          await File(
            '$captureRoot/player-${width.toInt()}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(find.text('任务管理'), findsOneWidget);
      await tester.tap(find.text('任务管理'));
      expect(taskVisits, 1);
      await tester.ensureVisible(find.text('拼接所选 1 集'));
      await tester.tap(find.text('拼接所选 1 集'));
      await tester.pumpAndSettle();
      expect(stitched, {1});
      await tester.ensureVisible(find.byKey(const ValueKey('episode-13')));
      await tester.pumpAndSettle();
      final cells = [
        for (var number = 1; number <= 50; number++)
          tester.getRect(find.byKey(ValueKey('episode-$number'))),
      ];
      for (final cell in cells) {
        expect(cell.width, closeTo(cells.first.width, .01));
        expect(cell.height, closeTo(cells.first.height, .01));
      }
      final columns = cells.where((rect) => rect.top == cells.first.top).length;
      for (var i = 0; i < cells.length; i++) {
        expect(
          cells[i].left,
          closeTo(cells[i % columns].left, .01),
          reason: 'Single and double digit episodes share column edges',
        );
      }
      await c.play(12);
      await tester.pumpAndSettle();
      for (var number = 1; number <= 50; number++) {
        expect(
          tester.getRect(find.byKey(ValueKey('episode-$number'))),
          cells[number - 1],
          reason: 'Selection must not move cells',
        );
      }
      if (Platform.environment['HONGGUO_CAPTURE_UI'] == '1') {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('player-capture')),
          );
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${Platform.environment['HONGGUO_CAPTURE_DIRECTORY'] ?? '.local/qa'}/episodes-${width.toInt()}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      tasks.dispose();
    });
  }
}
