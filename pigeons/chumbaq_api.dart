// =============================================================================
// Chumbaq Flutter SDK — Pigeon bridge contract
//
// This file is the SINGLE SOURCE OF TRUTH for all calls that cross the
// Flutter <-> native boundary. Do NOT edit the generated files:
//   - lib/src/pigeon.g.dart
//   - android/src/main/kotlin/com/chumbaq/chumbaq/PigeonApi.g.kt
//   - ios/chumbaq/Sources/chumbaq/PigeonApi.g.swift
//
// To regenerate after changes:
//   dart run pigeon --input pigeons/chumbaq_api.dart
//
// Design notes:
//   * Every HostApi method below is a pure forwarding call into the native
//     SDK — on Android com.chumbaq.sdk.Chumbaq / com.chumbaq.push.ChumbaqPush /
//     com.chumbaq.banners.ChumbaqBanners / com.chumbaq.messages.ChumbaqMessages,
//     on iOS the Chumbaq / ChumbaqPush / ChumbaqBanners / ChumbaqMessages
//     singletons of chumbaq-ios-sdk.
//   * Three methods have no iOS counterpart and fail loudly there rather than
//     pretending: startTokenStream, stopTokenStream (iOS has no token-refresh
//     callback — the host app owns APNs registration) and registerMiPushToken
//     (Mi Push is a Xiaomi/Android channel).
//   * Business logic (queue, retry, session, HTTP, storage) stays in native.
//   * Streams (deep links, push tokens, message events) are NOT in this file —
//     they use raw EventChannels because Pigeon models single calls, not streams.
//     See lib/src/event_channels.dart for the stream wiring.
// =============================================================================

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/com/chumbaq/chumbaq/PigeonApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.chumbaq.chumbaq'),
    swiftOut: 'ios/chumbaq/Sources/chumbaq/PigeonApi.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'chumbaq',
  ),
)

// ─── Enums ────────────────────────────────────────────────────────────────────

/// Mirrors com.chumbaq.sdk.internal.util.LogLevel.
enum ChumbaqLogLevel { none, error, warn, info, debug, verbose }

// ─── Config ───────────────────────────────────────────────────────────────────

/// Flat configuration object passed to [ChumbaqHostApi.init].
///
/// All fields have the same semantics as
/// `com.chumbaq.sdk.ChumbaqConfig.Builder`. The native side converts this
/// to a real `ChumbaqConfig` via its builder so validation rules
/// (non-blank strings, positive intervals) are enforced by existing Kotlin
/// code.
class ChumbaqConfigDto {
  ChumbaqConfigDto({
    required this.baseUrl,
    required this.apiKey,
    required this.projectId,
    this.logLevel = ChumbaqLogLevel.none,
    this.flushIntervalSeconds = 30,
    this.maxQueueSize = 1000,
    this.maxRetries = 3,
    this.sessionTimeoutSeconds = 300,
    this.enableAutoSessionTracking = true,
    this.enableAutoDeviceInfo = true,
    this.deepLinkHosts = const <String>[],
    this.customScheme,
  });

  final String baseUrl;
  final String apiKey;
  final String projectId;
  final ChumbaqLogLevel logLevel;
  final int flushIntervalSeconds;
  final int maxQueueSize;
  final int maxRetries;
  final int sessionTimeoutSeconds;
  final bool enableAutoSessionTracking;
  final bool enableAutoDeviceInfo;
  final List<String> deepLinkHosts;
  final String? customScheme;
}

// ─── Identity ─────────────────────────────────────────────────────────────────

/// Mirrors com.chumbaq.sdk.model.IdentifyParams — flat DTO (builder lives in Dart).
class IdentifyParamsDto {
  IdentifyParamsDto({
    this.distinctId,
    this.externalUserId,
    this.firstName,
    this.lastName,
    this.phone,
    this.avatar,
    this.locale,
    this.language,
    this.appVersion,
    this.appBuild,
    this.traits,
    this.utmSource,
    this.utmMedium,
    this.utmCampaign,
    this.utmContent,
    this.utmTerm,
    this.installSource,
    this.installCampaign,
    this.emailOptIn,
    this.smsOptIn,
    this.pushOptIn,
    this.gdprConsent,
    this.doNotTrack,
  });

