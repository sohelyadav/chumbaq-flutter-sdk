// Integration tests for the native bridge, on the device.
//
// These complement plugin_integration_test.dart by pinning down what the
// bridge does *before* the SDK is initialized, and which members are still
// platform-specific. Both only mean anything on a real device or simulator:
// under `flutter test` the host is neither Android nor iOS, so every one of
// these calls takes the unsupported-platform branch instead.
//
// Order matters. The uninitialized-SDK expectations have to run before
// anything initializes it — the native SDK is a process-wide singleton and
// there is no way back.

import 'dart:io' show Platform;

import 'package:dyplink/dyplink.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('before Dyplink.init', () {
    // The iOS SDK logs and no-ops when it is not initialized, where the
    // Android SDK throws. The bridge makes both report NOT_INITIALIZED, so a
    // dropped event is never mistaken for a recorded one.

    testWidgets('isInitialized answers false rather than throwing', (_) async {
      expect(await Dyplink.instance.isInitialized, isFalse);
      expect(await DyplinkPush.instance.isInitialized, isFalse);
    });

    testWidgets('track reports NOT_INITIALIZED', (_) async {
      await expectLater(
        Dyplink.instance.track('too_early'),
        throwsA(isA<DyplinkNotInitialized>()),
      );
    });

    testWidgets('trackRevenue reports NOT_INITIALIZED', (_) async {
      await expectLater(
        Dyplink.instance.trackRevenue(1.0),
        throwsA(isA<DyplinkNotInitialized>()),
      );
    });

    testWidgets('message triggers report NOT_INITIALIZED', (_) async {
      await expectLater(
        DyplinkMessages.instance.onAppOpen(),
        throwsA(isA<DyplinkNotInitialized>()),
      );
    });

    testWidgets('loadBanners reports NOT_INITIALIZED', (_) async {
      await expectLater(
        DyplinkBanners.instance.loadBanners('home-top'),
        throwsA(isA<DyplinkNotInitialized>()),
      );
    });

    testWidgets('matchDeferredDeepLink reports NOT_INITIALIZED', (_) async {
      // Not "no match": an uninitialized SDK has not looked.
      await expectLater(
        Dyplink.instance.matchDeferredDeepLink(),
        throwsA(isA<DyplinkNotInitialized>()),
      );
    });
  });

  group('after Dyplink.init', () {
    setUpAll(() async {
      final config = DyplinkConfig.builder(
        baseUrl: 'https://api.dyplink.example',
        apiKey: 'test-key',
        projectId: 'test-project',
      )
          .logLevel(DyplinkLogLevel.none)
          .deepLinkHosts(const ['links.dyplink.example'])
          .customScheme('dyplinkexample')
          .build();
      await Dyplink.instance.init(config);
    });

    testWidgets('identity accessors answer', (_) async {
      expect(await Dyplink.instance.isInitialized, isTrue);
      expect(await Dyplink.instance.distinctId, isNotEmpty);
      expect(await Dyplink.instance.deviceFingerprint, isNotEmpty);
    });

    testWidgets('fire-and-forget calls go through', (_) async {
      await Dyplink.instance.track('bridge_test', properties: const {
        'from': 'integration_test',
        'count': 1,
        'ok': true,
      });
      await Dyplink.instance.trackRevenue(9.99, currency: 'USD');
      await Dyplink.instance.trackConversion(
        TrackConversionParams(eventType: 'signup', metadata: const {'plan': 'pro'}),
      );
      // Nothing to assert beyond "did not throw": these are queued natively.
    });

    testWidgets('attribution getters answer null without a match', (_) async {
      expect(await Dyplink.instance.getAttributedShortCode(), isNull);
      expect(await Dyplink.instance.getAttributedLinkId(), isNull);
    });

    testWidgets('message triggers go through once initialized', (_) async {
      await DyplinkMessages.instance.onAppOpen();
      await DyplinkMessages.instance.onScreenView('HomeScreen');
      await DyplinkMessages.instance.onEvent('purchase');
    });

    testWidgets('the deep link stream attaches and detaches', (_) async {
      final sub = Dyplink.instance.deepLinks.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
    });

    testWidgets('the message event stream attaches and detaches', (_) async {
      final sub = DyplinkMessages.instance.events.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
    });

    testWidgets('push initializes and reports its own state', (_) async {
      await DyplinkPush.instance.init();
      expect(await DyplinkPush.instance.isInitialized, isTrue);
      // No token has been registered, and the core SDK's isInitialized must
      // not be what answers here — that was the bug the Pigeon rename fixed.
      expect(await DyplinkPush.instance.isRegistered, isFalse);
    });

    testWidgets('flush and reset go through', (_) async {
      await Dyplink.instance.flush();
      await Dyplink.instance.reset();
      expect(await Dyplink.instance.distinctId, isNotEmpty);
    });
  });

  group('platform-specific members', () {
    testWidgets('token stream is Android-only', (_) async {
      if (Platform.isIOS) {
        expect(() => DyplinkPush.instance.tokens, throwsUnsupportedError);
      } else {
        expect(DyplinkPush.instance.tokens, isA<Stream<String>>());
      }
    });

    testWidgets('Mi Push registration is Android-only', (_) async {
      if (Platform.isIOS) {
        expect(
          () => DyplinkPush.instance.registerMiPushToken('regid'),
          throwsUnsupportedError,
        );
      }
      // On Android this would hit the network, so there is nothing to assert
      // here that would not be a backend test.
    });
  });
}
