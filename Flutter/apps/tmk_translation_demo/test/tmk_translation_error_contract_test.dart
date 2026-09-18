import 'package:flutter_test/flutter_test.dart';
import 'package:tmk_translation_demo/src/tmk_translation_event_adapter.dart';
import 'package:tmk_translation_demo/src/tmk_translation_models.dart';
import 'package:tmk_translation_flutter/tmk_translation_flutter.dart' as api;

void main() {
  test('preserves the structured error contract in the Sample adapter', () {
    final error = api.TmkTranslationError.fromMap(<Object?, Object?>{
      'code': 2003005,
      'constantName': 'MESSAGE_DECODING_FAILED',
      'category': 'rtcRtm',
      'message': 'malformed message',
      'isRecoverable': true,
      'severity': 'warning',
    });

    final adapted = adaptSessionEvent(
      api.TmkSessionErrorEvent(
        sessionId: 'session-1',
        sequence: 1,
        occurredAt: DateTime.utc(2026, 1, 1),
        error: error,
      ),
    );

    expect(adapted, isA<TmkErrorEvent>());
    final errorEvent = adapted as TmkErrorEvent;
    expect(errorEvent.error, same(error));
    expect(errorEvent.error.severity, api.TmkTranslationErrorSeverity.warning);
    expect(errorEvent.error.constantName, 'MESSAGE_DECODING_FAILED');
    expect(shouldRecoverFromError(errorEvent.error), isFalse);
  });

  test('recovers only from failed and non-recoverable errors', () {
    final fatal = api.TmkTranslationError.fromMap(<Object?, Object?>{
      'code': 2003004,
      'constantName': 'RTC_OPERATION_FAILED',
      'category': 'rtcRtm',
      'message': 'channel failure',
      'isRecoverable': false,
      'severity': 'failed',
    });
    final recoverableFailure =
        api.TmkTranslationError.fromMap(<Object?, Object?>{
          'code': 2003004,
          'constantName': 'RTC_OPERATION_FAILED',
          'category': 'rtcRtm',
          'message': 'channel failure',
          'isRecoverable': true,
          'severity': 'failed',
        });
    final warning = fatal.copyWith(
      severity: api.TmkTranslationErrorSeverity.warning,
    );
    final ignored = api.TmkTranslationError.cancelled();

    expect(shouldRecoverFromError(fatal), isTrue);
    expect(shouldRecoverFromError(recoverableFailure), isFalse);
    expect(shouldRecoverFromError(warning), isFalse);
    expect(shouldRecoverFromError(ignored), isFalse);
  });

  test('preserves the structured state snapshot in the Sample adapter', () {
    final snapshot = api.TmkTranslationChannelStateSnapshot(
      state: api.TmkTranslationChannelState.failed,
      reason: api.TmkTranslationChannelStateReason.engineError,
      code: 2003004,
      message: 'channel failure',
      isRecoverable: false,
      updatedAt: DateTime.utc(2026, 1, 1),
    );

    final adapted = adaptSessionEvent(
      api.TmkSessionStateChangedEvent(
        sessionId: 'session-1',
        sequence: 2,
        occurredAt: DateTime.utc(2026, 1, 1),
        snapshot: snapshot,
      ),
    );

    expect(adapted, isA<TmkSessionStateEvent>());
    final stateEvent = adapted as TmkSessionStateEvent;
    expect(stateEvent.snapshot, same(snapshot));
    expect(stateEvent.snapshot.state, api.TmkTranslationChannelState.failed);
    expect(stateEvent.snapshot.code, 2003004);
  });
}
