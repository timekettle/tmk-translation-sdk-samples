import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Sample-owned fixed PCM source used by the original one-to-one demo.
final class SampleFixedPcmSource {
  SampleFixedPcmSource({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  static const androidAsset = 'assets/audio/fixed_android_en_us_16k16.pcm';
  static const iosAsset = 'assets/audio/fixed_ios_en_us_16k16.pcm';

  final AssetBundle _bundle;
  Uint8List? _pcm;
  int _offset = 0;

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
    _offset = 0;
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
    final available = pcm.length - _offset;
    final copyLength = available < lengthInBytes ? available : lengthInBytes;
    if (copyLength > 0) {
      frame.setRange(0, copyLength, pcm, _offset);
    }
    _offset += copyLength;
    if (_offset >= pcm.length) {
      _offset = 0;
    }
    return frame;
  }

  void reset() {
    _offset = 0;
  }
}
