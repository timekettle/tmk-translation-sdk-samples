import 'package:tmk_translation_flutter/tmk_translation_flutter.dart';

import 'models.dart';

enum ConversationStage { asr, mt, tts }

class ConversationEvent {
  const ConversationEvent({
    required this.bubbleId,
    required this.sdkSessionId,
    required this.lane,
    required this.stage,
    required this.isFinal,
    required this.text,
    required this.sourceLangCode,
    required this.targetLangCode,
  });

  final String bubbleId;
  final String sdkSessionId;
  final ConversationLane lane;
  final ConversationStage stage;
  final bool isFinal;
  final String? text;
  final String sourceLangCode;
  final String targetLangCode;

  ConversationEvent copyWith({
    ConversationLane? lane,
    String? sourceLangCode,
    String? targetLangCode,
  }) {
    return ConversationEvent(
      bubbleId: bubbleId,
      sdkSessionId: sdkSessionId,
      lane: lane ?? this.lane,
      stage: stage,
      isFinal: isFinal,
      text: text,
      sourceLangCode: sourceLangCode ?? this.sourceLangCode,
      targetLangCode: targetLangCode ?? this.targetLangCode,
    );
  }
}

class ConversationBubbleSnapshot {
  const ConversationBubbleSnapshot({
    required this.bubbleId,
    required this.sdkSessionId,
    required this.lane,
    required this.sourceLangCode,
    required this.targetLangCode,
    required this.sourceText,
    required this.translatedText,
  });

  final String bubbleId;
  final String sdkSessionId;
  final ConversationLane lane;
  final String sourceLangCode;
  final String targetLangCode;
  final String sourceText;
  final String translatedText;

  String get id => ConversationBubble.rowId(bubbleId, lane);
}

class ConversationBubbleRenderPipeline {
  ConversationBubbleRenderPipeline({
    required this.scenario,
    required this.mode,
    required this.selectedSourceLanguage,
    required this.selectedTargetLanguage,
  });

  final TmkScenario scenario;
  final TmkTranslationMode mode;
  final String selectedSourceLanguage;
  final String selectedTargetLanguage;

  final ConversationBubbleAssembler _assembler = ConversationBubbleAssembler();
  final Map<String, ConversationLane> _bubbleLaneMap = {};

  void reset() {
    _assembler.reset();
    _bubbleLaneMap.clear();
  }

  List<ConversationBubbleSnapshot> consumePluginEvent(TmkPluginEvent event) {
    final rawEvent = _adaptPluginEvent(event);
    if (rawEvent == null) {
      return const [];
    }
    final effectiveEvent = _normalize(
      rawEvent,
      explicitLane: _laneForPluginEvent(event),
    );
    return _assembler.consume(effectiveEvent);
  }

  ConversationEvent? _adaptPluginEvent(TmkPluginEvent event) {
    if (event is TmkRecognizedEvent) {
      return _makeTextEvent(
        event,
        stage: ConversationStage.asr,
      );
    }
    if (event is TmkTranslatedEvent) {
      return _makeTextEvent(
        event,
        stage: ConversationStage.mt,
      );
    }
    if (event is TmkBubbleEvent) {
      return _adaptLegacyBubbleEvent(event);
    }
    return null;
  }

  ConversationEvent? _makeTextEvent(
    TmkConversationTextEvent event, {
    required ConversationStage stage,
  }) {
    final normalizedText = _normalized(event.text);
    if (!_isDisplayable(normalizedText, isFinal: event.isFinal)) {
      return null;
    }
    return ConversationEvent(
      bubbleId: _bubbleId(event),
      sdkSessionId: event.sdkSessionId,
      lane: _parseLane(event.channel) ?? ConversationLane.left,
      stage: stage,
      isFinal: event.isFinal,
      text: normalizedText,
      sourceLangCode: event.sourceLangCode,
      targetLangCode: event.targetLangCode,
    );
  }

