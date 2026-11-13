import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SignedRequest {
  const SignedRequest(
    this.url,
    this.headers,
    this.body, {
    this.method = 'POST',
  });
  final Uri url;
  final Map<String, String> headers;
  final String body;
  final String method;
  factory SignedRequest.fromJson(Map<String, dynamic> data) => SignedRequest(
    Uri.parse(data['url'] as String),
    Map<String, String>.from(data['headers'] as Map),
    data['body'] as String,
    method: data['method'] as String? ?? 'POST',
  );
}

abstract class RequestSigner {
  Future<SignedRequest> sign(String body, Map<String, String> device);
}

abstract class PlaybackFallbackSigner implements RequestSigner {
  Future<SignedRequest> signFallback(String body, Map<String, String> device);
}

abstract class SearchRequestSigner {
  Future<SignedRequest> signSearch(
    Map<String, String> query,
    Map<String, String> identity,
  );
}

class NativeRequestSigner
    implements PlaybackFallbackSigner, SearchRequestSigner {
  static const channel = MethodChannel('dev.hongguo.studio/platform');
  Future<String>? _worker;
  Future<String> _prepare() async {
    final support = await getApplicationSupportDirectory();
    final dir = await Directory(
      p.join(support.path, 'protocol-v1'),
    ).create(recursive: true);
    for (final name in ['worker.cjs', 'signer.cjs', 'player_signer.cjs']) {
      final data = await rootBundle.loadString('assets/protocol/$name');
      await File(p.join(dir.path, name)).writeAsString(data, flush: true);
    }
    return p.join(dir.path, 'worker.cjs');
  }

  @override
  Future<SignedRequest> sign(String body, Map<String, String> device) async {
    return _run({'body': body, 'device': device}, 'sign');
  }

  @override
  Future<SignedRequest> signFallback(String body, Map<String, String> device) =>
      _run({
        'operation': 'playbackFallback',
        'body': body,
        'device': device,
      }, 'signPlaybackFallback');

  @override
  Future<SignedRequest> signSearch(
    Map<String, String> query,
    Map<String, String> identity,
  ) {
    return _run({
      'operation': 'search',
      'query': query,
      'device': identity,
    }, 'signSearch');
  }

  Future<SignedRequest> _run(Map<String, dynamic> input, String method) async {
    if (Platform.isAndroid) {
      final result = await channel.invokeMapMethod<String, dynamic>(
        method,
        input,
      );
      if (result == null) throw StateError('签名服务无响应');
      return SignedRequest.fromJson(result);
    }
    final worker = await (_worker ??= _prepare());
    final bundled = p.join(
      p.dirname(Platform.resolvedExecutable),
      'runtime',
      Platform.isWindows ? 'node.exe' : 'node',
    );
    final node = await File(bundled).exists() ? bundled : 'node';
    final process = await Process.start(node, [worker]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    process.stdin.writeln(jsonEncode(input));
    await process.stdin.close();
    final exit = await process.exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    final value = await output;
    await errors;
    if (exit != 0) throw StateError('签名服务启动失败，请确认安装包完整');
    return SignedRequest.fromJson(
      Map<String, dynamic>.from(jsonDecode(value) as Map),
    );
  }
}
