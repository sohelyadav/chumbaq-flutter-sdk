// Fake Pigeon HostApis.
//
// Each module exposes its generated HostApi as a settable field for exactly
// this purpose. The fakes record the call they received — the name plus the
// arguments that decide behaviour — so a test can assert both *that* the
// facade forwarded and *what* it forwarded, and can assert silence where a
// platform gate should have stopped the call before it ever got here.
//
// Each can be told to throw a PlatformException instead, which is how the
// swallowed stream-lifecycle paths are driven.

import 'package:dyplink/src/pigeon.g.dart' as pg;
import 'package:flutter/services.dart';

/// Shared bookkeeping: what was called, and what should fail.
mixin _RecordsCalls {
  final List<String> calls = <String>[];

  /// Method names that throw [PlatformException] instead of answering.
  final Map<String, PlatformException> failures = <String, PlatformException>{};

  void record(String call) {
    calls.add(call);
    final name = call.split(':').first;
    final failure = failures[name];
    if (failure != null) throw failure;
  }
}

class FakeDyplinkHostApi extends pg.DyplinkHostApi with _RecordsCalls {
  bool initialized = false;
  String distinct = 'distinct-1';
  String fingerprint = 'fingerprint-1';
  String? attributedShortCode;
  String? attributedLinkId;
  pg.DeferredMatchResultDto deferredMatch =
      pg.DeferredMatchResultDto(matched: false);

  @override
  Future<void> initialize(pg.DyplinkConfigDto config) async {
    record('initialize');
    initialized = true;
  }

  @override
  Future<bool> isInitialized() async {
    record('isInitialized');
    return initialized;
  }

  @override
  Future<String> distinctId() async {
    record('distinctId');
    return distinct;
  }

  @override
  Future<String> deviceFingerprint() async {
    record('deviceFingerprint');
    return fingerprint;
  }

  @override
  Future<pg.IdentifyResultDto> identify(pg.IdentifyParamsDto params) async {
    record('identify:${params.externalUserId}');
    return pg.IdentifyResultDto(
      id: 'id-1',
      projectId: 'project-1',
      distinctId: distinct,
      externalUserId: params.externalUserId,
      deviceFingerprint: fingerprint,
      platform: 'ios',
    );
  }

  @override
  Future<void> track(String eventName, Map<String?, Object?>? properties) async {
    record('track:$eventName');
  }

  @override
  Future<void> trackConversion(pg.TrackConversionParamsDto params) async {
    record('trackConversion:${params.eventType}');
  }

  @override
  Future<void> trackRevenue(double amount, String currency) async {
    record('trackRevenue:$amount:$currency');
  }

  @override
  Future<pg.DeferredMatchResultDto> matchDeferredDeepLink() async {
    record('matchDeferredDeepLink');
    return deferredMatch;
  }

  @override
  Future<String?> getAttributedShortCode() async {
    record('getAttributedShortCode');
    return attributedShortCode;
  }

  @override
  Future<String?> getAttributedLinkId() async {
    record('getAttributedLinkId');
    return attributedLinkId;
  }

  @override
  Future<void> reset() async => record('reset');

  @override
  Future<void> flush() async => record('flush');

  @override
  Future<void> startDeepLinkStream() async => record('startDeepLinkStream');

  @override
  Future<void> stopDeepLinkStream() async => record('stopDeepLinkStream');
}

class FakePushHostApi extends pg.DyplinkPushHostApi with _RecordsCalls {
  bool pushInitialized = false;
  bool registered = false;

  @override
  Future<void> initialize() async {
    record('initialize');
    pushInitialized = true;
  }

  @override
  Future<bool> isPushInitialized() async {
    record('isPushInitialized');
    return pushInitialized;
  }

  @override
  Future<bool> isRegistered() async {
    record('isRegistered');
    return registered;
  }

  @override
  Future<void> registerToken(String token) async => record('registerToken:$token');

  @override
  Future<void> registerMiPushToken(String regId) async =>
      record('registerMiPushToken:$regId');

  @override
  Future<void> unregisterToken() async => record('unregisterToken');

  @override
  Future<void> startTokenStream() async => record('startTokenStream');

  @override
  Future<void> stopTokenStream() async => record('stopTokenStream');
}

class FakeBannersHostApi extends pg.DyplinkBannersHostApi with _RecordsCalls {
  @override
  Future<pg.BannerCategoryDto> loadBanners(String categoryId) async {
    record('loadBanners:$categoryId');
    return pg.BannerCategoryDto(
      id: 'cat-1',
      name: 'Home top',
      layout: 'carousel',
      autoRotate: true,
      rotationInterval: 5,
      backgroundColor: '#ffffff',
      padding: 8,
      banners: <pg.BannerDto?>[
        pg.BannerDto(
          id: 'b-1',
          title: 'Banner one',
          sortOrder: 0,
          isActive: true,
        ),
      ],
    );
  }

  @override
  Future<void> clearCache() async => record('clearCache');
}

class FakeMessagesHostApi extends pg.DyplinkMessagesHostApi with _RecordsCalls {
  @override
  Future<void> onAppOpen() async => record('onAppOpen');

  @override
  Future<void> onScreenView(String screen) async => record('onScreenView:$screen');

  @override
  Future<void> onEvent(String event) async => record('onEvent:$event');

  @override
  Future<void> startMessageEventStream() async => record('startMessageEventStream');

  @override
  Future<void> stopMessageEventStream() async => record('stopMessageEventStream');
}
