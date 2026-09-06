// Tests for DyplinkPush push-engagement reporting
// (reportNotificationReceived / reportNotificationClicked).
//
// Scope:
//   * dyplink_campaign_id gating — present reports, absent/blank does not
//   * shape of the payload handed to the network transport
//   * a transport (network) failure never throws
//
// NOT in scope:
//   * The real HTTP transport (_defaultPostEvent) — swapped out via
//     DyplinkPush.instance.postEvent, the same "visible for testing" seam
//     used for hostApi elsewhere in this package.
//   * Core Dyplink's native deviceFingerprint plumbing — swapped out via
//     DyplinkPush.instance.deviceFingerprintProvider for the same reason.

import 'package:dyplink/dyplink.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Future<void> Function(String, String, Map<String, Object?>)
      originalPostEvent;
  late String? Function() originalPlatformName;
  late Future<String> Function() originalDeviceFingerprintProvider;
  late List<Map<String, Object?>> sent;
  late List<({String baseUrl, String apiKey})> sentTargets;

  setUp(() {
    originalPostEvent = DyplinkPush.instance.postEvent;
    originalPlatformName = DyplinkPush.instance.platformName;
    originalDeviceFingerprintProvider =
        DyplinkPush.instance.deviceFingerprintProvider;

    sent = <Map<String, Object?>>[];
    sentTargets = <({String baseUrl, String apiKey})>[];

    Dyplink.instance.currentConfig = DyplinkConfig.builder(
      baseUrl: 'https://api.dyplink.test',
      apiKey: 'test-api-key',
      projectId: 'project-1',
    ).build();
    DyplinkPush.instance.platformName = () => 'android';
    DyplinkPush.instance.deviceFingerprintProvider =
        () async => 'device-fingerprint-1';
    DyplinkPush.instance.postEvent = (baseUrl, apiKey, body) async {
      sentTargets.add((baseUrl: baseUrl, apiKey: apiKey));
      sent.add(body);
    };
  });

  tearDown(() {
    Dyplink.instance.currentConfig = null;
    DyplinkPush.instance.postEvent = originalPostEvent;
    DyplinkPush.instance.platformName = originalPlatformName;
    DyplinkPush.instance.deviceFingerprintProvider =
        originalDeviceFingerprintProvider;
  });

  group('reportNotificationReceived', () {
    test('reports "delivered" when data carries dyplink_campaign_id',
        () async {
      await DyplinkPush.instance.reportNotificationReceived({
        'dyplink_campaign_id': 'camp-1',
        'title': 'Hello',
      });

      expect(sent, hasLength(1));
      final body = sent.single;
      expect(body['projectId'], 'project-1');
      expect(body['campaignId'], 'camp-1');
      expect(body['deviceFingerprint'], 'device-fingerprint-1');
      expect(body['type'], 'delivered');
      expect(body['platform'], 'android');
      expect(body['occurredAt'], isA<String>());
      expect(sentTargets.single.baseUrl, 'https://api.dyplink.test');
      expect(sentTargets.single.apiKey, 'test-api-key');
    });

    test('does nothing when dyplink_campaign_id is absent', () async {
      await DyplinkPush.instance.reportNotificationReceived({
        'title': 'Not a Dyplink campaign push',
      });

      expect(sent, isEmpty);
    });

    test('does nothing when dyplink_campaign_id is blank', () async {
      await DyplinkPush.instance
          .reportNotificationReceived({'dyplink_campaign_id': ''});

      expect(sent, isEmpty);
    });

    test('does nothing when Dyplink.init has not been called', () async {
      Dyplink.instance.currentConfig = null;

      await DyplinkPush.instance
          .reportNotificationReceived({'dyplink_campaign_id': 'camp-1'});

      expect(sent, isEmpty);
    });

    test('does nothing on an unsupported platform', () async {
      DyplinkPush.instance.platformName = () => null;

      await DyplinkPush.instance
          .reportNotificationReceived({'dyplink_campaign_id': 'camp-1'});

      expect(sent, isEmpty);
    });
  });

  group('reportNotificationClicked', () {
    test('reports "click" when data carries dyplink_campaign_id', () async {
      await DyplinkPush.instance
          .reportNotificationClicked({'dyplink_campaign_id': 'camp-2'});

      expect(sent, hasLength(1));
      expect(sent.single['type'], 'click');
      expect(sent.single['campaignId'], 'camp-2');
    });

    test('does nothing when dyplink_campaign_id is absent', () async {
      await DyplinkPush.instance.reportNotificationClicked({'foo': 'bar'});

      expect(sent, isEmpty);
    });
  });

  group('failure handling', () {
    test('a network failure from postEvent does not throw', () async {
      DyplinkPush.instance.postEvent = (baseUrl, apiKey, body) async {
        throw Exception('network is down');
      };

      await expectLater(
        DyplinkPush.instance
            .reportNotificationReceived({'dyplink_campaign_id': 'camp-1'}),
        completes,
      );
    });

    test('a deviceFingerprint failure does not throw and reports nothing',
        () async {
      DyplinkPush.instance.deviceFingerprintProvider =
          () async => throw Exception('not initialized');

      await expectLater(
        DyplinkPush.instance
            .reportNotificationReceived({'dyplink_campaign_id': 'camp-1'}),
        completes,
      );
      expect(sent, isEmpty);
    });
  });
}