  final String? distinctId;
  final String? externalUserId;
  final String? firstName;
  final String? lastName;
  final String? phone;
  final String? avatar;
  final String? locale;
  final String? language;
  final String? appVersion;
  final String? appBuild;
  final Map<String?, Object?>? traits;
  final String? utmSource;
  final String? utmMedium;
  final String? utmCampaign;
  final String? utmContent;
  final String? utmTerm;
  final String? installSource;
  final String? installCampaign;
  final bool? emailOptIn;
  final bool? smsOptIn;
  final bool? pushOptIn;
  final bool? gdprConsent;
  final bool? doNotTrack;
}

/// Mirrors com.chumbaq.sdk.model.IdentifyResult.
class IdentifyResultDto {
  IdentifyResultDto({
    required this.id,
    required this.projectId,
    this.distinctId,
    this.externalUserId,
    required this.deviceFingerprint,
    required this.platform,
  });

  final String id;
  final String projectId;
  final String? distinctId;
  final String? externalUserId;
  final String deviceFingerprint;
  final String platform;
}

// ─── Deep Links ───────────────────────────────────────────────────────────────

/// Mirrors com.chumbaq.sdk.model.DeepLinkResult.
class DeepLinkResultDto {
  DeepLinkResultDto({
    required this.url,
    this.shortCode,
    this.params,
    required this.isDeferred,
    this.linkId,
  });

  final String url;
  final String? shortCode;
  final Map<String?, Object?>? params;
  final bool isDeferred;
  final String? linkId;
}

/// Mirrors com.chumbaq.sdk.model.DeferredMatchResult.
class DeferredMatchResultDto {
  DeferredMatchResultDto({
    required this.matched,
    this.linkId,
    this.shortCode,
    this.params,
  });

  final bool matched;
  final String? linkId;
  final String? shortCode;
  final Map<String?, Object?>? params;
}

// ─── Conversions ──────────────────────────────────────────────────────────────

/// Mirrors com.chumbaq.sdk.model.TrackConversionParams.
class TrackConversionParamsDto {
  TrackConversionParamsDto({
    required this.eventType,
    this.shortCode,
    this.linkId,
    this.externalUserId,
    this.metadata,
  });

  final String eventType;
  final String? shortCode;
  final String? linkId;
  final String? externalUserId;
  final Map<String?, Object?>? metadata;
}

// ─── Banners ──────────────────────────────────────────────────────────────────

/// Mirrors com.chumbaq.banners.model.Banner.
class BannerDto {
  BannerDto({
    required this.id,
    required this.title,
    this.imageUrl,
    this.clickUrl,
    this.ctaText,
    required this.sortOrder,
    required this.isActive,
    this.metadata,
  });

  final String id;
  final String title;
  final String? imageUrl;
  final String? clickUrl;
  final String? ctaText;
  final int sortOrder;
  final bool isActive;
  final Map<String?, Object?>? metadata;
}

/// Mirrors com.chumbaq.banners.model.BannerCategory.
class BannerCategoryDto {
  BannerCategoryDto({
    required this.id,
    required this.name,
    required this.layout,
    this.aspectRatio,
    required this.autoRotate,
    required this.rotationInterval,
    this.heading,
    required this.backgroundColor,
    required this.padding,
    required this.banners,
  });

  final String id;
  final String name;
  final String layout;
  final String? aspectRatio;
  final bool autoRotate;
  final int rotationInterval;
  final String? heading;
  final String backgroundColor;
  final int padding;
  final List<BannerDto?> banners;
}

// ─── In-App Messages ──────────────────────────────────────────────────────────

/// Mirrors com.chumbaq.messages.model.MessageButton.
class MessageButtonDto {
  MessageButtonDto({
    required this.id,
    required this.text,
    required this.action,
    this.actionUrl,
    this.actionEvent,
    required this.style,
  });

