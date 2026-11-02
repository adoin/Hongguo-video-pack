# Third-party notices

## Community and project inspiration

The author originally used MiniReel, shared in the [LINUX DO community](https://linux.do/), and encountered search pagination and playback failures during that personal use. Those experiences motivated this project's own observation and adaptation of the Hongguo website and App interfaces. They are not a claim about MiniReel's current behavior. See the [MiniReel community topic](https://linux.do/t/topic/3028726).

Thanks to the MiniReel authors and LINUX DO for the inspiration and community discussion. MiniReel is acknowledged here as product inspiration, separately from the reused open-source implementations listed below. No MiniReel client binary, private source, account or device identity is included.

## Reused software and licenses

- WebDAV credentials use `flutter_secure_storage` 10.0.0, BSD-3-Clause: https://github.com/juliansteenbakker/flutter_secure_storage . The Windows DPAPI Dart backend from `flutter_secure_storage_windows` 4.1.0 is included under `vendor/flutter_secure_storage_windows/` with its license; only its plugin manifest is changed to exclude the unused legacy C++/ATL migration bridge. Android retains the upstream Keystore-based encryption implementation. No WebDAV credentials are distributed.

The protocol adapters include code adapted from:

- `seanminjie-del/hongguoTV-livingroom`, commit `76eeaa9b964359fe6ed3f4a2b6f79ffb11f35761`: `server/vendor/hongguo.cjs` and Kotlin core `Signer.kt`, `AesV3.kt`, `Bytes.kt`, `VendorConstants.kt`. These implementations derive from drpys commit `22261adfa31435e3b3ef5a730b8a2a75bcaf1715` and are GPL-3.0-only. Source: https://github.com/seanminjie-del/hongguoTV-livingroom . The license is included in `licenses/GPL-3.0.txt`.
- Protocol changes in this project: request packaging, Flutter platform bridge, version parameters, signing-worker packaging, URL/content-key adapters, and application integration. Modified sources are shipped with the application source bundle. No MiniReel executable, source, account or stored device identity is distributed.
- FFmpegKit community continuation `ffmpeg_kit_flutter_new` and its full-GPL FFmpeg libraries: https://github.com/sk3llo/ffmpeg_kit_flutter . This distribution uses GPL-enabled codecs. Preserve the applicable licenses and provide corresponding source when redistributing.
- Windows signing runtime Node.js: https://nodejs.org/ , MIT and bundled third-party notices. Its LICENSE accompanies the portable distribution under `runtime/`.
- Flutter/Dart and all pub dependencies retain their respective notices, accessible from the application's About / Licenses dialog.
- Embedded playback uses `media_kit` 1.2.6, `media_kit_video` 2.0.1 and `media_kit_libs_video` 1.0.7, MIT-licensed Flutter wrappers: https://github.com/media-kit/media-kit . Wrapper license copies are included under `licenses/media_kit/`.
- The bundled native libmpv and its FFmpeg codecs retain their own GPL/LGPL and third-party terms. The Windows binary is the unmodified `2023-09-24` x86_64 build from https://github.com/media-kit/libmpv-win32-video-build/releases/tag/2023-09-24 ; Android libraries are the unmodified `v1.1.7` builds from https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.7 . Corresponding build recipes and source references are maintained in those repositories; mpv source is https://github.com/mpv-player/mpv . Do not describe the native libraries as covered solely by the wrappers' MIT license. Application source, dependency lockfile and reproducible build instructions accompany the distribution.

Application distributions containing the GPL adapters and media libraries must be redistributed consistently with their GPL terms, including corresponding source and notices. The acceptance package is delivered with this repository's application source and reproducible build instructions.
