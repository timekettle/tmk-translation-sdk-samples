import 'package:tmk_translation_flutter/tmk_translation_flutter.dart';

class ConversationBubble {
  ConversationBubble({
    required this.id,
    required this.sourceLangCode,
    required this.targetLangCode,
    this.channel,
    this.sourceText,
    this.translatedText,
    this.isFinal = false,
  });

  final String id;
  final String sourceLangCode;
  final String targetLangCode;
  final String? channel;
  final String? sourceText;
  final String? translatedText;
  final bool isFinal;

  ConversationBubble copyWith({
    String? sourceText,
    String? translatedText,
    bool? isFinal,
  }) {
    return ConversationBubble(
      id: id,
      sourceLangCode: sourceLangCode,
      targetLangCode: targetLangCode,
      channel: channel,
      sourceText: sourceText ?? this.sourceText,
      translatedText: translatedText ?? this.translatedText,
      isFinal: isFinal ?? this.isFinal,
    );
  }

  static String compositeId(TmkBubbleEvent event) {
    return '${event.bubbleId}::${event.channel ?? 'mono'}';
  }
}
