enum ConversationLane {
  left('left'),
  right('right');

  const ConversationLane(this.value);

  final String value;
}

class ConversationBubble {
  ConversationBubble({
    required this.id,
    required this.bubbleId,
    required this.sdkSessionId,
    required this.lane,
    required this.sourceLangCode,
    required this.targetLangCode,
    this.sourceText,
    this.translatedText,
  });

  final String id;
  final String bubbleId;
  final String sdkSessionId;
  final ConversationLane lane;
  final String sourceLangCode;
  final String targetLangCode;
  final String? sourceText;
  final String? translatedText;

  bool get isRightLane => lane == ConversationLane.right;

  String get sourceDisplay =>
      (sourceText ?? '').trim().isEmpty ? '...' : sourceText!.trim();

  String get translatedDisplay =>
      (translatedText ?? '').trim().isEmpty ? '...' : translatedText!.trim();

  ConversationBubble copyWith({String? sourceText, String? translatedText}) {
    return ConversationBubble(
      id: id,
      bubbleId: bubbleId,
      sdkSessionId: sdkSessionId,
      lane: lane,
      sourceLangCode: sourceLangCode,
      targetLangCode: targetLangCode,
      sourceText: sourceText ?? this.sourceText,
      translatedText: translatedText ?? this.translatedText,
    );
  }

  static String rowId(String bubbleId, ConversationLane lane) {
    return '$bubbleId::${lane.value}';
  }
}
