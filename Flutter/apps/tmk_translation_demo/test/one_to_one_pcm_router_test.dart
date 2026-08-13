import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tmk_translation_demo/src/one_to_one_pcm_router.dart';

void main() {
  test('interleaves two mono PCM16 lanes in left/right order', () {
    final mixed = TmkOneToOnePcmRouter.interleaveStereo16Le(
      left: Uint8List.fromList([1, 0, 2, 0]),
      right: Uint8List.fromList([3, 0, 4, 0]),
    );

    expect(mixed, [1, 0, 3, 0, 2, 0, 4, 0]);
  });

  test('pads the missing lane with PCM16 silence', () {
    final mixed = TmkOneToOnePcmRouter.interleaveStereo16Le(
      left: Uint8List(0),
      right: Uint8List.fromList([1, 0, 2, 0]),
    );

    expect(mixed, [0, 0, 1, 0, 0, 0, 2, 0]);
  });

  test('rejects incomplete PCM16 samples', () {
    expect(
      () => TmkOneToOnePcmRouter.interleaveStereo16Le(
        left: Uint8List.fromList([1]),
        right: Uint8List.fromList([2, 0]),
      ),
      throwsArgumentError,
    );
  });
}
