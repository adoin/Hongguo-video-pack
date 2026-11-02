import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/services/app_logs.dart';

void main() {
  test(
    'default severity, full logging, redaction, bounded storage and restart',
    () async {
      final base = Platform.isWindows
          ? Directory('D:/tmp/hongputao-webdav-tests')
          : Directory.systemTemp;
      await base.create(recursive: true);
      final folder = await base.createTemp('logs-');
      final logs = AppLogs();
      addTearDown(logs.dispose);
      addTearDown(() => folder.delete(recursive: true));
      final file = File('${folder.path}/logs.json');
      await logs.initialize(file);
      logs.add(LogLevel.info, 'test', 'not collected');
      expect(logs.entries, isEmpty);
      logs.add(
        LogLevel.error,
        'network',
        'https://host/path?token=secret\nAuthorization: Basic hidden\n1234567890123456',
      );
      expect(logs.entries.single.text, isNot(contains('secret')));
      expect(logs.entries.single.text, isNot(contains('hidden')));
      expect(logs.entries.single.text, isNot(contains('1234567890123456')));
      logs.setFull(true);
      logs.add(LogLevel.debug, 'test', 'debug event');
      await logs.flush();
      final restarted = AppLogs();
      addTearDown(restarted.dispose);
      await restarted.initialize(file);
      expect(restarted.full, isTrue);
      expect(restarted.entries.length, 2);
      for (var i = 0; i < 1100; i++) {
        logs.add(LogLevel.info, 'test', 'entry $i');
      }
      expect(logs.entries.length, 1000);
      await logs.flush();
      logs.setFull(false);
      final count = logs.entries.length;
      logs.add(LogLevel.info, 'test', 'disabled');
      expect(logs.entries.length, count);
      await logs.clear();
      expect(logs.entries, isEmpty);
    },
  );
}
