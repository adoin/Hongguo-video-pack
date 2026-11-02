import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/settings_view.dart';
import 'package:hongguo_studio/services/app_logs.dart';
import 'package:hongguo_studio/services/webdav_sync.dart';
import 'package:hongguo_studio/watch_history.dart';
import 'webdav_sync_test.dart' show MemoryCredentials;

void main() {
  for (final width in [320.0, 390.0, 1320.0]) {
    testWidgets('settings layout and custom history limit at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final history = WatchHistory(), logs = AppLogs();
      final sync = WebDavSync(
        history: history,
        credentials: MemoryCredentials(),
      );
      addTearDown(sync.dispose);
      addTearDown(history.dispose);
      addTearDown(logs.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(history: history, sync: sync, logs: logs),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('history-limit')),
        '123',
      );
      await tester.tap(find.text('保存记录条数'));
      await tester.pumpAndSettle();
      expect(history.limit, 123);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('开发者日志'),
        450,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('开发者日志'));
      await tester.pumpAndSettle();
      expect(find.text('全量日志'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets(
    'copy one warning or all issues and explicitly enable full logging',
    (tester) async {
      final logs = AppLogs();
      addTearDown(logs.dispose);
      logs.add(LogLevel.warning, '预加载', '警告样例');
      logs.add(LogLevel.error, '播放', '错误样例');
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: DeveloperLogsScreen(logs: logs)),
      );
      await tester.tap(find.byTooltip('复制此条日志').first);
      await tester.pump();
      expect(clipboard, contains('错误样例'));
      expect(clipboard, isNot(contains('警告样例')));
      await tester.tap(find.byTooltip('复制全部错误与警告'));
      await tester.pump();
      expect(clipboard, contains('错误样例'));
      expect(clipboard, contains('警告样例'));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(logs.full, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
