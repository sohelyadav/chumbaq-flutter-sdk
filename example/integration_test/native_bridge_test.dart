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

import 'package:chumbaq/chumbaq.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('before Chumbaq.init', () {
    // The iOS SDK logs and no-ops when it is not initialized, where the
    // Android SDK throws. The bridge makes both report NOT_INITIALIZED, so a
    // dropped event is never mistaken for a recorded one.

    testWidgets('isInitialized answers false rather than throwing', (_) async {
      expect(await Chumbaq.instance.isInitialized, isFalse);
      expect(await ChumbaqPush.instance.isInitialized, isFalse);
    });

    testWidgets('track reports NOT_INITIALIZED', (_) async {
      await expectLater(
        Chumbaq.instance.track('too_early'),
        throwsA(isA<ChumbaqNotInitialized>()),
      );
    });

    testWidgets('trackRevenue reports NOT_INITIALIZED', (_) async {
      await expectLater(
        Chumbaq.instance.trackRevenue(1.0),
        throwsA(isA<ChumbaqNotInitialized>()),
      );
    });

    testWidgets('message triggers report NOT_INITIALIZED', (_) async {
      await expectLater(
        ChumbaqMessages.instance.onAppOpen(),
        throwsA(isA<ChumbaqNotInitialized>()),
      );
    });

    testWidgets('loadBanners reports NOT_INITIALIZED', (_) async {
      await expectLater(
        ChumbaqBanners.instance.loadBanners('home-top'),
        throwsA(isA<ChumbaqNotInitialized>()),
      );
    });

    testWidgets('matchDeferredDeepLink reports NOT_INITIALIZED', (_) async {
      // Not "no match": an uninitialized SDK has not looked.
      await expectLater(
        Chumbaq.instance.matchDeferredDeepLink(),
        throwsA(isA<ChumbaqNotInitialized>()),
      );
    });
  });

  group('after Chumbaq.init', () {
    setUpAll(() async {
      final config = ChumbaqConfig.builder(
        baseUrl: 'https://api.chumbaq.example',
        apiKey: 'test-key',
        projectId: 'test-project',
      )
          .logLevel(ChumbaqLogLevel.none)
          .deepLinkHosts(const ['links.chumbaq.example'])
          .customScheme('chumbaqexample')
          .build();
      await Chumbaq.instance.init(config);
    });

    testWidgets('identity accessors answer', (_) async {
      expect(await Chumbaq.instance.isInitialized, isTrue);
      expect(await Chumbaq.instance.distinctId, isNotEmpty);
      expect(await Chumbaq.instance.deviceFingerprint, isNotEmpty);
    });

    testWidgets('fire-and-forget calls go through', (_) async {
      await Chumbaq.instance.track('bridge_test', properties: const {
        'from': 'integration_test',
        'count': 1,
        'ok': true,
      });
      await Chumbaq.instance.trackRevenue(9.99, currency: 'USD');
      await Chumbaq.instance.trackConversion(
        TrackConversionParams(eventType: 'signup', metadata: const {'plan': 'pro'}),
      );
      // Nothing to assert beyond "did not throw": these are queued natively.
    });

    testWidgets('attribution getters answer null without a match', (_) async {
      expect(await Chumbaq.instance.getAttributedShortCode(), isNull);
      expect(await Chumbaq.instance.getAttributedLinkId(), isNull);
    });

    testWidgets('message triggers go through once initialized', (_) async {
      await ChumbaqMessages.instance.onAppOpen();
      await ChumbaqMessages.instance.onScreenView('HomeScreen');
      await ChumbaqMessages.instance.onEvent('purchase');
    });

    testWidgets('the deep link stream attaches and detaches', (_) async {
      final sub = Chumbaq.instance.deepLinks.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
    });

    testWidgets('the message event stream attaches and detaches', (_) async {
      final sub = ChumbaqMessages.instance.events.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
    });

    testWidgets('push initializes and reports its own state', (_) async {
      await ChumbaqPush.instance.init();
      expect(await ChumbaqPush.instance.isInitialized, isTrue);
      // No token has been registered, and the core SDK's isInitialized must
      // not be what answers here — that was the bug the Pigeon rename fixed.
      expect(await ChumbaqPush.instance.isRegistered, isFalse);
    });

    testWidgets('flush and reset go through', (_) async {
      await Chumbaq.instance.flush();
      await Chumbaq.instance.reset();
      expect(await Chumbaq.instance.distinctId, isNotEmpty);
    });
  });

  group('platform-specific members', () {
    testWidgets('token stream is Android-only', (_) async {
      if (Platform.isIOS) {
        expect(() => ChumbaqPush.instance.tokens, throwsUnsupportedError);
      } else {
        expect(ChumbaqPush.instance.tokens, isA<Stream<String>>());
      }
    });

    testWidgets('Mi Push registration is Android-only', (_) async {
      if (Platform.isIOS) {
        expect(
          () => ChumbaqPush.instance.registerMiPushToken('regid'),
          throwsUnsupportedError,
        );
      }
      // On Android this would hit the network, so there is nothing to assert
      // here that would not be a backend test.
    });
  });
}
