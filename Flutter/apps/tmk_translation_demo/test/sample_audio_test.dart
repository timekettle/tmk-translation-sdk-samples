import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tmk_translation_demo/src/sample_fixed_pcm_source.dart';
import 'package:tmk_translation_demo/src/sample_pcm_player.dart';
import 'package:tmk_translation_demo/src/sample_session_audio_input.dart';
import 'package:tmk_translation_demo/src/tmk_translation_adapter.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart' as api;

void main() {
  group('fixed PCM source', () {
    test(
      'selects platform asset and preserves legacy zero-padded loop',
      () async {
        final source = SampleFixedPcmSource(
          bundle: _MemoryAssetBundle({
            SampleFixedPcmSource.androidAsset: [1, 2, 3, 4, 5, 6],
            SampleFixedPcmSource.iosAsset: [7, 8],
          }),
        );

        await source.load(platform: TargetPlatform.android);
        expect(source.nextFrame(4), Uint8List.fromList([1, 2, 3, 4]));
        expect(source.nextFrame(4), Uint8List.fromList([5, 6, 0, 0]));
        expect(source.nextFrame(4), Uint8List.fromList([1, 2, 3, 4]));

        source.reset();
        expect(source.nextFrame(2), Uint8List.fromList([1, 2]));
      },
    );
  });

  group('session audio input', () {
    test('one-to-one Sample requests the explicit stereo contract', () {
      final config = toSdkSessionConfig(
        const TmkSessionConfig(
          scenario: TmkScenario.oneToOne,
          mode: api.TmkTranslationMode.online,
          sourceLanguage: 'zh-CN',
          targetLanguage: 'en-US',
        ),
      );

      expect(config.audioConfig.pcmChannels, 2);
      expect(
        config.audioConfig.channelAudioMode,
        api.TmkChannelAudioMode.standard,
      );
      expect(config.toMap()['oneToOneChannelMode'], 'interleaved');
    });

    test('listen pushes one mono frame', () async {
      final pushes = <_Push>[];
      await pushSampleAudioFrame(
        microphonePcm: Uint8List.fromList([1, 2]),
        scenario: TmkScenario.listen,
        useFixedAudio: true,
        nextFixedFrame: (_) => throw StateError('must not read fixed PCM'),
        push: (data, {channelCount, speakerChannel}) async {
          pushes.add(_Push(data, channelCount, speakerChannel));
        },
      );

      expect(pushes, hasLength(1));
      expect(pushes.single.channelCount, 1);
      expect(pushes.single.speakerChannel, isNull);
    });

    test(
      'one-to-one interleaves left fixed PCM and right microphone',
      () async {
        final pushes = <_Push>[];
        await pushSampleAudioFrame(
          microphonePcm: Uint8List.fromList([1, 2]),
          scenario: TmkScenario.oneToOne,
          useFixedAudio: true,
          nextFixedFrame: (length) => Uint8List.fromList([3, 4]),
          push: (data, {channelCount, speakerChannel}) async {
            pushes.add(_Push(data, channelCount, speakerChannel));
          },
        );

        expect(pushes, hasLength(1));
        expect(pushes.single.channelCount, 2);
        expect(pushes.single.speakerChannel, isNull);
        expect(pushes.single.data, Uint8List.fromList([3, 4, 1, 2]));
      },
    );

    test('one-to-one stereo router pads a shorter lane with silence', () {
      expect(
        interleavePcm16Le(
          left: Uint8List.fromList([1, 2]),
          right: Uint8List.fromList([3, 4, 5, 6]),
        ),
        Uint8List.fromList([1, 2, 3, 4, 0, 0, 5, 6]),
      );
    });
  });

  group('translated audio routing', () {
    final stereo = TmkAudioDataEvent(
      sessionId: 'session',
      data: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      sampleRate: 16000,
      channelCount: 2,
      route: api.TmkTranslatedAudioRoute.stereo,
    );

    test('splits selected lane from interleaved stereo PCM16', () {
      final left = selectSamplePlaybackFrame(
        event: stereo,
        scenario: TmkScenario.oneToOne,
        playbackMode: TmkOneToOnePlaybackMode.left,
      );
      final right = selectSamplePlaybackFrame(
        event: stereo,
        scenario: TmkScenario.oneToOne,
        playbackMode: TmkOneToOnePlaybackMode.right,
      );

      expect(left!.data, Uint8List.fromList([1, 2, 5, 6]));
      expect(right!.data, Uint8List.fromList([3, 4, 7, 8]));
      expect(left.channelCount, 1);
      expect(right.channelCount, 1);
    });

    test('filters the route not selected by playback mode', () {
      final rightEvent = TmkAudioDataEvent(
        sessionId: 'session',
        data: Uint8List.fromList([1, 2]),
        sampleRate: 16000,
        channelCount: 1,
        route: api.TmkTranslatedAudioRoute.right,
      );

      expect(
        selectSamplePlaybackFrame(
          event: rightEvent,
          scenario: TmkScenario.oneToOne,
          playbackMode: TmkOneToOnePlaybackMode.left,
        ),
        isNull,
      );
    });
  });

  group('PCM player', () {
    test('feeds in order and reconfigures when format changes', () async {
      final backend = _FakePlaybackBackend();
      var duplexRestoreCount = 0;
      final player = SamplePcmPlayer(
        backend: backend,
        onFormatSetup: () async => duplexRestoreCount++,
      );

      await player.enqueue(
        SamplePlaybackFrame(
          data: Uint8List.fromList([1, 2]),
          sampleRate: 16000,
          channelCount: 1,
        ),
      );
      await player.enqueue(
        SamplePlaybackFrame(
          data: Uint8List.fromList([3, 4]),
          sampleRate: 8000,
          channelCount: 1,
        ),
      );

      expect(backend.formats, [(16000, 1), (8000, 1)]);
      expect(backend.frames, [
        [1, 2],
        [3, 4],
      ]);
      expect(backend.releaseCount, 1);
      expect(duplexRestoreCount, 2);
      await player.dispose();
    });

    test('prepares output before capture without feeding audio', () async {
      final backend = _FakePlaybackBackend();
      final player = SamplePcmPlayer(backend: backend);

      await player.prepare(sampleRate: 16000, channelCount: 1);
      await player.prepare(sampleRate: 16000, channelCount: 1);

      expect(backend.formats, [(16000, 1)]);
      expect(backend.frames, isEmpty);
      await player.dispose();
    });

    test('clears audio when buffered duration exceeds 30 seconds', () async {
      final backend = _FakePlaybackBackend();
      final player = SamplePcmPlayer(backend: backend);

      await expectLater(
        player.enqueue(
          SamplePlaybackFrame(
            data: Uint8List(62),
            sampleRate: 1,
            channelCount: 1,
          ),
        ),
        throwsA(isA<SamplePcmPlaybackOverflow>()),
      );
      expect(backend.frames, isEmpty);
      expect(backend.releaseCount, 1);
      await player.dispose();
    });
  });
}

final class _MemoryAssetBundle extends CachingAssetBundle {
  _MemoryAssetBundle(this.assets);

  final Map<String, List<int>> assets;

  @override
  Future<ByteData> load(String key) async {
    final bytes = Uint8List.fromList(assets[key]!);
    return bytes.buffer.asByteData();
  }
}

final class _Push {
  const _Push(this.data, this.channelCount, this.speakerChannel);

  final Uint8List data;
  final int? channelCount;
  final api.TmkSpeakerChannel? speakerChannel;
}

final class _FakePlaybackBackend implements SamplePcmPlaybackBackend {
  final List<(int, int)> formats = [];
  final List<List<int>> frames = [];
  int releaseCount = 0;

  @override
  Future<void> setup({
    required int sampleRate,
    required int channelCount,
    required void Function(int remainingFrames) onRemainingFrames,
  }) async {
    formats.add((sampleRate, channelCount));
  }

  @override
  Future<void> feed(Uint8List pcm16LittleEndian) async {
    frames.add(pcm16LittleEndian.toList());
  }

  @override
  Future<void> release() async {
    releaseCount++;
  }
}