  ConversationEvent? _adaptLegacyBubbleEvent(TmkBubbleEvent event) {
    if (event.sourceText != null) {
      return _makeLegacyBubbleEvent(
        event,
        stage: ConversationStage.asr,
        text: event.sourceText,
      );
    }
    if (event.translatedText != null) {
      return _makeLegacyBubbleEvent(
        event,
        stage: ConversationStage.mt,
        text: event.translatedText,
      );
    }
    return null;
  }

  ConversationEvent? _makeLegacyBubbleEvent(
    TmkBubbleEvent event, {
    required ConversationStage stage,
    required String? text,
  }) {
    final normalizedText = _normalized(text);
    if (!_isDisplayable(normalizedText, isFinal: event.isFinal)) {
      return null;
    }
    return ConversationEvent(
      bubbleId: _legacyBubbleId(event),
      sdkSessionId: event.sdkSessionId,
      lane: _parseLane(event.channel) ?? ConversationLane.left,
      stage: stage,
      isFinal: event.isFinal,
      text: normalizedText,
      sourceLangCode: event.sourceLangCode,
      targetLangCode: event.targetLangCode,
    );
  }

  ConversationEvent _normalize(
    ConversationEvent event, {
    required ConversationLane? explicitLane,
  }) {
    if (scenario == TmkScenario.listen) {
      return event.copyWith(lane: ConversationLane.left);
    }
    if (mode != TmkTranslationMode.online) {
      return event;
    }
    final lane = _resolveLane(
      bubbleId: event.bubbleId,
      explicitLane: explicitLane,
      sourceLangCode: event.sourceLangCode,
      targetLangCode: event.targetLangCode,
    );
    final languagePair = _fixedLanguagePair(lane);
    return event.copyWith(
      lane: lane,
      sourceLangCode: languagePair.source,
      targetLangCode: languagePair.target,
    );
  }

  ConversationLane _resolveLane({
    required String bubbleId,
    required ConversationLane? explicitLane,
    required String sourceLangCode,
    required String targetLangCode,
  }) {
    if (explicitLane != null) {
      _bubbleLaneMap[bubbleId] = explicitLane;
      return explicitLane;
    }
    final cached = _bubbleLaneMap[bubbleId];
    if (cached != null) {
      return cached;
    }
    final sourceLower = sourceLangCode.toLowerCase();
    final targetLower = targetLangCode.toLowerCase();
    final inferred =
        sourceLower.startsWith(_sourceLanguagePrefix()) ||
            targetLower.startsWith(_targetLanguagePrefix())
        ? ConversationLane.right
        : ConversationLane.left;
    _bubbleLaneMap[bubbleId] = inferred;
    return inferred;
  }

  ({String source, String target}) _fixedLanguagePair(ConversationLane lane) {
    switch (lane) {
      case ConversationLane.right:
        return (source: selectedSourceLanguage, target: selectedTargetLanguage);
      case ConversationLane.left:
        return (source: selectedTargetLanguage, target: selectedSourceLanguage);
    }
  }

  String _sourceLanguagePrefix() {
    return selectedSourceLanguage.split('-').first.toLowerCase();
  }

  String _targetLanguagePrefix() {
    return selectedTargetLanguage.split('-').first.toLowerCase();
  }

  static ConversationLane? _parseLane(String? channel) {
    switch (channel?.trim().toLowerCase()) {
      case 'left':
        return ConversationLane.left;
      case 'right':
        return ConversationLane.right;
      default:
        return null;
    }
  }

  static ConversationLane? _laneForPluginEvent(TmkPluginEvent event) {
    return switch (event) {
      TmkConversationTextEvent() => _parseLane(
        event.channel ?? event.extraData['channel']?.toString(),
      ),
      TmkBubbleEvent() => _parseLane(event.channel),
      _ => null,
    };
  }