  final String id;
  final String text;
  final String action; // "dismiss" | "deep_link" | "url" | "custom_event"
  final String? actionUrl;
  final String? actionEvent;
  final String style; // "primary" | "secondary" | "text"
}

/// Mirrors com.chumbaq.messages.model.MessageTheme.
class MessageThemeDto {
  MessageThemeDto({
    this.backgroundColor,
    this.textColor,
    this.titleColor,
    this.buttonPrimaryColor,
    this.buttonSecondaryColor,
    this.overlayColor,
    this.borderRadius,
    this.animation,
  });

  final String? backgroundColor;
  final String? textColor;
  final String? titleColor;
  final String? buttonPrimaryColor;
  final String? buttonSecondaryColor;
  final String? overlayColor;
  final int? borderRadius;
  final String? animation;
}

/// Mirrors com.chumbaq.messages.model.InAppMessage (delivered to the stream,
/// not returned from a method call).
class InAppMessageDto {
  InAppMessageDto({
    required this.id,
    required this.messageType,
    required this.title,
    this.body,
    this.imageUrl,
    required this.imagePosition,
    this.buttons,
    this.theme,
    required this.dismissOnTapOutside,
    this.autoDismissSeconds,
    required this.triggerDelay,
  });

  final String id;
  final String messageType;
  final String title;
  final String? body;
  final String? imageUrl;
  final String imagePosition;
  final List<MessageButtonDto?>? buttons;
  final MessageThemeDto? theme;
  final bool dismissOnTapOutside;
  final int? autoDismissSeconds;
  final int triggerDelay;
}

// =============================================================================
// HOST APIs (Flutter → Native)
// =============================================================================

/// Core SDK bridge — forwards to `com.chumbaq.sdk.Chumbaq`.
@HostApi()
abstract class ChumbaqHostApi {
  /// Forwards to `Chumbaq.init(context, ChumbaqConfig)`. Idempotent.
  ///
  /// Named `initialize` (not `init`) because `init` is a Swift reserved
  /// keyword that Pigeon's Swift codegen can't escape correctly.
  void initialize(ChumbaqConfigDto config);

  /// `Chumbaq.isInitialized`.
  bool isInitialized();

  /// `Chumbaq.distinctId`. Throws `PlatformException(NOT_INITIALIZED)` if not init'd.
  String distinctId();

  /// `Chumbaq.deviceFingerprint`. Throws `PlatformException(NOT_INITIALIZED)` if not init'd.
  String deviceFingerprint();

  /// Forwards to suspend `Chumbaq.identify(params)`.
  /// Throws `PlatformException` on any failure.
  @async
  IdentifyResultDto identify(IdentifyParamsDto params);

  /// Forwards to `Chumbaq.track(name, props)`. Fire-and-forget.
  void track(String eventName, Map<String?, Object?>? properties);

  /// Forwards to `Chumbaq.trackConversion(params)`.
  void trackConversion(TrackConversionParamsDto params);

  /// Forwards to `Chumbaq.trackRevenue(amount, currency)`.
  void trackRevenue(double amount, String currency);

  /// Forwards to suspend `Chumbaq.matchDeferredDeepLink()`.
  @async
  DeferredMatchResultDto matchDeferredDeepLink();

  /// `Chumbaq.getAttributedShortCode()`.
  String? getAttributedShortCode();

  /// `Chumbaq.getAttributedLinkId()`.
  String? getAttributedLinkId();

  /// `Chumbaq.reset()`.
  void reset();

  /// Forwards to suspend `Chumbaq.flush()`.
  @async
  void flush();

  // ── Deep link stream lifecycle ─────────────────────────────────────────────
  //
  // The native plugin installs an EventChannel named
  // "com.chumbaq.chumbaq/deep_links" which emits a serialized
  // DeepLinkResultDto each time the native SDK's DeepLinkListener fires.
  //
  // These two methods let the Dart side tell the plugin to start/stop
  // forwarding. Calling start() wires the internal DeepLinkListener; stop()
  // removes it. Subscribing to the EventChannel is what the Dart facade
  // exposes as `Chumbaq.deepLinks: Stream<DeepLinkResult>`.
  void startDeepLinkStream();
  void stopDeepLinkStream();
}

