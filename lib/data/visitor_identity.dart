import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';
import '../services/app_storage.dart';

class VisitorInitializationException implements Exception {
  const VisitorInitializationException({this.reason = 'unavailable'});
  final String reason;
  @override
  String toString() => '播放初始化失败，请稍后重试。';
}

class RegisteredVisitor {
  RegisteredVisitor(this.deviceId, this.installId) {
    if (![
      deviceId,
      installId,
    ].every((v) => RegExp(r'^[1-9]\d{15,19}$').hasMatch(v))) {
      throw const FormatException('无效访客身份');
    }
  }
  final String deviceId, installId;
  Map<String, String> get parameters => {
    'device_id': deviceId,
    'iid': installId,
  };
}

abstract class VisitorIdentityProvider {
  Future<RegisteredVisitor> get({RegisteredVisitor? rejected});
}

/// Each installation registers its own visitor. No captured identity or account.
class VisitorIdentityStore implements VisitorIdentityProvider {
  VisitorIdentityStore({required this.file, http.Client? client})
    : _http = client ?? http.Client();
  final Future<File> Function() file;
  final http.Client _http;
  RegisteredVisitor? _current;
  Future<RegisteredVisitor>? _pending;
  bool _loaded = false;
  static final shared = VisitorIdentityStore(
    file: () async => File(
      p.join((await appSupportDirectory()).path, 'data', 'visitor-v1.json'),
    ),
  );

  @override
  Future<RegisteredVisitor> get({RegisteredVisitor? rejected}) {
    if (rejected != null &&
        _current?.deviceId == rejected.deviceId &&
        _current?.installId == rejected.installId) {
      _current = null;
    }
    return _pending ??= _get().whenComplete(() => _pending = null);
  }

  Future<RegisteredVisitor> _get() async {
    try {
      final store = await file();
      if (!_loaded) {
        _loaded = true;
        if (await store.exists()) {
          try {
            if (await store.length() > 4096) throw const FormatException();
            final j = jsonDecode(await store.readAsString()) as Map;
            if (j['version'] != 1) throw const FormatException();
            _current = RegisteredVisitor(
              j['device_id'] as String,
              j['iid'] as String,
            );
          } on FormatException {
            /* Replace only after registration succeeds. */
          } on TypeError {
            /* An old or incomplete profile needs registration. */
          }
        }
      }
      if (_current != null) return _current!;
      final visitor = await _register();
      await store.parent.create(recursive: true);
      final temporary = File('${store.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'version': 1, ...visitor.parameters}),
        flush: true,
      );
      await temporary.rename(store.path);
      return _current = visitor;
    } on VisitorInitializationException catch (failure) {
      debugPrint('Visitor bootstrap: ${failure.reason}');
      rethrow;
    } catch (_) {
      debugPrint('Visitor bootstrap: local_storage_or_network');
      throw const VisitorInitializationException(
        reason: 'local_storage_or_network',
      );
    }
  }