  static String _bubbleId(TmkConversationTextEvent event) {
    final extraData = event.extraData;
    final candidates = <Object?>[
      extraData['bubble_id'],
      extraData['bubbleId'],
      extraData['serialId'],
      extraData['msgId'],
    ];
    for (final candidate in candidates) {
      final value = candidate?.toString().trim() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
    return event.sdkSessionId.isEmpty ? '' : 'sid_${event.sdkSessionId}';
  }

  static String _legacyBubbleId(TmkBubbleEvent event) {
    return event.bubbleId.isEmpty
        ? 'sid_${event.sdkSessionId}'
        : event.bubbleId;
  }

  static String _normalized(String? text) {
    return (text ?? '').trim();
  }

  static bool _isDisplayable(String text, {required bool isFinal}) {
    if (text.isEmpty) {
      return isFinal;
    }
    return _containsMeaningfulContent(text);
  }

  static bool _containsMeaningfulContent(String text) {
    for (final rune in text.runes) {
      if (_isIgnorableRune(rune)) {
        continue;
      }
      return true;
    }
    return false;
  }

  static bool _isIgnorableRune(int rune) {
    final char = String.fromCharCode(rune);
    if (char.trim().isEmpty) {
      return true;
    }
    return _isPunctuationOrSymbol(rune);
  }

  static bool _isPunctuationOrSymbol(int rune) {
    if ((rune >= 0x21 && rune <= 0x2F) ||
        (rune >= 0x3A && rune <= 0x40) ||
        (rune >= 0x5B && rune <= 0x60) ||
        (rune >= 0x7B && rune <= 0x7E)) {
      return true;
    }
    if (rune >= 0x3000 && rune <= 0x303F) {
      return true;
    }
    if ((rune >= 0xFF01 && rune <= 0xFF0F) ||
        (rune >= 0xFF1A && rune <= 0xFF20) ||
        (rune >= 0xFF3B && rune <= 0xFF40) ||
        (rune >= 0xFF5B && rune <= 0xFF65)) {
      return true;
    }
    return false;
  }
}

class ConversationBubbleAssembler {
  final Map<String, _BubbleAggregate> _aggregates = {};
  final Map<ConversationLane, String> _activeBubbleIdByLane = {};

  void reset() {
    _aggregates.clear();
    _activeBubbleIdByLane.clear();
  }

  List<ConversationBubbleSnapshot> consume(ConversationEvent event) {
    final key = rowKey(event.bubbleId, event.lane);
    final snapshots = <ConversationBubbleSnapshot>[];

    final previousBubbleId = _activeBubbleIdByLane[event.lane];
    if (previousBubbleId != null && previousBubbleId != event.bubbleId) {
      final previousKey = rowKey(previousBubbleId, event.lane);
      final previousAggregate = _aggregates[previousKey];
      if (previousAggregate != null) {
        final previousSnapshot = _makeSnapshot(
          bubbleId: previousBubbleId,
          lane: event.lane,
          aggregate: previousAggregate,
          isActiveBubble: false,
        );
        if (previousSnapshot != null) {
          snapshots.add(previousSnapshot);
        }
      }
    }

    _activeBubbleIdByLane[event.lane] = event.bubbleId;
    final aggregate =
        _aggregates[key] ??
        _BubbleAggregate(
          sourceLangCode: event.sourceLangCode,
          targetLangCode: event.targetLangCode,
        );

    aggregate.latestSessionId = _maxSessionId(
      aggregate.latestSessionId,
      event.sdkSessionId,
    );
    aggregate.sourceLangCode = event.sourceLangCode;
    aggregate.targetLangCode = event.targetLangCode;

    switch (event.stage) {
      case ConversationStage.asr:
        _update(
          segmentText: event.text,
          isFinal: event.isFinal,
          sessionId: event.sdkSessionId,
          sessionOrder: aggregate.sourceSessionOrder,
          segments: aggregate.sourceBySession,
          sessionAliases: aggregate.sourceSessionAlias,
        );
      case ConversationStage.mt:
        _update(
          segmentText: event.text,
          isFinal: event.isFinal,
          sessionId: event.sdkSessionId,
          sessionOrder: aggregate.translatedSessionOrder,
          segments: aggregate.translatedBySession,
          sessionAliases: aggregate.translatedSessionAlias,
        );
      case ConversationStage.tts:
        break;
    }

    _aggregates[key] = aggregate;
    final currentSnapshot = _makeSnapshot(
      bubbleId: event.bubbleId,
      lane: event.lane,
      aggregate: aggregate,
      isActiveBubble: true,
    );
    if (currentSnapshot != null) {
      snapshots.add(currentSnapshot);
    }
    return snapshots;
  }

