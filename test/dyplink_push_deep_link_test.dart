// Tests for the destination URL that DyplinkPush.reportNotificationClicked
// hands back when a campaign push carries a deep link.
//
// Scope:
//   * deep_link_url / link key precedence, matching the Android SDK
//   * values that must count as "no deep link" (absent, blank, non-String)
//   * the URL survives a failing analytics call — extraction and reporting
//     are independent
//   * reporting a click never opens the deep-link stream as a side effect
//
// NOT in scope:
//   * Delivery on Dyplink.deepLinks. The stream's controller is created by
//     the `deepLinks` getter, which is Android-gated and so throws under
//     `flutter test` (host OS). Emission is covered instead by asserting the
//     complementary guarantee below: reporting never touches that getter.
//   * The engagement POST itself — see dyplink_push_events_test.dart.

import 'package:dyplink/dyplink.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Future<void> Function(String, String, Map<String, Object?>)
      originalPostEvent;
  late String? Function() originalPlatformName;
  late Future<String> Function() originalDeviceFingerprintProvider;
  late List<Map<String, Object?>> sent;

  setUp(() {
    originalPostEvent = DyplinkPush.instance.postEvent;
    originalPlatformName = DyplinkPush.instance.platformName;
    originalDeviceFingerprintProvider =
        DyplinkPush.instance.deviceFingerprintProvider;

    sent = <Map<String, Object?>>[];

    Dyplink.instance.currentConfig = DyplinkConfig.builder(
      baseUrl: 'https://api.dyplink.test',
      apiKey: 'test-api-key',
      projectId: 'project-1',
    ).build();
    DyplinkPush.instance.platformName = () => 'android';
    DyplinkPush.instance.deviceFingerprintProvider =
        () async => 'device-fingerprint-1';
    DyplinkPush.instance.postEvent = (baseUrl, apiKey, body) async {
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

  group('reportNotificationClicked deep link', () {
    test('returns the deep_link_url and still reports the click', () async {
      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'deep_link_url': 'https://app.test/products/42',
      });

      expect(url, 'https://app.test/products/42');
      expect(sent, hasLength(1));
      expect(sent.single['type'], 'click');
      expect(sent.single['campaignId'], 'camp-1');
    });

    test('falls back to link when deep_link_url is absent', () async {
      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'link': 'https://app.test/fallback',
      });

      expect(url, 'https://app.test/fallback');
    });

    test('prefers deep_link_url over link when both are present', () async {
      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'deep_link_url': 'https://app.test/preferred',
        'link': 'https://app.test/fallback',
      });

      expect(url, 'https://app.test/preferred');
    });

    test('returns null when the campaign carries no deep link', () async {
      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'title': 'Hello',
      });

      expect(url, isNull);
      expect(sent, hasLength(1));
    });

    test('treats an empty deep_link_url as absent', () async {
      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'deep_link_url': '',
      });

      expect(url, isNull);
    });

    test('treats a non-String deep_link_url as absent', () async {
      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'deep_link_url': 42,
      });

      expect(url, isNull);
    });

    test('falls through to link when deep_link_url is unusable', () async {
      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'deep_link_url': '',
        'link': 'https://app.test/fallback',
      });

      expect(url, 'https://app.test/fallback');
    });

    test('returns null and reports nothing for a non-campaign payload',
        () async {
      final url = await DyplinkPush.instance.reportNotificationClicked({
        'deep_link_url': 'https://app.test/products/42',
      });

      expect(url, isNull);
      expect(sent, isEmpty);
    });

    test('returns null and reports nothing when the campaign id is blank',
        () async {
      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': '',
        'deep_link_url': 'https://app.test/products/42',
      });

      expect(url, isNull);
      expect(sent, isEmpty);
    });

    test('still returns the URL when the analytics call throws', () async {
      DyplinkPush.instance.postEvent = (baseUrl, apiKey, body) async {
        throw Exception('network is down');
      };

      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'deep_link_url': 'https://app.test/products/42',
      });

      expect(url, 'https://app.test/products/42');
    });

    test('still returns the URL when the device fingerprint is unavailable',
        () async {
      DyplinkPush.instance.deviceFingerprintProvider =
          () async => throw Exception('not initialized');

      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'deep_link_url': 'https://app.test/products/42',
      });

      expect(url, 'https://app.test/products/42');
      expect(sent, isEmpty);
    });

    test('still returns the URL when Dyplink.init has not been called',
        () async {
      Dyplink.instance.currentConfig = null;

      final url = await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'deep_link_url': 'https://app.test/products/42',
      });

      expect(url, 'https://app.test/products/42');
      expect(sent, isEmpty);
    });

    test('does not open the deep-link stream as a side effect', () async {
      // Reaching for Dyplink.deepLinks here would both attach the native
      // listener at a surprising moment and throw on this (non-Android) host,
      // so completing normally with no controller is the assertion.
      await DyplinkPush.instance.reportNotificationClicked({
        'dyplink_campaign_id': 'camp-1',
        'deep_link_url': 'https://app.test/products/42',
      });

      expect(
        Dyplink.instance.emitDeepLink(
          const DeepLinkResult(url: 'https://app.test/x', isDeferred: false),
        ),
        isFalse,
      );
    });
  });
}
