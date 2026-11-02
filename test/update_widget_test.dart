import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hongguo_studio/services/app_updater.dart';
import 'package:hongguo_studio/update_view.dart';
import 'app_updater_test.dart' show release;

void main() {
  for (final width in [320.0, 390.0, 1320.0]) {
    testWidgets(
      'update page shows stable version and blocks task interruption at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final updater = AppUpdater(
          versionReader: () async => '1.0.0',
          giteeRepository: '',
          client: MockClient(
            (_) async => http.Response(jsonEncode([release('v2.0.0')]), 200),
          ),
        );
        addTearDown(updater.dispose);
        await updater.check();
        // No executable is created or run by this UI test.
        updater.readyFile = File('never-run.exe');
        var installs = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              filledButtonTheme: FilledButtonThemeData(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 19,
                  ),
                ),
              ),
            ),
            home: UpdateScreen(
              updater: updater,
              busy: () => true,
              install: () async {
                installs++;
                return true;
              },
              openRelease: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('当前版本：1.0.0'), findsOneWidget);
        final size = tester.getSize(find.widgetWithText(FilledButton, '安装更新'));
        expect(size.height, lessThanOrEqualTo(48));
        expect(size.width, lessThan(160));
        await tester.tap(find.text('安装更新'));
        await tester.pumpAndSettle();
        expect(installs, 0);
        expect(find.text('请先完成或取消当前拼接任务，再安装更新。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('update actions stay usable with larger mobile text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final updater = AppUpdater(
      versionReader: () async => '1.0.0',
      giteeRepository: '',
      client: MockClient(
        (_) async => http.Response(jsonEncode([release('v2.0.0')]), 200),
      ),
    );
    addTearDown(updater.dispose);
    await updater.check();
    updater.readyFile = File('never-run.exe');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: UpdateScreen(
          updater: updater,
          busy: () => false,
          install: () async => true,
          openRelease: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('安装更新'));
    expect(
      tester.getSize(find.widgetWithText(FilledButton, '安装更新')).height,
      lessThanOrEqualTo(64),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
