// Tests for the iOS half of the platform bridge.
//
// Scope:
//   * The event-channel payload shape the iOS plugin sends. It drops its
//     nil-valued entries instead of encoding them as null — the Dart
//     parsers read optionals as `map['key'] as T?`, for which an absent key
//     and a null one are the same thing, and these tests are what says so.
//   * Platform gating after iOS was de-gated: what answers, what throws,
//     and what is still Android-only.
//
// NOT in scope:
//   * The Swift conversions themselves — exercised by building and running
//     the example app on a simulator.
//   * Anything that needs a bound platform channel: `flutter test` runs on
//     the host, where `Platform.isAndroid` and `Platform.isIOS` are both
//     false, so every gated member is on its unsupported path here. That is
//     also what makes the gating assertions below meaningful.

import 'package:dyplink/dyplink.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('iOS event payloads — optional fields arrive as absent keys', () {
    test('DeepLinkResult.fromEventMap decodes a minimal iOS payload', () {
      final result = DeepLinkResult.fromEventMap(<Object?, Object?>{
        'url': 'myapp://product/42',
        'isDeferred': false,
      });

      expect(result.url, 'myapp://product/42');
      expect(result.isDeferred, isFalse);
      expect(result.shortCode, isNull);
      expect(result.params, isNull);
      expect(result.linkId, isNull);
    });

    test('DeepLinkResult.fromEventMap decodes a full iOS payload', () {
      final result = DeepLinkResult.fromEventMap(<Object?, Object?>{
        'url': 'https://links.example.com/aB3dE?utm_source=ig',
        'shortCode': 'aB3dE',
        'params': <Object?, Object?>{'utm_source': 'ig', 'count': 3},
        'isDeferred': false,
        'linkId': 'link-1',
      });

      expect(result.shortCode, 'aB3dE');
      expect(result.params, <String, Object?>{'utm_source': 'ig', 'count': 3});
      expect(result.linkId, 'link-1');
    });

    test('InAppMessage.fromEventMap decodes a minimal iOS payload', () {
      final message = InAppMessage.fromEventMap(<Object?, Object?>{
        'id': 'm1',
        'messageType': 'modal',
        'title': 'Hello',
        'imagePosition': 'top',
        'dismissOnTapOutside': true,
        'triggerDelay': 0,
      });

      expect(message.id, 'm1');
      expect(message.messageType, 'modal');
      expect(message.title, 'Hello');
      expect(message.imagePosition, 'top');
      expect(message.dismissOnTapOutside, isTrue);
      expect(message.triggerDelay, 0);
      expect(message.body, isNull);
      expect(message.imageUrl, isNull);
      expect(message.buttons, isNull);
      expect(message.theme, isNull);
      expect(message.autoDismissSeconds, isNull);
    });

    test('InAppMessage.fromEventMap decodes buttons and theme', () {
      final message = InAppMessage.fromEventMap(<Object?, Object?>{
        'id': 'm2',
        'messageType': 'bottom_sheet',
        'title': 'Sale',
        'body': '50% off',
        'imagePosition': 'none',
        'buttons': <Object?>[
          <Object?, Object?>{
            'id': 'b1',
            'text': 'Shop',
            'action': 'deep_link',
            'actionUrl': 'myapp://sale',
            'style': 'primary',
          },
          // Second button carries neither actionUrl nor actionEvent, so the
          // iOS payload omits both keys.
          <Object?, Object?>{
            'id': 'b2',
            'text': 'Later',
            'action': 'dismiss',
            'style': 'text',
          },
        ],
        'theme': <Object?, Object?>{
          'backgroundColor': '#ffffff',
          'borderRadius': 12,
        },
        'dismissOnTapOutside': false,
        'autoDismissSeconds': 5,
        'triggerDelay': 2,
      });

      expect(message.buttons, hasLength(2));
      expect(message.buttons![0].actionUrl, 'myapp://sale');
      expect(message.buttons![0].actionEvent, isNull);
      expect(message.buttons![1].action, 'dismiss');
      expect(message.buttons![1].actionUrl, isNull);
      expect(message.theme!.backgroundColor, '#ffffff');
      expect(message.theme!.borderRadius, 12);
      expect(message.theme!.textColor, isNull);
      expect(message.autoDismissSeconds, 5);
    });

    test('MessageTheme.fromEventMap decodes an empty theme', () {
      final theme = MessageTheme.fromEventMap(<Object?, Object?>{});

      expect(theme.backgroundColor, isNull);
      expect(theme.textColor, isNull);
      expect(theme.titleColor, isNull);
      expect(theme.buttonPrimaryColor, isNull);
      expect(theme.buttonSecondaryColor, isNull);
      expect(theme.overlayColor, isNull);
      expect(theme.borderRadius, isNull);
      expect(theme.animation, isNull);
    });

    test('MessageButton.fromEventMap decodes a minimal button', () {
      final button = MessageButton.fromEventMap(<Object?, Object?>{
        'id': 'b1',
        'text': 'OK',
        'action': 'dismiss',
        'style': 'secondary',
      });

      expect(button.id, 'b1');
      expect(button.actionUrl, isNull);
      expect(button.actionEvent, isNull);
      expect(button.style, 'secondary');
    });
  });

  group('platform gating', () {
    // The host platform under `flutter test` is neither Android nor iOS, so
    // these exercise the unsupported branch. What they pin down is which
    // members answer instead of throwing, and that the messages no longer
    // claim iOS is unsupported.

    test('feature-detection predicates answer false instead of throwing', () {
      expect(Dyplink.instance.isInitialized, completion(isFalse));
      expect(DyplinkPush.instance.isInitialized, completion(isFalse));
      expect(DyplinkPush.instance.isRegistered, completion(isFalse));
    });

    test('core members name both supported platforms when unsupported', () {
      expect(
        () => Dyplink.instance.distinctId,
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Android'), contains('iOS'), isNot(contains('coming soon'))),
          ),
        ),
      );
    });

    test('module members name both supported platforms when unsupported', () {
      for (final call in <Function()>[
        () => DyplinkMessages.instance.onAppOpen(),
        () => DyplinkBanners.instance.loadBanners('home-top'),
        () => DyplinkPush.instance.init(),
      ]) {
        expect(
          call,
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              allOf(contains('Android'), contains('iOS')),
            ),
          ),
        );
      }
    });

    test('DyplinkPush.tokens stays Android-only and says why', () {
      expect(
        () => DyplinkPush.instance.tokens,
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Android-only'), contains('APNs')),
          ),
        ),
      );
    });

    test('DyplinkPush.registerMiPushToken stays Android-only and says why', () {
      expect(
        () => DyplinkPush.instance.registerMiPushToken('regid'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Android-only'), contains('Xiaomi')),
          ),
        ),
      );
    });
  });
}
