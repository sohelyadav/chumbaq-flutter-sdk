// Bridge-only tests for the Chumbaq Flutter plugin.
//
// Scope:
//   * Dart facade correctly forwards calls to the HostApi
//   * PlatformException -> ChumbaqError rewrapping
//   * ChumbaqConfigBuilder validation
//
// NOT in scope:
//   * Business logic (queue, retry, identity, session) — tested in the
//     native Android SDK's own test suite
//   * Round-trip serialization — exercised implicitly by facade tests

import 'package:chumbaq/chumbaq.dart';
import 'package:chumbaq/src/chumbaq_error.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// We can't easily mock Pigeon's generated HostApi (no @GenerateMocks here
// to keep the test setup dead simple), so we reach into chumbaq_core.dart
// via its @visibleForTesting hook. For now these tests focus on pure-Dart
// code paths that don't need a bound channel.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChumbaqConfigBuilder', () {
    test('builds with only the three required fields', () {
      final config = ChumbaqConfig.builder(
        baseUrl: 'https://api.chumbaq.com',
        apiKey: 'k',
        projectId: 'p',
      ).build();

      expect(config.baseUrl, 'https://api.chumbaq.com');
      expect(config.apiKey, 'k');
      expect(config.projectId, 'p');
      expect(config.logLevel, ChumbaqLogLevel.none);
      expect(config.flushIntervalSeconds, 30);
      expect(config.maxQueueSize, 1000);
      expect(config.maxRetries, 3);
      expect(config.sessionTimeoutSeconds, 300);
      expect(config.enableAutoSessionTracking, isTrue);
      expect(config.enableAutoDeviceInfo, isTrue);
      expect(config.deepLinkHosts, isEmpty);
      expect(config.customScheme, isNull);
    });

    test('applies all optional fields', () {
      final config = ChumbaqConfig.builder(
        baseUrl: 'https://api.chumbaq.com',
        apiKey: 'k',
        projectId: 'p',
      )
          .logLevel(ChumbaqLogLevel.debug)
          .flushInterval(const Duration(seconds: 60))
          .maxQueueSize(500)
          .maxRetries(5)
          .sessionTimeout(const Duration(minutes: 10))
          .enableAutoSessionTracking(false)
          .enableAutoDeviceInfo(false)
          .deepLinkHosts(const ['a.example.com', 'b.example.com'])
          .customScheme('myapp')
          .build();

      expect(config.logLevel, ChumbaqLogLevel.debug);
      expect(config.flushIntervalSeconds, 60);
      expect(config.maxQueueSize, 500);
      expect(config.maxRetries, 5);
      expect(config.sessionTimeoutSeconds, 600);
      expect(config.enableAutoSessionTracking, isFalse);
      expect(config.enableAutoDeviceInfo, isFalse);
      expect(config.deepLinkHosts, ['a.example.com', 'b.example.com']);
      expect(config.customScheme, 'myapp');
    });

    test('rejects blank required fields', () {
      expect(
        () => ChumbaqConfig.builder(baseUrl: '', apiKey: 'k', projectId: 'p')
            .build(),
        throwsArgumentError,
      );
      expect(
        () => ChumbaqConfig.builder(
          baseUrl: 'https://api.chumbaq.com',
          apiKey: '',
          projectId: 'p',
        ).build(),
        throwsArgumentError,
      );
      expect(
        () => ChumbaqConfig.builder(
          baseUrl: 'https://api.chumbaq.com',
          apiKey: 'k',
          projectId: '',
        ).build(),
        throwsArgumentError,
      );
    });

    test('rejects non-positive flushInterval / maxQueueSize', () {
      expect(
        () => ChumbaqConfig.builder(
          baseUrl: 'https://api.chumbaq.com',
          apiKey: 'k',
          projectId: 'p',
        ).flushInterval(Duration.zero).build(),
        throwsArgumentError,
      );
      expect(
        () => ChumbaqConfig.builder(
          baseUrl: 'https://api.chumbaq.com',
          apiKey: 'k',
          projectId: 'p',
        ).maxQueueSize(0).build(),
        throwsArgumentError,
      );
    });

    test('rejects negative maxRetries', () {
      expect(
        () => ChumbaqConfig.builder(
          baseUrl: 'https://api.chumbaq.com',
          apiKey: 'k',
          projectId: 'p',
        ).maxRetries(-1).build(),
        throwsArgumentError,
      );
    });

    test('toDto produces matching Pigeon DTO', () {
      final config = ChumbaqConfig.builder(
        baseUrl: 'https://api.chumbaq.com',
        apiKey: 'k',
        projectId: 'p',
      ).logLevel(ChumbaqLogLevel.info).build();
      final dto = config.toDto();
      expect(dto.baseUrl, config.baseUrl);
      expect(dto.apiKey, config.apiKey);
      expect(dto.projectId, config.projectId);
      expect(dto.flushIntervalSeconds, 30);
    });
  });

  group('IdentifyParamsBuilder', () {
    test('fluently sets every field', () {
      final params = IdentifyParams.builder()
          .distinctId('anon-1')
          .externalUserId('user-1')
          .firstName('Jane')
          .lastName('Doe')
          .phone('+15551234567')
          .avatar('https://example.com/a.png')
          .locale('en_US')
          .language('en')
          .appVersion('1.0.0')
          .appBuild('42')
          .traits(const {'plan': 'pro', 'age': 34})
          .utmSource('google')
          .utmMedium('cpc')
          .utmCampaign('spring')
          .utmContent('banner_a')
          .utmTerm('shoes')
          .installSource('play_store')
          .installCampaign('launch')
          .emailOptIn(true)
          .smsOptIn(false)
          .pushOptIn(true)
          .gdprConsent(true)
          .doNotTrack(false)
          .build();
      final dto = params.toDto();

      expect(dto.distinctId, 'anon-1');
      expect(dto.externalUserId, 'user-1');
      expect(dto.firstName, 'Jane');
      expect(dto.lastName, 'Doe');
      expect(dto.phone, '+15551234567');
      expect(dto.traits!['plan'], 'pro');
      expect(dto.traits!['age'], 34);
      expect(dto.utmSource, 'google');
      expect(dto.emailOptIn, isTrue);
      expect(dto.smsOptIn, isFalse);
      expect(dto.pushOptIn, isTrue);
      expect(dto.gdprConsent, isTrue);
      expect(dto.doNotTrack, isFalse);
    });

    test('unset fields are null in the DTO', () {
      final dto = IdentifyParams.builder().externalUserId('only-me').build().toDto();
      expect(dto.externalUserId, 'only-me');
      expect(dto.distinctId, isNull);
      expect(dto.firstName, isNull);
      expect(dto.traits, isNull);
      expect(dto.emailOptIn, isNull);
    });
  });

  group('ChumbaqError.fromPlatformException', () {
    test('NOT_INITIALIZED code -> ChumbaqNotInitialized', () {
      final e = ChumbaqError.fromPlatformException(
        PlatformException(code: 'NOT_INITIALIZED', message: 'nope'),
      );
      expect(e, isA<ChumbaqNotInitialized>());
      expect(e.message, 'nope');
    });

    test('INVALID_CONFIG code -> ChumbaqInvalidConfig', () {
      final e = ChumbaqError.fromPlatformException(
        PlatformException(code: 'INVALID_CONFIG', message: 'bad baseUrl'),
      );
      expect(e, isA<ChumbaqInvalidConfig>());
      expect(e.message, 'bad baseUrl');
    });

    test('INVALID_ARGUMENT code -> ChumbaqInvalidConfig (same bucket)', () {
      final e = ChumbaqError.fromPlatformException(
        PlatformException(code: 'INVALID_ARGUMENT', message: 'empty'),
      );
      expect(e, isA<ChumbaqInvalidConfig>());
    });

    test('NETWORK_ERROR with status in details', () {
      final e = ChumbaqError.fromPlatformException(
        PlatformException(
          code: 'NETWORK_ERROR',
          message: 'timeout',
          details: {'statusCode': 504},
        ),
      );
      expect(e, isA<ChumbaqNetworkError>());
      final ne = e as ChumbaqNetworkError;
      expect(ne.statusCode, 504);
    });

    test('API_ERROR:404 -> ChumbaqApiError with parsed status', () {
      final e = ChumbaqError.fromPlatformException(
        PlatformException(
          code: 'API_ERROR:404',
          message: 'not found',
          details: {'responseBody': '{"error":"not_found"}'},
        ),
      );
      expect(e, isA<ChumbaqApiError>());
      final ae = e as ChumbaqApiError;
      expect(ae.statusCode, 404);
      expect(ae.responseBody, '{"error":"not_found"}');
      expect(ae.code, 'API_ERROR:404');
    });

    test('unknown code -> ChumbaqUnknownError preserves original code', () {
      final e = ChumbaqError.fromPlatformException(
        PlatformException(code: 'SOMETHING_ODD', message: 'huh'),
      );
      expect(e, isA<ChumbaqUnknownError>());
      final ue = e as ChumbaqUnknownError;
      expect(ue.originalCode, 'SOMETHING_ODD');
      expect(ue.code, 'SOMETHING_ODD');
    });
  });

  group('runCatchingChumbaq', () {
    test('passes through on success', () async {
      final result = await runCatchingChumbaq(() async => 42);
      expect(result, 42);
    });

    test('rewraps PlatformException into the right ChumbaqError subclass',
        () async {
      await expectLater(
        () => runCatchingChumbaq<void>(() async {
          throw PlatformException(
            code: 'NOT_INITIALIZED',
            message: 'init first',
          );
        }),
        throwsA(isA<ChumbaqNotInitialized>()),
      );
    });

    test('non-PlatformException exceptions pass through unchanged', () async {
      await expectLater(
        () => runCatchingChumbaq<void>(() async {
          throw StateError('not a platform exception');
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'not a platform exception',
          ),
        ),
      );
    });
  });

  group('DeepLinkResult.fromEventMap', () {
    test('decodes a full map', () {
      final result = DeepLinkResult.fromEventMap({
        'url': 'https://example.chumbaq.com/abc',
        'shortCode': 'abc',
        'params': {'utm_source': 'email'},
        'isDeferred': false,
        'linkId': 'link-1',
      });

      expect(result.url, 'https://example.chumbaq.com/abc');
      expect(result.shortCode, 'abc');
      expect(result.params!['utm_source'], 'email');
      expect(result.isDeferred, isFalse);
      expect(result.linkId, 'link-1');
    });

    test('decodes with nulls for optional fields', () {
      final result = DeepLinkResult.fromEventMap({
        'url': 'chumbaqexample://home',
        'shortCode': null,
        'params': null,
        'isDeferred': true,
        'linkId': null,
      });
      expect(result.url, 'chumbaqexample://home');
      expect(result.shortCode, isNull);
      expect(result.params, isNull);
      expect(result.isDeferred, isTrue);
      expect(result.linkId, isNull);
    });
  });

  group('TrackConversionParams.toDto', () {
    test('forwards every field', () {
      const params = TrackConversionParams(
        eventType: 'purchase',
        shortCode: 'abc',
        linkId: 'link-1',
        externalUserId: 'user-1',
        metadata: {'cart_total': 42.50, 'currency': 'USD'},
      );
      final dto = params.toDto();
      expect(dto.eventType, 'purchase');
      expect(dto.shortCode, 'abc');
      expect(dto.linkId, 'link-1');
      expect(dto.externalUserId, 'user-1');
      expect(dto.metadata!['cart_total'], 42.50);
      expect(dto.metadata!['currency'], 'USD');
    });
  });

}