  static String rowKey(String bubbleId, ConversationLane lane) {
    return ConversationBubble.rowId(bubbleId, lane);
  }

  ConversationBubbleSnapshot? _makeSnapshot({
    required String bubbleId,
    required ConversationLane lane,
    required _BubbleAggregate aggregate,
    required bool isActiveBubble,
  }) {
    final sourceText = _composeText(
      order: aggregate.sourceSessionOrder,
      segments: aggregate.sourceBySession,
      isActiveBubble: isActiveBubble,
    );
    final translatedText = _composeText(
      order: aggregate.translatedSessionOrder,
      segments: aggregate.translatedBySession,
      isActiveBubble: isActiveBubble,
    );
    if (sourceText.isEmpty && translatedText.isEmpty) {
      return null;
    }
    return ConversationBubbleSnapshot(
      bubbleId: bubbleId,
      sdkSessionId: aggregate.latestSessionId,
      lane: lane,
      sourceLangCode: aggregate.sourceLangCode,
      targetLangCode: aggregate.targetLangCode,
      sourceText: sourceText,
      translatedText: translatedText,
    );
  }

  void _update({
    required String? segmentText,
    required bool isFinal,
    required String sessionId,
    required List<String> sessionOrder,
    required Map<String, _SessionSegment> segments,
    required Map<String, String> sessionAliases,
  }) {
    final text = (segmentText ?? '').trim();
    if (text.isEmpty && !isFinal) {
      return;
    }
    final effectiveSessionId = sessionAliases[sessionId] ?? sessionId;
    if (!sessionOrder.contains(effectiveSessionId)) {
      sessionOrder.add(effectiveSessionId);
    }
    final old = segments[effectiveSessionId];
    if (old != null &&
        old.isFinal &&
        text.isNotEmpty &&
        !_isIncrementalTransition(old.text, text)) {
      final newSessionId = _nextSyntheticSessionId(segments);
      sessionOrder.add(newSessionId);
      segments[newSessionId] = _SessionSegment(text: text, isFinal: isFinal);
      sessionAliases[sessionId] = newSessionId;
      return;
    }
    final mergedText = _resolveIncrementalText(old?.text ?? '', text);
    final finalValue = (old?.isFinal ?? false) || isFinal;
    segments[effectiveSessionId] = _SessionSegment(
      text: mergedText,
      isFinal: finalValue,
    );
    sessionAliases[sessionId] = effectiveSessionId;
  }

  String _composeText({
    required List<String> order,
    required Map<String, _SessionSegment> segments,
    required bool isActiveBubble,
  }) {
    final orderedTexts = <String>[];
    var latestIsFinal = true;
    for (final sessionId in order) {
      final segment = segments[sessionId];
      if (segment == null) {
        continue;
      }
      final text = _normalizedDisplayText(
        segment.text,
        isFinal: segment.isFinal,
      );
      if (text.isEmpty) {
        continue;
      }
      orderedTexts.add(text);
      latestIsFinal = segment.isFinal;
    }
    if (orderedTexts.isEmpty) {
      return '';
    }
    var merged = orderedTexts.first;
    for (var index = 1; index < orderedTexts.length; index += 1) {
      merged = _mergeCumulativeText(merged, orderedTexts[index]);
    }
    if (latestIsFinal || !isActiveBubble) {
      return _removeTrailingEllipsis(merged);
    }
    return _appendEllipsisIfNeeded(merged);
  }

