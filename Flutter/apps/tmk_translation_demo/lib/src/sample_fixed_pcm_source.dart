import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Sample-owned fixed PCM source used by the original one-to-one demo.
final class SampleFixedPcmSource {
  SampleFixedPcmSource({
    AssetBundle? bundle,
    Duration restartDelay = const Duration(seconds: 3),
    int Function()? nowMs,
  }) : assert(!restartDelay.isNegative),
       _bundle = bundle ?? rootBundle,
       _restartDelayMs = restartDelay.inMilliseconds,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const androidAsset = 'assets/audio/fixed_android_en_us_16k16.pcm';
  static const iosAsset = 'assets/audio/fixed_ios_en_us_16k16.pcm';

  final AssetBundle _bundle;
  final int _restartDelayMs;
  final int Function() _nowMs;
  Uint8List? _pcm;
  int _offset = 0;
  int? _resumeAtMs;

  bool get isLoaded => _pcm != null;

  Future<void> load({TargetPlatform? platform}) async {
    final resolvedPlatform = platform ?? defaultTargetPlatform;
    final asset = switch (resolvedPlatform) {
      TargetPlatform.android => androidAsset,
      TargetPlatform.iOS => iosAsset,
      _ => throw UnsupportedError('固定 PCM 仅支持 Android 和 iOS'),
    };
    final data = await _bundle.load(asset);
    _pcm = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    reset();
  }

  Uint8List nextFrame(int lengthInBytes) {
    if (lengthInBytes < 0) {
      throw ArgumentError.value(lengthInBytes, 'lengthInBytes');
    }
    final pcm = _pcm;
    if (pcm == null || pcm.isEmpty) {
      throw StateError('固定 PCM 尚未加载');
    }
    final frame = Uint8List(lengthInBytes);
    if (lengthInBytes == 0) return frame;
    final resumeAtMs = _resumeAtMs;
    if (resumeAtMs != null) {
      if (_nowMs() < resumeAtMs) return frame;
      _resumeAtMs = null;
      _offset = 0;
    }
    final available = pcm.length - _offset;
    final copyLength = available < lengthInBytes ? available : lengthInBytes;
    if (copyLength > 0) {
      frame.setRange(0, copyLength, pcm, _offset);
    }
    _offset += copyLength;
    if (_offset >= pcm.length) {
      _resumeAtMs = _nowMs() + _restartDelayMs;
    }
    return frame;
  }

  void reset() {
    _offset = 0;
    _resumeAtMs = null;
  }
}
