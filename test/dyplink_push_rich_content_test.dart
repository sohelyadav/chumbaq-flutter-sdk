import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:dyplink/dyplink.dart';

/// The rich-content accessors are pure map reads, but the map crosses a
/// platform channel and holds whatever the OS handed over — so the cases that
/// matter are the malformed ones.
void main() {
  group('carouselFrom', () {
    test('reads slides a campaign carried', () {
      final slides = DyplinkPush.carouselFrom({
        'dyplink_carousel': jsonEncode([
          {'imageUrl': 'https://cdn.test/1.png', 'caption': 'One'},
          {'imageUrl': 'https://cdn.test/2.png', 'deepLinkUrl': 'app://two'},
        ]),
      });

      expect(slides, hasLength(2));
      expect(slides.first.caption, 'One');
      expect(slides.last.deepLinkUrl, 'app://two');
      // Null rather than empty: null means "use the campaign's own link".
      expect(slides.first.deepLinkUrl, isNull);
    });

    test('returns nothing when the campaign carried no carousel', () {
      expect(DyplinkPush.carouselFrom({}), isEmpty);
    });

    test('drops a slide with no image rather than showing a blank frame', () {
      final slides = DyplinkPush.carouselFrom({
        'dyplink_carousel': jsonEncode([
          {'imageUrl': 'https://cdn.test/1.png'},
          {'caption': 'no image'},
        ]),
      });

      expect(slides, hasLength(1));
    });

    test('survives malformed json', () {
      // Malformed content costs the extras, never the notification.
      expect(DyplinkPush.carouselFrom({'dyplink_carousel': 'not json'}), isEmpty);
    });

    test('survives a payload that is not a list', () {
      expect(
        DyplinkPush.carouselFrom({'dyplink_carousel': jsonEncode({'a': 1})}),
        isEmpty,
      );
    });

    test('ignores a non-String value', () {
      expect(DyplinkPush.carouselFrom({'dyplink_carousel': 42}), isEmpty);
    });
  });

  group('timerFrom', () {
    test('reads a countdown', () {
      final timer = DyplinkPush.timerFrom({
        'dyplink_timer': jsonEncode({
          'endsAt': '2099-01-01T00:00:00.000Z',
          'expiredTitle': 'Gone',
        }),
      });

      expect(timer, isNotNull);
      expect(timer!.expiredTitle, 'Gone');
      expect(timer.hasExpired, isFalse);
    });

    test('reports a countdown that has already run out', () {
      final timer = DyplinkPush.timerFrom({
        'dyplink_timer': jsonEncode({'endsAt': '2000-01-01T00:00:00.000Z'}),
      });

      // Ordinary rather than exceptional: a notification can sit undelivered
      // for longer than its countdown lasts.
      expect(timer!.hasExpired, isTrue);
    });

    test('returns null for an unparseable end time', () {
      // A countdown to an unknown moment is worse than none.
      expect(
        DyplinkPush.timerFrom({
          'dyplink_timer': jsonEncode({'endsAt': 'next tuesday'}),
        }),
        isNull,
      );
    });

    test('returns null when endsAt is missing', () {
      expect(
        DyplinkPush.timerFrom({
          'dyplink_timer': jsonEncode({'expiredTitle': 'Gone'}),
        }),
        isNull,
      );
    });

    test('survives malformed json', () {
      expect(DyplinkPush.timerFrom({'dyplink_timer': '{{{'}), isNull);
    });
  });

  group('actionsFrom', () {
    test('reads the buttons a campaign carried, in order', () {
      final actions = DyplinkPush.actionsFrom({
        'dyplink_actions': jsonEncode([
          {'id': 'shop', 'title': 'Shop now', 'deepLinkUrl': 'app://sale'},
          {'id': 'later', 'title': 'Remind me'},
        ]),
      });

      expect(actions.map((a) => a.id), ['shop', 'later']);
      expect(actions.first.title, 'Shop now');
      expect(actions.first.deepLinkUrl, 'app://sale');
      // Null means the campaign's own deep link applies.
      expect(actions.last.deepLinkUrl, isNull);
    });

    test('drops a button with no id, since a tap could not be attributed', () {
      final actions = DyplinkPush.actionsFrom({
        'dyplink_actions': jsonEncode([
          {'title': 'Nameless'},
          {'id': 'ok', 'title': 'Fine'},
        ]),
      });

      expect(actions.map((a) => a.id), ['ok']);
    });

    test('drops a button with no title, since there is nothing to show', () {
      final actions = DyplinkPush.actionsFrom({
        'dyplink_actions': jsonEncode([
          {'id': 'blank'},
          {'id': 'ok', 'title': 'Fine'},
        ]),
      });

      expect(actions.map((a) => a.id), ['ok']);
    });

    test('is empty when the campaign carried none', () {
      expect(DyplinkPush.actionsFrom({}), isEmpty);
      expect(DyplinkPush.actionsFrom({'dyplink_actions': ''}), isEmpty);
    });

    test('survives malformed json', () {
      expect(DyplinkPush.actionsFrom({'dyplink_actions': 'not json'}), isEmpty);
      expect(
        DyplinkPush.actionsFrom({'dyplink_actions': jsonEncode({'a': 1})}),
        isEmpty,
      );
    });

    test('survives a value that is not a string at all', () {
      expect(DyplinkPush.actionsFrom({'dyplink_actions': 42}), isEmpty);
    });
  });

  group('imageUrlFrom', () {
    test('reads the image a campaign carried', () {
      expect(
        DyplinkPush.imageUrlFrom({'dyplink_image_url': 'https://cdn.test/hero.png'}),
        'https://cdn.test/hero.png',
      );
    });

    test('is null when the campaign carried none', () {
      // Which is the ordinary case over FCM: it has an image field of its
      // own and its client SDK renders it without help.
      expect(DyplinkPush.imageUrlFrom({}), isNull);
      expect(DyplinkPush.imageUrlFrom({'dyplink_image_url': ''}), isNull);
    });

    test('is null for a value that is not a string', () {
      expect(DyplinkPush.imageUrlFrom({'dyplink_image_url': 42}), isNull);
    });
  });
}
