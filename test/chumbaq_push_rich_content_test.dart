import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:chumbaq/chumbaq.dart';

/// The rich-content accessors are pure map reads, but the map crosses a
/// platform channel and holds whatever the OS handed over — so the cases that
/// matter are the malformed ones.
void main() {
  group('carouselFrom', () {
    test('reads slides a campaign carried', () {
      final slides = ChumbaqPush.carouselFrom({
        'chumbaq_carousel': jsonEncode([
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
      expect(ChumbaqPush.carouselFrom({}), isEmpty);
    });

    test('drops a slide with no image rather than showing a blank frame', () {
      final slides = ChumbaqPush.carouselFrom({
        'chumbaq_carousel': jsonEncode([
          {'imageUrl': 'https://cdn.test/1.png'},
          {'caption': 'no image'},
        ]),
      });

      expect(slides, hasLength(1));
    });

    test('survives malformed json', () {
      // Malformed content costs the extras, never the notification.
      expect(ChumbaqPush.carouselFrom({'chumbaq_carousel': 'not json'}), isEmpty);
    });

    test('survives a payload that is not a list', () {
      expect(
        ChumbaqPush.carouselFrom({'chumbaq_carousel': jsonEncode({'a': 1})}),
        isEmpty,
      );
    });

    test('ignores a non-String value', () {
      expect(ChumbaqPush.carouselFrom({'chumbaq_carousel': 42}), isEmpty);
    });
  });

  group('timerFrom', () {
    test('reads a countdown', () {
      final timer = ChumbaqPush.timerFrom({
        'chumbaq_timer': jsonEncode({
          'endsAt': '2099-01-01T00:00:00.000Z',
          'expiredTitle': 'Gone',
        }),
      });

      expect(timer, isNotNull);
      expect(timer!.expiredTitle, 'Gone');
      expect(timer.hasExpired, isFalse);
    });

    test('reports a countdown that has already run out', () {
      final timer = ChumbaqPush.timerFrom({
        'chumbaq_timer': jsonEncode({'endsAt': '2000-01-01T00:00:00.000Z'}),
      });

      // Ordinary rather than exceptional: a notification can sit undelivered
      // for longer than its countdown lasts.
      expect(timer!.hasExpired, isTrue);
    });

    test('returns null for an unparseable end time', () {
      // A countdown to an unknown moment is worse than none.
      expect(
        ChumbaqPush.timerFrom({
          'chumbaq_timer': jsonEncode({'endsAt': 'next tuesday'}),
        }),
        isNull,
      );
    });

    test('returns null when endsAt is missing', () {
      expect(
        ChumbaqPush.timerFrom({
          'chumbaq_timer': jsonEncode({'expiredTitle': 'Gone'}),
        }),
        isNull,
      );
    });

    test('survives malformed json', () {
      expect(ChumbaqPush.timerFrom({'chumbaq_timer': '{{{'}), isNull);
    });
  });

  group('actionsFrom', () {
    test('reads the buttons a campaign carried, in order', () {
      final actions = ChumbaqPush.actionsFrom({
        'chumbaq_actions': jsonEncode([
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
      final actions = ChumbaqPush.actionsFrom({
        'chumbaq_actions': jsonEncode([
          {'title': 'Nameless'},
          {'id': 'ok', 'title': 'Fine'},
        ]),
      });

      expect(actions.map((a) => a.id), ['ok']);
    });

    test('drops a button with no title, since there is nothing to show', () {
      final actions = ChumbaqPush.actionsFrom({
        'chumbaq_actions': jsonEncode([
          {'id': 'blank'},
          {'id': 'ok', 'title': 'Fine'},
        ]),
      });

      expect(actions.map((a) => a.id), ['ok']);
    });

    test('is empty when the campaign carried none', () {
      expect(ChumbaqPush.actionsFrom({}), isEmpty);
      expect(ChumbaqPush.actionsFrom({'chumbaq_actions': ''}), isEmpty);
    });

    test('survives malformed json', () {
      expect(ChumbaqPush.actionsFrom({'chumbaq_actions': 'not json'}), isEmpty);
      expect(
        ChumbaqPush.actionsFrom({'chumbaq_actions': jsonEncode({'a': 1})}),
        isEmpty,
      );
    });

    test('survives a value that is not a string at all', () {
      expect(ChumbaqPush.actionsFrom({'chumbaq_actions': 42}), isEmpty);
    });
  });

  group('imageUrlFrom', () {
    test('reads the image a campaign carried', () {
      expect(
        ChumbaqPush.imageUrlFrom({'chumbaq_image_url': 'https://cdn.test/hero.png'}),
        'https://cdn.test/hero.png',
      );
    });

    test('is null when the campaign carried none', () {
      // Which is the ordinary case over FCM: it has an image field of its
      // own and its client SDK renders it without help.
      expect(ChumbaqPush.imageUrlFrom({}), isNull);
      expect(ChumbaqPush.imageUrlFrom({'chumbaq_image_url': ''}), isNull);
    });

    test('is null for a value that is not a string', () {
      expect(ChumbaqPush.imageUrlFrom({'chumbaq_image_url': 42}), isNull);
    });
  });
}