/// Push module bridge — forwards to `com.chumbaq.push.ChumbaqPush`.
@HostApi()
abstract class ChumbaqPushHostApi {
  /// `ChumbaqPush.init(context)`. Requires `ChumbaqHostApi.initialize` first.
  /// Named `initialize` (not `init`) — see [ChumbaqHostApi.initialize] for why.
  void initialize();

  /// `ChumbaqPush.isInitialized`.
  ///
  /// Named `isPushInitialized`, not `isInitialized`, because the native
  /// plugin classes implement every HostApi in this file on a single object.
  /// Pigeon turns each HostApi into an interface/protocol, so two of them
  /// declaring `isInitialized(): Bool` collapse to one implementation —
  /// whichever the class writes answers both channels, and the push
  /// module's own state becomes unreachable. Unlike [ChumbaqHostApi.initialize]
  /// vs [initialize], the signatures here are identical, so there is nothing
  /// for overload resolution to tell apart. The Dart facade still exposes
  /// this as `ChumbaqPush.isInitialized`.
  bool isPushInitialized();

  /// `ChumbaqPush.isRegistered`.
  bool isRegistered();

  /// Forwards to suspend `ChumbaqPush.registerToken(token)`.
  @async
  void registerToken(String token);

  /// Forwards to suspend `ChumbaqPush.registerMiPushToken(regId)`.
  ///
  /// A vendor channel alongside FCM rather than a replacement for it: MIUI
  /// throttles background FCM, so on Xiaomi devices this is the one that gets
  /// delivered. The host app owns the Mi Push SDK and passes the regId it
  /// receives; see the native SDK's `ChumbaqPush.registerMiPushToken` for the
  /// full contract.
  @async
  void registerMiPushToken(String regId);

  /// Forwards to suspend `ChumbaqPush.unregisterToken()`.
  @async
  void unregisterToken();

  // ── Push token stream lifecycle ────────────────────────────────────────────
  //
  // EventChannel "com.chumbaq.chumbaq/push_tokens" emits the FCM token
  // whenever ChumbaqMessagingService reports a refresh. start/stop wires
  // a listener inside the plugin.
  void startTokenStream();
  void stopTokenStream();
}

/// Banners module bridge — forwards to `com.chumbaq.banners.ChumbaqBanners`.
@HostApi()
abstract class ChumbaqBannersHostApi {
  /// Forwards to suspend `ChumbaqBanners.loadBanners(categoryId)`.
  @async
  BannerCategoryDto loadBanners(String categoryId);

  /// `ChumbaqBanners.clearCache()`.
  void clearCache();

  // Note: BannerCarouselView is embedded via PlatformView, NOT this API.
  // See `ChumbaqBannerCarousel` widget in lib/chumbaq.dart — it uses an
  // AndroidView with viewType "com.chumbaq.chumbaq/banner_carousel".
}

/// In-app messages bridge — forwards to `com.chumbaq.messages.ChumbaqMessages`.
@HostApi()
abstract class ChumbaqMessagesHostApi {
  /// `ChumbaqMessages.onAppOpen(context)`.
  void onAppOpen();

  /// `ChumbaqMessages.onScreenView(context, screen)`.
  void onScreenView(String screen);

  /// `ChumbaqMessages.onEvent(context, event)`.
  void onEvent(String event);

  // ── Message event stream lifecycle ─────────────────────────────────────────
  //
  // EventChannel "com.chumbaq.chumbaq/message_events" emits a map:
  //   { "type": "message_event" | "button_action" | "custom_event",
  //     "message": InAppMessageDto,
  //     "eventType": String?,   // only for "message_event"
  //     "buttonId": String?,    // only for "message_event"
  //     "button": MessageButtonDto?, // only for "button_action"
  //     "eventName": String?,   // only for "custom_event" }
  //
  // The Dart facade decodes and re-emits as separate typed streams.
  void startMessageEventStream();
  void stopMessageEventStream();
}
