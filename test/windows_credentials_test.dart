import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.folder);
  final String folder;
  @override
  Future<String?> getApplicationSupportPath() async => folder;
}

void main() {
  test(
    'Windows DPAPI stores encrypted credentials and reads them after restart',
    () async {
      final base = Directory('D:/tmp/hongputao-webdav-tests');
      await base.create(recursive: true);
      final folder = await base.createTemp('dpapi-');
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(folder.path);
      try {
        const options = {'useBackwardCompatibility': 'false'};
        final backend = FlutterSecureStorageWindows();
        await backend.write(
          key: 'webdav-test',
          value: 'synthetic-password-4239',
          options: options,
        );
        final files = await folder
            .list()
            .where((f) => f is File)
            .cast<File>()
            .toList();
        expect(files, isNotEmpty);
        for (final file in files) {
          expect(
            utf8.decode(await file.readAsBytes(), allowMalformed: true),
            isNot(contains('synthetic-password-4239')),
          );
        }
        expect(
          await FlutterSecureStorageWindows().read(
            key: 'webdav-test',
            options: options,
          ),
          'synthetic-password-4239',
        );
      } finally {
        PathProviderPlatform.instance = previous;
        await folder.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
