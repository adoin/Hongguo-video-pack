import 'dart:convert';
import 'dart:io';
import 'package:hongguo_studio/data/request_signer.dart';

class CliSigner implements PlaybackFallbackSigner {
  @override
  Future<SignedRequest> sign(String body, Map<String, String> device) async {
    return _sign(body, device, false);
  }

  @override
  Future<SignedRequest> signFallback(String body, Map<String, String> device) =>
      _sign(body, device, true);
  Future<SignedRequest> _sign(
    String body,
    Map<String, String> device,
    bool fallback,
  ) async {
    final process = await Process.start('node', ['assets/protocol/worker.cjs']);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    process.stdin.writeln(
      jsonEncode({
        'body': body,
        'device': device,
        if (fallback) 'operation': 'playbackFallback',
      }),
    );
    await process.stdin.close();
    final code = await process.exitCode;
    await errors;
    if (code != 0) throw StateError('Signer failed');
    return SignedRequest.fromJson(
      Map<String, dynamic>.from(jsonDecode(await output) as Map),
    );
  }
}
