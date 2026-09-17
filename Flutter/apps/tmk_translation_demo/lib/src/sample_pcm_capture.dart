import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Sample-owned microphone capture. The SDK only receives the resulting PCM.
final class SamplePcmCapture {
  SamplePcmCapture({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  StreamSubscription<Uint8List>? _subscription;
  Future<void>? _startTask;
  Future<void> _pushTail = Future<void>.value();

  bool get isRecording => _subscription != null;

  Future<void> start({
    required Future<void> Function(Uint8List frame) onFrame,
    required void Function(Object error) onError,
  }) {
    if (_startTask case final pending?) return pending;
    if (isRecording) return Future<void>.value();
    late final Future<void> task;
    task = _startNow(onFrame: onFrame, onError: onError).whenComplete(() {
      if (identical(_startTask, task)) _startTask = null;
    });
    _startTask = task;
    return task;
  }

  Future<void> _startNow({
    required Future<void> Function(Uint8List frame) onFrame,
    required void Function(Object error) onError,
  }) async {
    if (!await _recorder.hasPermission()) {
      throw StateError('麦克风权限未授权');
    }
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        // Keep Sample-owned external capture consistent across platforms.
        // Speaker output may be recaptured by the microphone when played
        // aloud; that remains observable as right-lane input by design.
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        streamBufferSize: isIos ? 1024 : null,
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
    // A stop can race startStream; do not leave a late subscription attached.
    try {
      await _startTask;
    } catch (_) {
      // Still ask the recorder to stop after a failed start.
    }
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _recorder.stop();
    await _pushTail;
  }

  /// Restores the full-duplex route after the PCM output plugin configures
  /// AVAudioSession. This matches the original iOS VoiceProcessingIO sample:
  /// play-and-record, speaker by default, and Bluetooth input/output support.
  Future<void> restoreDuplexAudioSession() async {
    final ios = _recorder.ios;
    if (ios == null) return;
    await ios.setAudioSessionCategory(
      category: IosAudioCategory.playAndRecord,
      options: const [
        IosAudioCategoryOptions.defaultToSpeaker,
        IosAudioCategoryOptions.allowBluetooth,
      ],
    );
    // Capture and the PCM output AudioUnit are already active here. Calling
    // setActive(true) again can fail with AVAudioSession '!pla'
    // (CannotStartPlaying) while translated audio is being rendered.
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }
}
