import 'dart:typed_data';

/// Builds the PCM payload required by the standard one-to-one channel mode.
///
/// The Sample owns capture and routing. The SDK receives an already formatted
/// PCM16 little-endian stream and never fills, interleaves, or resamples it.
abstract final class TmkOneToOnePcmRouter {
  /// Interleaves two mono PCM16 little-endian lanes as left/right frames.
  ///
  /// If one lane is shorter, the missing samples are filled with silence so a
  /// capture frame can be sent while the other input is unavailable.
  static Uint8List interleaveStereo16Le({
    required Uint8List left,
    required Uint8List right,
  }) {
    _checkPcm16(left, 'left');
    _checkPcm16(right, 'right');

    final frameCount =
        (left.length > right.length ? left.length : right.length) ~/ 2;
    final mixed = Uint8List(frameCount * 4);
    for (var frame = 0; frame < frameCount; frame++) {
      final sourceOffset = frame * 2;
      final destinationOffset = frame * 4;
      if (sourceOffset + 1 < left.length) {
        mixed[destinationOffset] = left[sourceOffset];
        mixed[destinationOffset + 1] = left[sourceOffset + 1];
      }
      if (sourceOffset + 1 < right.length) {
        mixed[destinationOffset + 2] = right[sourceOffset];
        mixed[destinationOffset + 3] = right[sourceOffset + 1];
      }
    }
    return mixed;
  }

  static void _checkPcm16(Uint8List data, String lane) {
    if (data.length.isOdd) {
      throw ArgumentError.value(
        data.length,
        lane,
        'PCM16 data must contain complete two-byte samples',
      );
    }
  }
}