  Future<RegisteredVisitor> _register() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final random = Random.secure();
    String hex(int count) => List.generate(
      count,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    String uuid() {
      final h = hex(16);
      return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-'
          '8${h.substring(17, 20)}-${h.substring(20)}';
    }

    final body = encodeVisitorRegistration(
      utf8.encode(
        jsonEncode({
          'magic_tag': 'ss_app_log',
          '_gen_time': now,
          'header': {
            'display_name': '红果免费短剧',
            'aid': 8662,
            'channel': 'update_64',
            'package': 'com.phoenix.read',
            'app_version': '7.3.9.32',
            'version_code': 73932,
            'update_version_code': 73932,
            'manifest_version_code': 73932,
            'app_version_minor': '',
            'sdk_version': '3.7.0-rc.34-fanqie-xiaoshuo',
            'sdk_target_version': 29,
            'git_hash': '',
            'os': 'Android',
            'os_version': '9',
            'os_api': 28,
            'device_model': 'DT1901A',
            'device_brand': 'smartisan',
            'device_manufacturer': 'smartisan',
            'cpu_abi': 'arm64-v8a',
            'release_build': 'PQ3A.190705.09211140',
            'density_dpi': 320,
            'display_density': 'xhdpi',
            'resolution': '1280x720',
            'language': 'zh',
            'timezone': 8,
            'access': 'wifi',
            'not_request_sender': 0,
            'rom': 'PQ3A',
            'rom_version': 'PQ3A.190705.09211140 release-keys',
            'cdid': uuid(),
            'openudid': hex(8),
            'clientudid': uuid(),
            'sig_hash': '56a962410c494bbaf0b58dba20cae56f',
            'region': 'CN',
            'tz_name': 'Asia/Shanghai',
            'tz_offset': 28800,
            'sim_region': 'cn',
            'oaid_may_support': true,
            'req_id': uuid(),
            'device_platform': 'android',
            'pre_installed_channel': '',
            'apk_first_install_time': now,
            'is_system_app': 0,
            'sdk_flavor': 'china',
            'guest_mode': 0,
            'custom': {
              'account_region_src': 'fallback',
              'host_bit': 64,
              'account_region': 'cn',
              'dragon_device_type': 'phone',
            },
          },
        }),
      ),
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _requestRegistration(body, now);
      } on VisitorInitializationException catch (failure) {
        if (attempt == 1 || failure.reason == 'registration_forbidden') rethrow;
      } on TimeoutException {
        if (attempt == 1) {
          throw const VisitorInitializationException(
            reason: 'registration_timeout',
          );
        }
      } on http.ClientException {
        if (attempt == 1) {
          throw const VisitorInitializationException(
            reason: 'registration_network',
          );
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw const VisitorInitializationException();
  }

  Future<RegisteredVisitor> _requestRegistration(
    List<int> body,
    int now,
  ) async {
    final response = await _http
        .post(
          Uri.https('log5-applog.fqnovel.com', '/service/2/device_register/', {
            'tt_data': 'a',
            'okhttp_version': '4.2.243.31-douyin',
            'use_store_region_cookie': '1',
          }),
          headers: {
            'Content-Type': 'application/octet-stream;tt-data=a',
            'log-encode-type': 'gzip',
            'x-ss-stub': md5.convert(body).toString().toUpperCase(),
            'x-ss-req-ticket': '$now',
            'sdk-version': '2',
            'passport-sdk-version': '5051452',
            'x-vc-bdturing-sdk-version': '4.0.3.cn',
            'User-Agent':
                'com.phoenix.read/73932 (Linux; U; Android 9; zh_CN; DT1901A)',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 25));
    if ({403, 429}.contains(response.statusCode)) {
      throw const VisitorInitializationException(
        reason: 'registration_forbidden',
      );
    }
    if (response.statusCode != 200 || response.bodyBytes.length > 16384) {
      throw const VisitorInitializationException(reason: 'registration_http');
    }
    try {
      final j = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      return RegisteredVisitor(
        j['device_id_str'] as String,
        j['install_id_str'] as String,
      );
    } catch (_) {
      throw const VisitorInitializationException(
        reason: 'registration_rejected',
      );
    }
  }
}

/// TTEncrypt registration envelope: random seed, SHA-512 and AES-128-CBC.
/// Uses the same public protocol salt as the media-address adapter.
Uint8List encodeVisitorRegistration(List<int> json, {List<int>? seed}) {
  final random = Random.secure();
  final entropy = seed ?? List.generate(32, (_) => random.nextInt(256));
  if (entropy.length != 32) throw ArgumentError('Seed must contain 32 bytes');
  final compressed = gzip.encode(json);
  compressed.setRange(0, 10, [31, 139, 8, 0, 0, 0, 0, 0, 0, 0]);
  const salt =
      '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524'
      'f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58';
  final hash = sha512.convert([
    ...sha512.convert(entropy).bytes,
    for (var i = 0; i < salt.length; i += 2)
      int.parse(salt.substring(i, i + 2), radix: 16),
  ]).bytes;
  final plain = <int>[...sha512.convert(compressed).bytes, ...compressed];
  final pad = 16 - plain.length % 16;
  plain.addAll(List.filled(pad, pad));
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      true,
      ParametersWithIV(
        KeyParameter(Uint8List.fromList(hash.sublist(0, 16))),
        Uint8List.fromList(hash.sublist(16, 32)),
      ),
    );
  final encrypted = Uint8List(plain.length);
  final bytes = Uint8List.fromList(plain);
  for (var at = 0; at < bytes.length; at += 16) {
    cipher.processBlock(bytes, at, encrypted, at);
  }
  return Uint8List.fromList([
    0x74,
    0x63,
    0x05,
    0x10,
    0,
    0,
    ...entropy,
    ...encrypted,
  ]);
}
