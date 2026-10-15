// Tests for DyplinkDiagnostics — the opt-in reporting of failures the SDK
// otherwise swallows.
//
// Scope:
//   * off by default, and silent when off
//   * the swallowed push-reporting paths report through it when on
//   * no credential reaches the sink
//
// Covered elsewhere:
//   * The stream-lifecycle paths in Dyplink.deepLinks / DyplinkMessages.events
//     and DyplinkPush.tokens — dyplink_stream_wiring_test.dart. They used to
//     be untestable here: all three sat behind a `Platform.isAndroid` gate
//     that throws UnsupportedError under `flutter test`, which runs on the
//     host OS. They now resolve through DyplinkPlatform, which a test can
//     swap. The Kotlin side of the token stream is covered by
//     android/src/test/kotlin/.../DyplinkPluginTest.kt.
//   * The skip reported by DyplinkBannerCarousel and by Dyplink.emitDeepLink
//     — dyplink_platform_gating_test.dart and dyplink_emit_deep_link_test.dart.

import 'package:dyplink/dyplink.dart';
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
    originalPostEvent = DyplinkPush.instance.postEvent;
    originalPlatformName = DyplinkPush.instance.platformName;
    originalDeviceFingerprintProvider =
        DyplinkPush.instance.deviceFingerprintProvider;
    originalSink = DyplinkDiagnostics.sink;

    logged = <String>[];
    DyplinkDiagnostics.sink = logged.add;

    DyplinkPush.instance.platformName = () => 'android';
    DyplinkPush.instance.deviceFingerprintProvider =
        () async => 'device-fingerprint-1';
    DyplinkPush.instance.postEvent = (baseUrl, apiKey, body) async {};
  });

  tearDown(() {
    DyplinkDiagnostics.enabled = false;
    DyplinkDiagnostics.sink = originalSink;
    Dyplink.instance.currentConfig = null;
    DyplinkPush.instance.postEvent = originalPostEvent;
    DyplinkPush.instance.platformName = originalPlatformName;
    DyplinkPush.instance.deviceFingerprintProvider =
        originalDeviceFingerprintProvider;
  });

  group('defaults', () {
    test('is off', () {
      // A fresh process must not log: these are debugging aids, and an SDK
      // that chatters by default trains people to ignore it.
      expect(DyplinkDiagnostics.enabled, isFalse);
    });

    test('logs nothing while off', () async {
      DyplinkPush.instance.postEvent = (baseUrl, apiKey, body) async {
        throw Exception('network is down');
      };
      Dyplink.instance.currentConfig = _config;

      await DyplinkPush.instance
          .reportNotificationReceived({'dyplink_campaign_id': 'camp-1'});

      expect(logged, isEmpty);
    });
  });

  group('swallowed push-reporting failures', () {
    setUp(() => DyplinkDiagnostics.enabled = true);

    test('a transport failure is reported', () async {
      DyplinkPush.instance.postEvent = (baseUrl, apiKey, body) async {
        throw Exception('network is down');
      };
      Dyplink.instance.currentConfig = _config;

      await DyplinkPush.instance
          .reportNotificationReceived({'dyplink_campaign_id': 'camp-1'});

      expect(logged, hasLength(1));
      expect(logged.single, contains('delivered'));
      expect(logged.single, contains('network is down'));
    });

    test('a missing Dyplink.init is reported as a skip, not a failure',
        () async {
      // The single most likely integration mistake, and the one that is
      // completely invisible otherwise.
      await DyplinkPush.instance
          .reportNotificationReceived({'dyplink_campaign_id': 'camp-1'});

      expect(logged, hasLength(1));
      expect(logged.single, contains('skipped'));
      expect(logged.single, contains('Dyplink.init'));
    });

    test('an unsupported platform is reported', () async {
      Dyplink.instance.currentConfig = _config;
      DyplinkPush.instance.platformName = () => null;

      await DyplinkPush.instance
          .reportNotificationReceived({'dyplink_campaign_id': 'camp-1'});

      expect(logged, hasLength(1));
      expect(logged.single, contains('skipped'));
    });

    test('a device-fingerprint failure is reported', () async {
      Dyplink.instance.currentConfig = _config;
      DyplinkPush.instance.deviceFingerprintProvider =
          () async => throw Exception('not initialized');

      await DyplinkPush.instance
          .reportNotificationClicked({'dyplink_campaign_id': 'camp-1'});

      expect(logged, hasLength(1));
      expect(logged.single, contains('device fingerprint'));
    });

    test('a push that is not a Dyplink campaign is not reported', () async {
      Dyplink.instance.currentConfig = _config;

      // The ordinary case for an app that also sends its own pushes, so it
      // must not fill the log.
      await DyplinkPush.instance.reportNotificationReceived({'title': 'Hi'});

      expect(logged, isEmpty);
    });
  });

  group('credentials', () {
    setUp(() => DyplinkDiagnostics.enabled = true);

    test('no API key reaches the sink', () async {
      DyplinkPush.instance.postEvent = (baseUrl, apiKey, body) async {
        throw Exception('rejected');
      };
      Dyplink.instance.currentConfig = _config;

      await DyplinkPush.instance
          .reportNotificationReceived({'dyplink_campaign_id': 'camp-1'});

      expect(logged, isNotEmpty);
      for (final line in logged) {
        expect(line, isNot(contains('super-secret-api-key')));
      }
    });

    test('redact describes a secret by length alone', () {
      expect(DyplinkDiagnostics.redact('abcd'), '<4 chars>');
      expect(DyplinkDiagnostics.redact(''), '<0 chars>');
      expect(DyplinkDiagnostics.redact('tok'), isNot(contains('tok')));
    });
  });

  group('sink', () {
    test('both report kinds honour the enabled flag', () {
      // reportSkipped has its own early return, so "off" has to be proved
      // for each kind separately rather than for the sink as a whole.
      DyplinkDiagnostics.enabled = false;
      DyplinkDiagnostics.reportFailure('Thing.doIt', 'boom');
      DyplinkDiagnostics.reportSkipped('Thing.other', 'no reason');
      expect(logged, isEmpty);

      DyplinkDiagnostics.enabled = true;
      DyplinkDiagnostics.reportFailure('Thing.doIt', 'boom');
      DyplinkDiagnostics.reportSkipped('Thing.other', 'no reason');
      expect(logged, hasLength(2));
    });

    test('a report names the operation that went quiet', () {
      DyplinkDiagnostics.enabled = true;

      DyplinkDiagnostics.reportFailure('Thing.doIt', 'boom');
      DyplinkDiagnostics.reportSkipped('Thing.other', 'no reason');

      expect(logged, hasLength(2));
      expect(logged.first, contains('Thing.doIt'));
      expect(logged.first, contains('boom'));
      expect(logged.last, contains('Thing.other'));
      expect(logged.last, contains('no reason'));
    });
  });
}

DyplinkConfig get _config => DyplinkConfig.builder(
      baseUrl: 'https://api.dyplink.test',
      apiKey: 'super-secret-api-key',
      projectId: 'project-1',
    ).build();
