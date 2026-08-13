import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// Sample-owned microphone capture. The SDK only receives the resulting PCM.
final class SamplePcmCapture {
  SamplePcmCapture({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  StreamSubscription<Uint8List>? _subscription;
  Future<void> _pushTail = Future<void>.value();

  bool get isRecording => _subscription != null;

  Future<void> start({
    required Future<void> Function(Uint8List frame) onFrame,
    required void Function(Object error) onError,
  }) async {
    if (isRecording) return;
    if (!await _recorder.hasPermission()) {
      throw StateError('麦克风权限未授权');
    }
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ),
    );
    _subscription = stream.listen((frame) {
      // Preserve capture order and avoid overlapping native push calls.
      _pushTail = _pushTail.then((_) => onFrame(frame)).catchError((
        Object error,
      ) {
        onError(error);
      });
    }, onError: onError);
  }

  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _recorder.stop();
    await _pushTail;
  }

  Future<void> dispose() async {
    await stop();
    _recorder.dispose();
  }
}
