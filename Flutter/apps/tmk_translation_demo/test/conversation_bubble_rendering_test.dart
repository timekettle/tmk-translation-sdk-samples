import 'package:flutter_test/flutter_test.dart';
import 'package:tmk_translation_demo/src/conversation_bubbles.dart';
import 'package:tmk_translation_demo/src/models.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart';

void main() {
  test('listen mode merges partial and final text into one bubble', () {
    final pipeline = ConversationBubbleRenderPipeline(
      scenario: TmkScenario.listen,
      mode: TmkTranslationMode.online,
      selectedSourceLanguage: 'zh-CN',
      selectedTargetLanguage: 'en-US',
    );

    final first = pipeline
        .consumePluginEvent(
          _recognizedEvent(
            bubbleId: 'bubble-1',
            sdkSessionId: '101',
            text: '你好',
            isFinal: false,
          ),
        )
        .last;
    expect(first.lane, ConversationLane.left);
    expect(first.sourceText, '你好...');

    final second = pipeline
        .consumePluginEvent(
          _recognizedEvent(
            bubbleId: 'bubble-1',
            sdkSessionId: '101',
            text: '你好世界',
            isFinal: false,
          ),
        )
        .last;
    expect(second.sourceText, '你好世界...');

    final third = pipeline
        .consumePluginEvent(
          _recognizedEvent(
            bubbleId: 'bubble-1',
            sdkSessionId: '101',
            text: '你好世界',
            isFinal: true,
          ),
        )
        .last;
    expect(third.sourceText, '你好世界');
  });

  test('starting a new bubble closes the previous active bubble', () {
    final pipeline = ConversationBubbleRenderPipeline(
      scenario: TmkScenario.listen,
      mode: TmkTranslationMode.online,
      selectedSourceLanguage: 'zh-CN',
      selectedTargetLanguage: 'en-US',
    );
    final snapshots = <String, ConversationBubbleSnapshot>{};

    void apply(TmkPluginEvent event) {
      for (final snapshot in pipeline.consumePluginEvent(event)) {
        snapshots[snapshot.id] = snapshot;
      }
    }

    apply(
      _recognizedEvent(
        bubbleId: 'bubble-1',
        sdkSessionId: '101',
        text: '第一条',
        isFinal: false,
      ),
    );
    apply(
      _recognizedEvent(
        bubbleId: 'bubble-2',
        sdkSessionId: '102',
        text: '第二条',
        isFinal: false,
      ),
    );

    expect(
      snapshots[ConversationBubble.rowId('bubble-1', ConversationLane.left)]!
          .sourceText,
      '第一条',
    );
    expect(
      snapshots[ConversationBubble.rowId('bubble-2', ConversationLane.left)]!
          .sourceText,
      '第二条...',
    );
  });

  test('online one-to-one uses lane and fixed language pair', () {
    final pipeline = ConversationBubbleRenderPipeline(
      scenario: TmkScenario.oneToOne,
      mode: TmkTranslationMode.online,
      selectedSourceLanguage: 'zh-CN',
      selectedTargetLanguage: 'en-US',
    );

    final rightSnapshot = pipeline
        .consumePluginEvent(
          _recognizedEvent(
            bubbleId: 'bubble-1',
            sdkSessionId: '201',
            channel: 'right',
            sourceLangCode: 'en-US',
            targetLangCode: 'zh-CN',
            text: '你好',
            isFinal: true,
          ),
        )
        .last;

    expect(rightSnapshot.lane, ConversationLane.right);
    expect(rightSnapshot.sourceLangCode, 'zh-CN');
    expect(rightSnapshot.targetLangCode, 'en-US');

    final leftSnapshot = pipeline
        .consumePluginEvent(
          _recognizedEvent(
            bubbleId: 'bubble-2',
            sdkSessionId: '202',
            channel: 'left',
            sourceLangCode: 'zh-CN',
            targetLangCode: 'en-US',
            text: 'hello',
            isFinal: true,
          ),
        )
        .last;

    expect(leftSnapshot.lane, ConversationLane.left);
    expect(leftSnapshot.sourceLangCode, 'en-US');
    expect(leftSnapshot.targetLangCode, 'zh-CN');
  });

  test('offline one-to-one keeps sdk language pair as-is', () {
    final pipeline = ConversationBubbleRenderPipeline(
      scenario: TmkScenario.oneToOne,
      mode: TmkTranslationMode.offline,
      selectedSourceLanguage: 'zh',
      selectedTargetLanguage: 'en',
    );

    final snapshot = pipeline
        .consumePluginEvent(
          _translatedEvent(
            bubbleId: 'bubble-3',
            sdkSessionId: '301',
            channel: 'right',
            sourceLangCode: 'en',
            targetLangCode: 'zh',
            text: '你好',
            isFinal: true,
          ),
        )
        .last;

    expect(snapshot.lane, ConversationLane.right);
    expect(snapshot.sourceLangCode, 'en');
    expect(snapshot.targetLangCode, 'zh');
  });
}

TmkRecognizedEvent _recognizedEvent({
  required String bubbleId,
  required String sdkSessionId,
  required bool isFinal,
  String? channel,
  String sourceLangCode = 'zh-CN',
  String targetLangCode = 'en-US',
  String? text,
}) {
  return TmkRecognizedEvent(
    sessionId: 'flutter-session',
    sdkSessionId: sdkSessionId,
    sourceLangCode: sourceLangCode,
    targetLangCode: targetLangCode,
    isFinal: isFinal,
    channel: channel,
    text: text,
    extraData: {'bubble_id': bubbleId},
  );
}

TmkTranslatedEvent _translatedEvent({
  required String bubbleId,
  required String sdkSessionId,
  required bool isFinal,
  String? channel,
  String sourceLangCode = 'zh-CN',
  String targetLangCode = 'en-US',
  String? text,
}) {
  return TmkTranslatedEvent(
    sessionId: 'flutter-session',
    sdkSessionId: sdkSessionId,
    sourceLangCode: sourceLangCode,
    targetLangCode: targetLangCode,
    isFinal: isFinal,
    channel: channel,
    text: text,
    extraData: {'bubble_id': bubbleId},
  );
}
