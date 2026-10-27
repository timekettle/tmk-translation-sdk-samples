import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Sample-owned, real-time PCM input for online listening tests.
final class SampleOnlineListenTestAudio {
  SampleOnlineListenTestAudio({
    AssetBundle? bundle,
    Future<void> Function(Duration)? wait,
  }) : _bundle = bundle ?? rootBundle,
       _wait = wait ?? Future<void>.delayed;

  static const asset = 'assets/audio/saucelabs_en_0_16k_mono_s16le.pcm';
  static const frameBytes = 640; // 20 ms at 16 kHz, mono, PCM16LE.
  static const tailFrames = 50; // One second of silence to flush final ASR.
  static const maxRemoteBytes = 20 * 1024 * 1024;

  final AssetBundle _bundle;
  final Future<void> Function(Duration) _wait;
  Uint8List? _pcm;
  int _generation = 0;

  Future<void> load() async {
    if (_pcm != null) return;
    final data = await _bundle.load(asset);
    if (data.lengthInBytes == 0 || data.lengthInBytes.isOdd) {
      throw StateError('测试音频必须是非空、完整采样的 PCM16 文件');
    }
    _pcm = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  void clearRemote() => _pcm = null;

  /// Runs on the phone and reports only safe metadata, never the signed URL.
  Future<Map<String, Object?>> downloadRemote(String rawUrl) async {
    _pcm = null;
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return _downloadReport('failed', error: 'https_url_required');
    }
    final clock = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    int? httpStatus;
    var byteCount = 0;
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      final response = await request.close().timeout(const Duration(seconds: 60));
      httpStatus = response.statusCode;
      if (httpStatus != HttpStatus.ok) {
        await response.drain<void>();
        return _downloadReport('failed', httpStatus: httpStatus, host: uri.host,
          durationMs: clock.elapsedMilliseconds, error: 'http_status_$httpStatus');
      }
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        byteCount += chunk.length;
        if (byteCount > maxRemoteBytes) throw const FormatException('audio_too_large');
        chunks.add(chunk);
      }
      if (byteCount == 0 || byteCount.isOdd) {
        throw const FormatException('invalid_pcm16_length');
      }
      final pcm = chunks.takeBytes();
      final digest = sha256.convert(pcm).toString();
      _pcm = pcm;
      return _downloadReport('ok', httpStatus: httpStatus, bytes: byteCount,
        sha: digest, host: uri.host, durationMs: clock.elapsedMilliseconds);
    } catch (error) {
      _pcm = null;
      final code = error is FormatException
          ? error.message
          : error is SocketException
              ? 'SocketException_${error.osError?.errorCode ?? 'unknown'}'
              : error.runtimeType.toString();
      return _downloadReport('failed', httpStatus: httpStatus, bytes: byteCount,
        host: uri.host, durationMs: clock.elapsedMilliseconds, error: code);
    } finally {
      client.close(force: true);
      clock.stop();
    }
  }

  static Map<String, Object?> _downloadReport(String status, {
    int? httpStatus, int? bytes, String? sha, String? host,
    int? durationMs, String? error,
  }) => {
    'status': status,
    'http_status': httpStatus,
    'bytes': bytes,
    'sha256': sha,
    'host': host,
    'duration_ms': durationMs,
    'error': error,
  };

  Future<bool> play(Future<void> Function(Uint8List frame) push) async {
    final generation = ++_generation;
    await load();
    final pcm = _pcm!;
    final clock = Stopwatch()..start();
    var pushedFrames = 0;

    Future<void> waitForNextFrame() async {
      pushedFrames++;
      final remaining =
          Duration(milliseconds: pushedFrames * 20) - clock.elapsed;
      if (remaining > Duration.zero) await _wait(remaining);
    }

    for (var offset = 0; offset < pcm.length; offset += frameBytes) {
      if (generation != _generation) return false;
      final frame = Uint8List(frameBytes);
      final end = (offset + frameBytes).clamp(0, pcm.length);
      frame.setRange(0, end - offset, pcm, offset);
      await push(frame);
      await waitForNextFrame();
    }
    for (var index = 0; index < tailFrames; index++) {
      if (generation != _generation) return false;
      await push(Uint8List(frameBytes));
      await waitForNextFrame();
    }
    return generation == _generation;
  }

  void cancel() => _generation++;
}
