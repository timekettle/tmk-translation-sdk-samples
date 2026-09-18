import 'dart:typed_data';

import 'package:tmk_translation_flutter/tmk_translation_flutter.dart' as api;

import 'tmk_translation_adapter.dart';

typedef SamplePcmPush =
    Future<void> Function(
      Uint8List data, {
      int? channelCount,
      api.TmkSpeakerChannel? speakerChannel,
    });

Future<void> pushSampleAudioFrame({
  required Uint8List microphonePcm,
  required TmkScenario scenario,
  required bool useFixedAudio,
  required Uint8List Function(int lengthInBytes) nextFixedFrame,
  required SamplePcmPush push,
}) async {
  if (scenario != TmkScenario.oneToOne) {
    await push(microphonePcm, channelCount: 1);
    return;
  }

  final fixedPcm = useFixedAudio
      ? nextFixedFrame(microphonePcm.lengthInBytes)
      : Uint8List(microphonePcm.lengthInBytes);
  await push(
    interleavePcm16Le(left: fixedPcm, right: microphonePcm),
    channelCount: 2,
  );
}

Uint8List interleavePcm16Le({
  required Uint8List left,
  required Uint8List right,
}) {
  if (left.lengthInBytes.isOdd || right.lengthInBytes.isOdd) {
    throw ArgumentError('PCM16 input must contain complete two-byte samples');
  }
  final frameCount =
      (left.lengthInBytes > right.lengthInBytes
          ? left.lengthInBytes
          : right.lengthInBytes) ~/
      2;
  final interleaved = Uint8List(frameCount * 4);
  for (var frame = 0; frame < frameCount; frame++) {
    final sourceOffset = frame * 2;
    final outputOffset = frame * 4;
    if (sourceOffset + 1 < left.lengthInBytes) {
      interleaved[outputOffset] = left[sourceOffset];
      interleaved[outputOffset + 1] = left[sourceOffset + 1];
    }
    if (sourceOffset + 1 < right.lengthInBytes) {
      interleaved[outputOffset + 2] = right[sourceOffset];
      interleaved[outputOffset + 3] = right[sourceOffset + 1];
    }
  }
  return interleaved;
}
