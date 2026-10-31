// Tests for ChumbaqPush push-engagement reporting
// (reportNotificationReceived / reportNotificationClicked).
//
// Scope:
//   * chumbaq_campaign_id gating — present reports, absent/blank does not
//   * every event type the backend accepts, and only those
//   * metadata, including the actionId that attributes an action-button tap
//   * shape of the payload handed to the network transport
//   * a transport (network) failure never throws
//
// NOT in scope:
//   * The real HTTP transport (_defaultPostEvent) — swapped out via
//     ChumbaqPush.instance.postEvent, the same "visible for testing" seam
//     used for hostApi elsewhere in this package.
//   * Core Chumbaq's native deviceFingerprint plumbing — swapped out via
//     ChumbaqPush.instance.deviceFingerprintProvider for the same reason.

import 'package:chumbaq/chumbaq.dart';
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
    originalPostEvent = ChumbaqPush.instance.postEvent;
    originalPlatformName = ChumbaqPush.instance.platformName;
    originalDeviceFingerprintProvider =
        ChumbaqPush.instance.deviceFingerprintProvider;

    sent = <Map<String, Object?>>[];
    sentTargets = <({String baseUrl, String apiKey})>[];

    Chumbaq.instance.currentConfig = ChumbaqConfig.builder(
      baseUrl: 'https://api.chumbaq.test',
      apiKey: 'test-api-key',
      projectId: 'project-1',
    ).build();
    ChumbaqPush.instance.platformName = () => 'android';
    ChumbaqPush.instance.deviceFingerprintProvider =
        () async => 'device-fingerprint-1';
    ChumbaqPush.instance.postEvent = (baseUrl, apiKey, body) async {
      sentTargets.add((baseUrl: baseUrl, apiKey: apiKey));
      sent.add(body);
    };
  });

  tearDown(() {
    Chumbaq.instance.currentConfig = null;
    ChumbaqPush.instance.postEvent = originalPostEvent;
    ChumbaqPush.instance.platformName = originalPlatformName;
    ChumbaqPush.instance.deviceFingerprintProvider =
        originalDeviceFingerprintProvider;
  });

  group('reportNotificationReceived', () {
    test('reports "delivered" when data carries chumbaq_campaign_id',
        () async {
      await ChumbaqPush.instance.reportNotificationReceived({
        'chumbaq_campaign_id': 'camp-1',
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
      expect(sentTargets.single.baseUrl, 'https://api.chumbaq.test');
      expect(sentTargets.single.apiKey, 'test-api-key');
    });

    test('does nothing when chumbaq_campaign_id is absent', () async {
      await ChumbaqPush.instance.reportNotificationReceived({
        'title': 'Not a Chumbaq campaign push',
      });

      expect(sent, isEmpty);
    });

    test('does nothing when chumbaq_campaign_id is blank', () async {
      await ChumbaqPush.instance
          .reportNotificationReceived({'chumbaq_campaign_id': ''});

      expect(sent, isEmpty);
    });

    test('does nothing when Chumbaq.init has not been called', () async {
      Chumbaq.instance.currentConfig = null;

      await ChumbaqPush.instance
          .reportNotificationReceived({'chumbaq_campaign_id': 'camp-1'});

      expect(sent, isEmpty);
    });

    test('does nothing on an unsupported platform', () async {
      ChumbaqPush.instance.platformName = () => null;

      await ChumbaqPush.instance
          .reportNotificationReceived({'chumbaq_campaign_id': 'camp-1'});

      expect(sent, isEmpty);
    });
  });

  group('reportNotificationClicked', () {
    test('reports "click" when data carries chumbaq_campaign_id', () async {
      await ChumbaqPush.instance
          .reportNotificationClicked({'chumbaq_campaign_id': 'camp-2'});

      expect(sent, hasLength(1));
      expect(sent.single['type'], 'click');
      expect(sent.single['campaignId'], 'camp-2');
    });

    test('does nothing when chumbaq_campaign_id is absent', () async {
      await ChumbaqPush.instance.reportNotificationClicked({'foo': 'bar'});

      expect(sent, isEmpty);
    });
  });

  group('reportNotificationImpression', () {
    test('reports "impression"', () async {
      await ChumbaqPush.instance
          .reportNotificationImpression({'chumbaq_campaign_id': 'camp-3'});

      expect(sent.single['type'], 'impression');
      expect(sent.single['campaignId'], 'camp-3');
    });

    test('does nothing when chumbaq_campaign_id is absent', () async {
      await ChumbaqPush.instance.reportNotificationImpression({'foo': 'bar'});

      expect(sent, isEmpty);
    });
  });

  group('reportNotificationDismissed', () {
    test('reports "dismissed"', () async {
      await ChumbaqPush.instance
          .reportNotificationDismissed({'chumbaq_campaign_id': 'camp-4'});

      expect(sent.single['type'], 'dismissed');
      expect(sent.single['campaignId'], 'camp-4');
    });

    test('does nothing when chumbaq_campaign_id is absent', () async {
      await ChumbaqPush.instance.reportNotificationDismissed({'foo': 'bar'});

      expect(sent, isEmpty);
    });
  });

  group('event types', () {
    test('every reported type is one the backend accepts', () async {
      // CLIENT_REPORTABLE_EVENT_TYPES in the API's
      // push-notification-event.entity.ts. `sent` is excluded there on
      // purpose — it is server-written and feeds frequency capping — so a
      // client must never report it.
      const accepted = {'delivered', 'impression', 'click', 'dismissed'};

      await ChumbaqPush.instance
          .reportNotificationReceived({'chumbaq_campaign_id': 'c'});
      await ChumbaqPush.instance
          .reportNotificationImpression({'chumbaq_campaign_id': 'c'});
      await ChumbaqPush.instance
          .reportNotificationClicked({'chumbaq_campaign_id': 'c'});
      await ChumbaqPush.instance
          .reportNotificationDismissed({'chumbaq_campaign_id': 'c'});

      final reported = sent.map((body) => body['type']).toSet();
      expect(reported, accepted);
    });
  });

  group('metadata', () {
    test('is forwarded when given', () async {
      await ChumbaqPush.instance.reportNotificationReceived(
        {'chumbaq_campaign_id': 'camp-1'},
        metadata: {'variant': 'b'},
      );

      expect(sent.single['metadata'], {'variant': 'b'});
    });

    test('is omitted entirely when absent', () async {
      await ChumbaqPush.instance
          .reportNotificationReceived({'chumbaq_campaign_id': 'camp-1'});

      // Not sent as null: the backend validates metadata as an object when
      // the key is present and rejects the whole event otherwise.
      expect(sent.single.containsKey('metadata'), isFalse);
    });

    test('is omitted when given empty', () async {
      await ChumbaqPush.instance.reportNotificationReceived(
        {'chumbaq_campaign_id': 'camp-1'},
        metadata: const {},
      );

      expect(sent.single.containsKey('metadata'), isFalse);
    });
  });

  group('action button attribution', () {
    test('actionId is reported as metadata.actionId', () async {
      await ChumbaqPush.instance.reportNotificationClicked(
        {'chumbaq_campaign_id': 'camp-5'},
        actionId: 'buy-now',
      );

      // The key the Android SDK's PushEventReporter uses, so both platforms
      // land in the same column of a campaign's report.
      expect(sent.single['metadata'], {'actionId': 'buy-now'});
      expect(sent.single['type'], 'click');
    });

    test('actionId rides alongside caller metadata', () async {
      await ChumbaqPush.instance.reportNotificationClicked(
        {'chumbaq_campaign_id': 'camp-5'},
        actionId: 'buy-now',
        metadata: {'variant': 'b'},
      );

      expect(sent.single['metadata'], {'variant': 'b', 'actionId': 'buy-now'});
    });

    test('actionId wins over an actionId in caller metadata', () async {
      await ChumbaqPush.instance.reportNotificationClicked(
        {'chumbaq_campaign_id': 'camp-5'},
        actionId: 'buy-now',
        metadata: {'actionId': 'stale'},
      );

      expect(sent.single['metadata'], {'actionId': 'buy-now'});
    });

    test('a body tap reports no actionId', () async {
      await ChumbaqPush.instance
          .reportNotificationClicked({'chumbaq_campaign_id': 'camp-5'});

      expect(sent.single.containsKey('metadata'), isFalse);
    });

    test("returns the pressed action's own deep link", () async {
      final url = await ChumbaqPush.instance.reportNotificationClicked(
        {
          'chumbaq_campaign_id': 'camp-5',
          'deep_link_url': 'myapp://campaign',
          'chumbaq_actions': '[{"id":"buy-now","title":"Buy now",'
              '"deepLinkUrl":"myapp://checkout"}]',
        },
        actionId: 'buy-now',
      );

      expect(url, 'myapp://checkout');
    });

    test("falls back to the campaign's deep link when the action has none",
        () async {
      final url = await ChumbaqPush.instance.reportNotificationClicked(
        {
          'chumbaq_campaign_id': 'camp-5',
          'deep_link_url': 'myapp://campaign',
          'chumbaq_actions': '[{"id":"later","title":"Remind me"}]',
        },
        actionId: 'later',
      );

      expect(url, 'myapp://campaign');
    });

    test("falls back to the campaign's deep link for an unknown actionId",
        () async {
      final url = await ChumbaqPush.instance.reportNotificationClicked(
        {
          'chumbaq_campaign_id': 'camp-5',
          'deep_link_url': 'myapp://campaign',
          'chumbaq_actions': '[{"id":"buy-now","title":"Buy now",'
              '"deepLinkUrl":"myapp://checkout"}]',
        },
        actionId: 'no-such-button',
      );

      expect(url, 'myapp://campaign');
      // Still attributed: the campaign's report should record which button
      // the device claimed, even one this payload does not describe.
      expect(sent.single['metadata'], {'actionId': 'no-such-button'});
    });
  });

  group('failure handling', () {
    test('a network failure from postEvent does not throw', () async {
      ChumbaqPush.instance.postEvent = (baseUrl, apiKey, body) async {
        throw Exception('network is down');
      };

      await expectLater(
        ChumbaqPush.instance
            .reportNotificationReceived({'chumbaq_campaign_id': 'camp-1'}),
        completes,
      );
    });

    test('a deviceFingerprint failure does not throw and reports nothing',
        () async {
      ChumbaqPush.instance.deviceFingerprintProvider =
          () async => throw Exception('not initialized');

      await expectLater(
        ChumbaqPush.instance
            .reportNotificationReceived({'chumbaq_campaign_id': 'camp-1'}),
        completes,
      );
      expect(sent, isEmpty);
    });
  });
}
