import 'package:flutter/foundation.dart';

/// Opt-in reporting of failures the SDK otherwise swallows.
///
/// Almost nothing in this package is allowed to throw at its caller.
/// Engagement reporting must never cost an app a notification tap, a
/// stream's native listener must not take the stream down with it when it
/// fails to attach, and a widget cannot throw out of `build`. The result is
/// that a misconfigured integration looks exactly like a working one: calls
/// return, streams stay open, and nothing emits.
///
/// Turning this on makes those paths say so. It is off by default because
/// it is a debugging aid, not an error channel — the SDK's behaviour is
/// identical either way.
///
/// ```dart
/// // In main(), before Dyplink.init:
/// DyplinkDiagnostics.enabled = true;
/// ```
///
/// Nothing logged here carries an API key, a push token, or a device
/// fingerprint: a diagnostic that is unsafe to paste into an issue is a
/// diagnostic nobody can use. Token-shaped values are reported by length
/// only.
class DyplinkDiagnostics {
  DyplinkDiagnostics._();

  /// Whether swallowed failures are reported. Defaults to false.
  static bool enabled = false;

  /// Where reports go. Defaults to [debugPrint], which Flutter throttles and
  /// strips in release builds.
  ///
  /// Replace to route them into your own logger or a test spy:
  /// ```dart
  /// DyplinkDiagnostics.sink = (message) => myLogger.warn(message);
  /// ```
  static void Function(String message) sink = _defaultSink;

  /// Reports that [operation] failed with [error], if diagnostics are on.
  ///
  /// [operation] should name the SDK call, not the app's — the reader is
  /// looking for which part of Dyplink went quiet.
  static void reportFailure(String operation, Object error) {
    if (!enabled) return;
    sink('[Dyplink] $operation failed: $error');
  }

  /// Reports that [operation] did nothing, and why.
  ///
  /// Distinct from [reportFailure] because a skip is usually a
  /// configuration answer ("Dyplink.init has not been called") rather than
  /// a fault, and the fix is a different one.
  static void reportSkipped(String operation, String reason) {
    if (!enabled) return;
    sink('[Dyplink] $operation skipped: $reason');
  }

  /// Describes a secret by shape alone, for use in a [reportFailure] message.
  ///
  /// A token that is empty, or truncated, or carries a stray newline from a
  /// copy-paste is a real cause of registration failures, and length is
  /// enough to see all three without putting the credential in a log.
  static String redact(String secret) => '<${secret.length} chars>';

  static void _defaultSink(String message) => debugPrint(message);
}