  String _resolveIncrementalText(String oldText, String newText) {
    final lhs = oldText.trim();
    final rhs = newText.trim();
    if (rhs.isEmpty) {
      return lhs;
    }
    if (lhs.isEmpty) {
      return rhs;
    }
    if (_shouldPreferRightInUpdate(lhs, rhs)) {
      return rhs;
    }
    if (_shouldPreferLeftInUpdate(lhs, rhs)) {
      return lhs;
    }
    return rhs;
  }

  String _mergeCumulativeText(String lhsRaw, String rhsRaw) {
    final lhs = lhsRaw.trim();
    final rhs = rhsRaw.trim();
    if (lhs.isEmpty) {
      return rhs;
    }
    if (rhs.isEmpty) {
      return lhs;
    }
    if (_shouldPreferRightInMerge(lhs, rhs)) {
      return rhs;
    }
    if (_shouldPreferLeftInMerge(lhs, rhs)) {
      return lhs;
    }
    final overlap = _longestOverlap(lhs, rhs);
    if (overlap > 0) {
      return lhs + rhs.substring(overlap);
    }
    final similarity = _normalizedSimilarity(lhs, rhs);
    if (similarity >= 0.78) {
      return rhs.length >= lhs.length ? rhs : lhs;
    }
    return '$lhs $rhs';
  }

  int _longestOverlap(String lhs, String rhs) {
    final maxCount = lhs.length < rhs.length ? lhs.length : rhs.length;
    for (var count = maxCount; count >= 1; count -= 1) {
      if (lhs.substring(lhs.length - count) == rhs.substring(0, count)) {
        return count;
      }
    }
    return 0;
  }

  String _appendEllipsisIfNeeded(String text) {
    if (text.endsWith('...') || text.endsWith('…')) {
      return text;
    }
    return '$text...';
  }

  String _normalizedDisplayText(String text, {required bool isFinal}) {
    final normalized = text.trim();
    if (!isFinal) {
      return normalized;
    }
    return _removeTrailingEllipsis(normalized);
  }

  String _removeTrailingEllipsis(String text) {
    var normalized = text.trim();
    while (normalized.endsWith('...') || normalized.endsWith('…')) {
      if (normalized.endsWith('...')) {
        normalized = normalized.substring(0, normalized.length - 3).trim();
      } else {
        normalized = normalized.substring(0, normalized.length - 1).trim();
      }
    }
    return normalized;
  }

  bool _isIncrementalTransition(String oldText, String newText) {
    final lhs = oldText.trim();
    final rhs = newText.trim();
    if (lhs.isEmpty || rhs.isEmpty) {
      return false;
    }
    if (_shouldPreferRightInUpdate(lhs, rhs)) {
      return true;
    }
    if (_shouldPreferLeftInUpdate(lhs, rhs)) {
      return true;
    }
    return _normalizedSimilarity(lhs, rhs) >= 0.70;
  }

  String _nextSyntheticSessionId(Map<String, _SessionSegment> segments) {
    var index = -1;
    while (segments.containsKey('$index')) {
      index -= 1;
    }
    return '$index';
  }

  bool _shouldPreferRightInUpdate(String lhs, String rhs) {
    if (lhs == rhs) {
      return true;
    }
    if (rhs.startsWith(lhs) || rhs.contains(lhs)) {
      return true;
    }
    final lhsKey = _normalizeCompareKey(lhs);
    final rhsKey = _normalizeCompareKey(rhs);
    if (lhsKey.isEmpty || rhsKey.isEmpty) {
      return false;
    }
    if (rhsKey == lhsKey) {
      return true;
    }
    if (rhsKey.startsWith(lhsKey) || rhsKey.contains(lhsKey)) {
      return true;
    }
    return _normalizedSimilarity(lhs, rhs) >= 0.88 && rhs.length >= lhs.length;
  }

  bool _shouldPreferLeftInUpdate(String lhs, String rhs) {
    if (lhs.startsWith(rhs) || lhs.contains(rhs)) {
      return true;
    }
    final lhsKey = _normalizeCompareKey(lhs);
    final rhsKey = _normalizeCompareKey(rhs);
    if (lhsKey.isEmpty || rhsKey.isEmpty) {
      return false;
    }
    if (lhsKey.startsWith(rhsKey) || lhsKey.contains(rhsKey)) {
      return true;
    }
    return _normalizedSimilarity(lhs, rhs) >= 0.88 && lhs.length > rhs.length;
  }

