import 'package:flutter/services.dart';

/// Sealed hierarchy of errors that the Chumbaq SDK may surface.
///
/// Every method that can fail returns a [Future] which completes with a
/// subclass of [ChumbaqError]. Callers can pattern-match on the subclass
/// to react to specific failure modes.
///
/// Internally, these are built from [PlatformException]s raised by the
/// native Android SDK and carry the same [PlatformException.code] values
/// that the Kotlin plugin emits (see `ChumbaqPlugin.toFlutterError`).
sealed class ChumbaqError implements Exception {
  const ChumbaqError(this.message);

  /// Human-readable description of the failure.
  final String message;

  /// The PlatformException code that triggered this error, if any.
  String get code;

  @override
  String toString() => '$runtimeType($code): $message';

  /// Converts a [PlatformException] from the native layer into the
  /// appropriate typed [ChumbaqError] subclass.
  static ChumbaqError fromPlatformException(PlatformException e) {
    final msg = e.message ?? e.code;
    final code = e.code;
    if (code == 'NOT_INITIALIZED') {
      return ChumbaqNotInitialized(msg);
    }
    if (code == 'INVALID_CONFIG' || code == 'INVALID_ARGUMENT') {
      return ChumbaqInvalidConfig(msg);
    }
    if (code == 'NETWORK_ERROR') {
      final details = e.details;
      final statusCode = details is Map ? details['statusCode'] as int? : null;
      return ChumbaqNetworkError(msg, statusCode: statusCode);
    }
    if (code.startsWith('API_ERROR:')) {
      final statusStr = code.substring('API_ERROR:'.length);
      final status = int.tryParse(statusStr) ?? 0;
      final details = e.details;
      final body = details is Map ? details['responseBody'] as String? : null;
      return ChumbaqApiError(msg, statusCode: status, responseBody: body);
    }
    return ChumbaqUnknownError(msg, originalCode: code);
  }
}

/// Thrown when an SDK method is called before [Chumbaq.init].
class ChumbaqNotInitialized extends ChumbaqError {
  const ChumbaqNotInitialized([super.message = 'Chumbaq SDK not initialized']);

  @override
  String get code => 'NOT_INITIALIZED';
}

/// Thrown when SDK configuration is invalid (blank baseUrl, etc.).
class ChumbaqInvalidConfig extends ChumbaqError {
  const ChumbaqInvalidConfig(super.message);

  @override
  String get code => 'INVALID_CONFIG';
}

/// Thrown on transport-level network failures (no response from server).
class ChumbaqNetworkError extends ChumbaqError {
  const ChumbaqNetworkError(super.message, {this.statusCode});

  /// HTTP status code, if the failure happened after headers were received.
  final int? statusCode;

  @override
  String get code => 'NETWORK_ERROR';
}

/// Thrown on non-2xx HTTP responses from the Chumbaq backend.
class ChumbaqApiError extends ChumbaqError {
  const ChumbaqApiError(
    super.message, {
    required this.statusCode,
    this.responseBody,
  });

  final int statusCode;
  final String? responseBody;

  @override
  String get code => 'API_ERROR:$statusCode';
}

/// Any error that doesn't match a known category.
class ChumbaqUnknownError extends ChumbaqError {
  const ChumbaqUnknownError(super.message, {required this.originalCode});

  final String originalCode;

  @override
  String get code => originalCode;
}

/// Utility: run [block] and rethrow [PlatformException]s as [ChumbaqError].
Future<T> runCatchingChumbaq<T>(Future<T> Function() block) async {
  try {
    return await block();
  } on PlatformException catch (e) {
    throw ChumbaqError.fromPlatformException(e);
  }
}
