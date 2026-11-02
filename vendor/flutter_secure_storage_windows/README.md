# Windows secure storage compatibility

Source: flutter_secure_storage_windows 4.1.0 from https://pub.dev/packages/flutter_secure_storage_windows/versions/4.1.0 . Upstream: https://github.com/juliansteenbakker/flutter_secure_storage . BSD-3-Clause license is retained in LICENSE.

The three Dart source files are unchanged. Only pubspec.yaml removes the native `pluginClass` entry and retains `dartPluginClass`. This avoids compiling the legacy C++/ATL migration bridge. The upstream Dart backend still encrypts the JSON store with Windows DPAPI for the current OS user. `WindowsOptions(useBackwardCompatibility: false)` is required; there are no credentials from an older secure-storage integration to migrate in this project.

Do not enable the legacy migration option without restoring the corresponding native implementation. Android uses the unmodified flutter_secure_storage 10.0.0 implementation.
