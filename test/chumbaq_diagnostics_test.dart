// Tests for ChumbaqDiagnostics — the opt-in reporting of failures the SDK
// otherwise swallows.
//
// Scope:
//   * off by default, and silent when off
//   * the swallowed push-reporting paths report through it when on
//   * no credential reaches the sink
//
// Covered elsewhere:
//   * The stream-lifecycle paths in Chumbaq.deepLinks / ChumbaqMessages.events
//     and ChumbaqPush.tokens — chumbaq_stream_wiring_test.dart. They used to
//     be untestable here: all three sat behind a `Platform.isAndroid` gate
//     that throws UnsupportedError under `flutter test`, which runs on the
//     host OS. They now resolve through ChumbaqPlatform, which a test can
//     swap. The Kotlin side of the token stream is covered by
//     android/src/test/kotlin/.../ChumbaqPluginTest.kt.
//   * The skip reported by ChumbaqBannerCarousel and by Chumbaq.emitDeepLink
//     — chumbaq_platform_gating_test.dart and chumbaq_emit_deep_link_test.dart.

import 'package:chumbaq/chumbaq.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Future<void> Function(String, String, Map<String, Object?>)
      originalPostEvent;
  late String? Function() originalPlatformName;
  late Future<String> Function() originalDeviceFingerprintProvider;
  late void Function(String) originalSink;
  late List<String> logged;

  setUp(() {
    originalPostEvent = ChumbaqPush.instance.postEvent;
    originalPlatformName = ChumbaqPush.instance.platformName;
    originalDeviceFingerprintProvider =
        ChumbaqPush.instance.deviceFingerprintProvider;
    originalSink = ChumbaqDiagnostics.sink;

    logged = <String>[];
    ChumbaqDiagnostics.sink = logged.add;

    ChumbaqPush.instance.platformName = () => 'android';
    ChumbaqPush.instance.deviceFingerprintProvider =
        () async => 'device-fingerprint-1';
    ChumbaqPush.instance.postEvent = (baseUrl, apiKey, body) async {};
  });

  tearDown(() {
    ChumbaqDiagnostics.enabled = false;
    ChumbaqDiagnostics.sink = originalSink;
    Chumbaq.instance.currentConfig = null;
    ChumbaqPush.instance.postEvent = originalPostEvent;
    ChumbaqPush.instance.platformName = originalPlatformName;
    ChumbaqPush.instance.deviceFingerprintProvider =
        originalDeviceFingerprintProvider;
  });

  group('defaults', () {
    test('is off', () {
      // A fresh process must not log: these are debugging aids, and an SDK
      // that chatters by default trains people to ignore it.
      expect(ChumbaqDiagnostics.enabled, isFalse);
    });

    test('logs nothing while off', () async {
      ChumbaqPush.instance.postEvent = (baseUrl, apiKey, body) async {
        throw Exception('network is down');
      };
      Chumbaq.instance.currentConfig = _config;

      await ChumbaqPush.instance
          .reportNotificationReceived({'chumbaq_campaign_id': 'camp-1'});

      expect(logged, isEmpty);
    });
  });

  group('swallowed push-reporting failures', () {
    setUp(() => ChumbaqDiagnostics.enabled = true);

    test('a transport failure is reported', () async {
      ChumbaqPush.instance.postEvent = (baseUrl, apiKey, body) async {
        throw Exception('network is down');
      };
      Chumbaq.instance.currentConfig = _config;

      await ChumbaqPush.instance
          .reportNotificationReceived({'chumbaq_campaign_id': 'camp-1'});

      expect(logged, hasLength(1));
      expect(logged.single, contains('delivered'));
      expect(logged.single, contains('network is down'));
    });

    test('a missing Chumbaq.init is reported as a skip, not a failure',
        () async {
      // The single most likely integration mistake, and the one that is
      // completely invisible otherwise.
      await ChumbaqPush.instance
          .reportNotificationReceived({'chumbaq_campaign_id': 'camp-1'});

      expect(logged, hasLength(1));
      expect(logged.single, contains('skipped'));
      expect(logged.single, contains('Chumbaq.init'));
    });

    test('an unsupported platform is reported', () async {
      Chumbaq.instance.currentConfig = _config;
      ChumbaqPush.instance.platformName = () => null;

      await ChumbaqPush.instance
          .reportNotificationReceived({'chumbaq_campaign_id': 'camp-1'});

      expect(logged, hasLength(1));
      expect(logged.single, contains('skipped'));
    });

    test('a device-fingerprint failure is reported', () async {
      Chumbaq.instance.currentConfig = _config;
      ChumbaqPush.instance.deviceFingerprintProvider =
          () async => throw Exception('not initialized');

      await ChumbaqPush.instance
          .reportNotificationClicked({'chumbaq_campaign_id': 'camp-1'});

      expect(logged, hasLength(1));
      expect(logged.single, contains('device fingerprint'));
    });

    test('a push that is not a Chumbaq campaign is not reported', () async {
      Chumbaq.instance.currentConfig = _config;

      // The ordinary case for an app that also sends its own pushes, so it
      // must not fill the log.
      await ChumbaqPush.instance.reportNotificationReceived({'title': 'Hi'});

      expect(logged, isEmpty);
    });
  });

  group('credentials', () {
    setUp(() => ChumbaqDiagnostics.enabled = true);

    test('no API key reaches the sink', () async {
      ChumbaqPush.instance.postEvent = (baseUrl, apiKey, body) async {
        throw Exception('rejected');
      };
      Chumbaq.instance.currentConfig = _config;

      await ChumbaqPush.instance
          .reportNotificationReceived({'chumbaq_campaign_id': 'camp-1'});

      expect(logged, isNotEmpty);
      for (final line in logged) {
        expect(line, isNot(contains('super-secret-api-key')));
      }
    });

    test('redact describes a secret by length alone', () {
      expect(ChumbaqDiagnostics.redact('abcd'), '<4 chars>');
      expect(ChumbaqDiagnostics.redact(''), '<0 chars>');
      expect(ChumbaqDiagnostics.redact('tok'), isNot(contains('tok')));
    });
  });

  group('sink', () {
    test('both report kinds honour the enabled flag', () {
      // reportSkipped has its own early return, so "off" has to be proved
      // for each kind separately rather than for the sink as a whole.
      ChumbaqDiagnostics.enabled = false;
      ChumbaqDiagnostics.reportFailure('Thing.doIt', 'boom');
      ChumbaqDiagnostics.reportSkipped('Thing.other', 'no reason');
      expect(logged, isEmpty);

      ChumbaqDiagnostics.enabled = true;
      ChumbaqDiagnostics.reportFailure('Thing.doIt', 'boom');
      ChumbaqDiagnostics.reportSkipped('Thing.other', 'no reason');
      expect(logged, hasLength(2));
    });

    test('a report names the operation that went quiet', () {
      ChumbaqDiagnostics.enabled = true;

      ChumbaqDiagnostics.reportFailure('Thing.doIt', 'boom');
      ChumbaqDiagnostics.reportSkipped('Thing.other', 'no reason');

      expect(logged, hasLength(2));
      expect(logged.first, contains('Thing.doIt'));
      expect(logged.first, contains('boom'));
      expect(logged.last, contains('Thing.other'));
      expect(logged.last, contains('no reason'));
    });
  });
}

ChumbaqConfig get _config => ChumbaqConfig.builder(
      baseUrl: 'https://api.chumbaq.test',
      apiKey: 'super-secret-api-key',
      projectId: 'project-1',
    ).build();
