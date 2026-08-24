import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart' as api;

import 'tmk_translation_adapter.dart';

final class SamplePlaybackFrame {
  const SamplePlaybackFrame({
    required this.data,
    required this.sampleRate,
    required this.channelCount,
  });

  final Uint8List data;
  final int sampleRate;
  final int channelCount;

  int get frameCount => data.lengthInBytes ~/ (2 * channelCount);
}

SamplePlaybackFrame? selectSamplePlaybackFrame({
  required TmkAudioDataEvent event,
  required TmkScenario scenario,
  required TmkOneToOnePlaybackMode playbackMode,
}) {
  if (event.sampleRate <= 0 || event.channelCount <= 0) {
    throw const FormatException('翻译音频采样率或声道数无效');
  }
  final bytesPerFrame = 2 * event.channelCount;
  if (event.data.lengthInBytes % bytesPerFrame != 0) {
    throw const FormatException('翻译音频不是完整的 PCM16 帧');
  }
  if (scenario != TmkScenario.oneToOne) {
    return SamplePlaybackFrame(
      data: event.data,
      sampleRate: event.sampleRate,
      channelCount: event.channelCount,
    );
  }

  final route = event.route ?? api.TmkTranslatedAudioRoute.unknown;
  if (playbackMode == TmkOneToOnePlaybackMode.left &&
      route == api.TmkTranslatedAudioRoute.right) {
    return null;
  }
  if (playbackMode == TmkOneToOnePlaybackMode.right &&
      route == api.TmkTranslatedAudioRoute.left) {
    return null;
  }
  final isStereoRoute =
      route == api.TmkTranslatedAudioRoute.stereo ||
      (route == api.TmkTranslatedAudioRoute.unknown && event.channelCount >= 2);
  if (!isStereoRoute || event.channelCount < 2) {
    return SamplePlaybackFrame(
      data: event.data,
      sampleRate: event.sampleRate,
      channelCount: event.channelCount,
    );
  }
  return SamplePlaybackFrame(
    data: extractPcm16Lane(
      event.data,
      channelCount: event.channelCount,
      laneIndex: playbackMode == TmkOneToOnePlaybackMode.left ? 0 : 1,
    ),
    sampleRate: event.sampleRate,
    channelCount: 1,
  );
}

Uint8List extractPcm16Lane(
  Uint8List interleaved, {
  required int channelCount,
  required int laneIndex,
}) {
  if (channelCount < 2 || laneIndex < 0 || laneIndex >= channelCount) {
    throw ArgumentError('无效的 PCM 声道参数');
  }
  final bytesPerFrame = channelCount * 2;
  if (interleaved.lengthInBytes % bytesPerFrame != 0) {
    throw const FormatException('交错 PCM16 数据长度无效');
  }
  final result = Uint8List(interleaved.lengthInBytes ~/ channelCount);
  var writeOffset = 0;
  for (
    var readOffset = laneIndex * 2;
    readOffset + 1 < interleaved.lengthInBytes;
    readOffset += bytesPerFrame
  ) {
    result[writeOffset++] = interleaved[readOffset];
    result[writeOffset++] = interleaved[readOffset + 1];
  }
  return result;
}

abstract interface class SamplePcmPlaybackBackend {
  Future<void> setup({
    required int sampleRate,
    required int channelCount,
    required void Function(int remainingFrames) onRemainingFrames,
  });

  Future<void> feed(Uint8List pcm16LittleEndian);

  Future<void> release();
}

final class FlutterPcmPlaybackBackend implements SamplePcmPlaybackBackend {
  @override
  Future<void> setup({
    required int sampleRate,
    required int channelCount,
    required void Function(int remainingFrames) onRemainingFrames,
  }) async {
    await FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(
      sampleRate: sampleRate,
      channelCount: channelCount,
      iosAudioCategory: IosAudioCategory.playAndRecord,
    );
    await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 10);
    FlutterPcmSound.setFeedCallback(onRemainingFrames);
  }

  @override
  Future<void> feed(Uint8List pcm16LittleEndian) {
    final bytes = pcm16LittleEndian.buffer.asByteData(
      pcm16LittleEndian.offsetInBytes,
      pcm16LittleEndian.lengthInBytes,
    );
    return FlutterPcmSound.feed(PcmArrayInt16(bytes: bytes));
  }

  @override
  Future<void> release() async {
    FlutterPcmSound.setFeedCallback(null);
    await FlutterPcmSound.release();
  }
}

final class SamplePcmPlaybackOverflow implements Exception {
  const SamplePcmPlaybackOverflow();

  @override
  String toString() => '翻译音频播放积压超过 30 秒，已清空旧音频';
}

final class SamplePcmPlayer {
  SamplePcmPlayer({
    SamplePcmPlaybackBackend? backend,
    Future<void> Function()? onFormatSetup,
  }) : _backend = backend ?? FlutterPcmPlaybackBackend(),
       _onFormatSetup = onFormatSetup;

  static const maxBufferedDuration = Duration(seconds: 30);

  final SamplePcmPlaybackBackend _backend;
  final Future<void> Function()? _onFormatSetup;
  Future<void> _tail = Future<void>.value();
  int? _sampleRate;
  int? _channelCount;
  int _estimatedQueuedFrames = 0;
  int _remainingFramesRevision = 0;
  bool _disposed = false;

  Future<void> enqueue(SamplePlaybackFrame frame) {
    if (_disposed) {
      return Future<void>.error(StateError('PCM 播放器已释放'));
    }
    final completer = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        await _enqueueNow(frame);
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> prepare({required int sampleRate, required int channelCount}) {
    if (_disposed) {
      return Future<void>.error(StateError('PCM 播放器已释放'));
    }
    final completer = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        await _prepareNow(sampleRate, channelCount);
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _enqueueNow(SamplePlaybackFrame frame) async {
    await _prepareNow(frame.sampleRate, frame.channelCount);
    final maxFrames = frame.sampleRate * maxBufferedDuration.inSeconds;
    if (_estimatedQueuedFrames + frame.frameCount > maxFrames) {
      await _releaseNow();
      throw const SamplePcmPlaybackOverflow();
    }
    final revisionBeforeFeed = _remainingFramesRevision;
    await _backend.feed(frame.data);
    if (_remainingFramesRevision == revisionBeforeFeed) {
      _estimatedQueuedFrames += frame.frameCount;
    } else if (_estimatedQueuedFrames < frame.frameCount) {
      _estimatedQueuedFrames = frame.frameCount;
    }
  }

  Future<void> _prepareNow(int sampleRate, int channelCount) async {
    if (sampleRate <= 0 || channelCount <= 0) {
      throw ArgumentError('PCM 播放格式无效');
    }
    final formatChanged =
        _sampleRate != sampleRate || _channelCount != channelCount;
    if (formatChanged) {
      await _releaseNow();
      await _backend.setup(
        sampleRate: sampleRate,
        channelCount: channelCount,
        onRemainingFrames: (remainingFrames) {
          _estimatedQueuedFrames = remainingFrames < 0 ? 0 : remainingFrames;
          _remainingFramesRevision++;
        },
      );
      await _onFormatSetup?.call();
      _sampleRate = sampleRate;
      _channelCount = channelCount;
    }
  }

  Future<void> clear() {
    _tail = _tail.then((_) => _releaseNow());
    return _tail;
  }

  Future<void> _releaseNow() async {
    if (_sampleRate != null) {
      await _backend.release();
    }
    _sampleRate = null;
    _channelCount = null;
    _estimatedQueuedFrames = 0;
    _remainingFramesRevision = 0;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await clear();
  }
}