  bool _shouldPreferRightInMerge(String lhs, String rhs) {
    if (lhs == rhs) {
      return false;
    }
    if (rhs.startsWith(lhs) || rhs.contains(lhs)) {
      return true;
    }
    final lhsKey = _normalizeCompareKey(lhs);
    final rhsKey = _normalizeCompareKey(rhs);
    if (lhsKey.isEmpty || rhsKey.isEmpty) {
      return false;
    }
    if (rhsKey == lhsKey) {
      return rhs.length >= lhs.length;
    }
    return rhsKey.startsWith(lhsKey) || rhsKey.contains(lhsKey);
  }

  bool _shouldPreferLeftInMerge(String lhs, String rhs) {
    if (lhs.startsWith(rhs) || lhs.contains(rhs)) {
      return true;
    }
    final lhsKey = _normalizeCompareKey(lhs);
    final rhsKey = _normalizeCompareKey(rhs);
    if (lhsKey.isEmpty || rhsKey.isEmpty) {
      return false;
    }
    if (lhsKey == rhsKey) {
      return lhs.length > rhs.length;
    }
    return lhsKey.startsWith(rhsKey) || lhsKey.contains(rhsKey);
  }

  String _normalizeCompareKey(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (ConversationBubbleRenderPipeline._isIgnorableRune(rune)) {
        continue;
      }
      buffer.write(String.fromCharCode(rune).toLowerCase());
    }
    return buffer.toString();
  }

  double _normalizedSimilarity(String lhs, String rhs) {
    final lhsKey = _normalizeCompareKey(lhs);
    final rhsKey = _normalizeCompareKey(rhs);
    if (lhsKey.isEmpty || rhsKey.isEmpty) {
      return 0;
    }
    final common = _longestCommonSubstringLength(lhsKey, rhsKey);
    final denominator = lhsKey.length > rhsKey.length
        ? lhsKey.length
        : rhsKey.length;
    if (denominator == 0) {
      return 0;
    }
    return common / denominator;
  }

  int _longestCommonSubstringLength(String lhs, String rhs) {
    final a = lhs.codeUnits;
    final b = rhs.codeUnits;
    if (a.isEmpty || b.isEmpty) {
      return 0;
    }
    final dp = List.generate(
      a.length + 1,
      (_) => List<int>.filled(b.length + 1, 0),
      growable: false,
    );
    var best = 0;
    for (var i = 1; i <= a.length; i += 1) {
      for (var j = 1; j <= b.length; j += 1) {
        if (a[i - 1] != b[j - 1]) {
          dp[i][j] = 0;
          continue;
        }
        dp[i][j] = dp[i - 1][j - 1] + 1;
        if (dp[i][j] > best) {
          best = dp[i][j];
        }
      }
    }
    return best;
  }

  String _maxSessionId(String lhs, String rhs) {
    final leftInt = int.tryParse(lhs);
    final rightInt = int.tryParse(rhs);
    if (leftInt != null && rightInt != null) {
      return rightInt >= leftInt ? rhs : lhs;
    }
    return rhs.isNotEmpty ? rhs : lhs;
  }
}

class _BubbleAggregate {
  _BubbleAggregate({
    required this.sourceLangCode,
    required this.targetLangCode,
  });

  String sourceLangCode;
  String targetLangCode;
  final List<String> sourceSessionOrder = [];
  final List<String> translatedSessionOrder = [];
  final Map<String, _SessionSegment> sourceBySession = {};
  final Map<String, _SessionSegment> translatedBySession = {};
  final Map<String, String> sourceSessionAlias = {};
  final Map<String, String> translatedSessionAlias = {};
  String latestSessionId = '';
}

class _SessionSegment {
  _SessionSegment({required this.text, required this.isFinal});

  final String text;
  final bool isFinal;
}
