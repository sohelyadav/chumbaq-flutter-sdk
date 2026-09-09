// Public Dart models for the Dyplink SDK.
//
// These are hand-written wrappers around the auto-generated Pigeon DTOs in
// `pigeon.g.dart`. Users import these via `package:dyplink/dyplink.dart` —
// they should never see the `*Dto` names.

import 'pigeon.g.dart' as pg;

// ─── LogLevel ────────────────────────────────────────────────────────────────

/// Verbosity of the Dyplink SDK's internal logger.
///
/// Mirrors `com.dyplink.sdk.internal.util.LogLevel` on Android.
enum DyplinkLogLevel {
  none,
  error,
  warn,
  info,
  debug,
  verbose;

  pg.DyplinkLogLevel toDto() => switch (this) {
        DyplinkLogLevel.none => pg.DyplinkLogLevel.none,
        DyplinkLogLevel.error => pg.DyplinkLogLevel.error,
        DyplinkLogLevel.warn => pg.DyplinkLogLevel.warn,
        DyplinkLogLevel.info => pg.DyplinkLogLevel.info,
        DyplinkLogLevel.debug => pg.DyplinkLogLevel.debug,
        DyplinkLogLevel.verbose => pg.DyplinkLogLevel.verbose,
      };
}

// ─── DyplinkConfig ───────────────────────────────────────────────────────────

/// Immutable configuration for the Dyplink SDK.
///
/// Use [DyplinkConfig.builder] to construct:
/// ```dart
/// final config = DyplinkConfig.builder(
///   baseUrl: 'https://api.dyplink.com',
///   apiKey: 'your-api-key',
///   projectId: 'your-project-id',
/// )
///   .logLevel(DyplinkLogLevel.debug)
///   .flushInterval(const Duration(seconds: 60))
///   .build();
/// ```
class DyplinkConfig {
  DyplinkConfig._({
    required this.baseUrl,
    required this.apiKey,
    required this.projectId,
    required this.logLevel,
    required this.flushIntervalSeconds,
    required this.maxQueueSize,
    required this.maxRetries,
    required this.sessionTimeoutSeconds,
    required this.enableAutoSessionTracking,
    required this.enableAutoDeviceInfo,
    required this.deepLinkHosts,
    required this.customScheme,
  });

  final String baseUrl;
  final String apiKey;
  final String projectId;
  final DyplinkLogLevel logLevel;
  final int flushIntervalSeconds;
  final int maxQueueSize;
  final int maxRetries;
  final int sessionTimeoutSeconds;
  final bool enableAutoSessionTracking;
  final bool enableAutoDeviceInfo;
  final List<String> deepLinkHosts;
  final String? customScheme;

  /// Creates a builder with the three required fields.
  static DyplinkConfigBuilder builder({
    required String baseUrl,
    required String apiKey,
    required String projectId,
  }) =>
      DyplinkConfigBuilder._(
        baseUrl: baseUrl,
        apiKey: apiKey,
        projectId: projectId,
      );

  pg.DyplinkConfigDto toDto() => pg.DyplinkConfigDto(
        baseUrl: baseUrl,
        apiKey: apiKey,
        projectId: projectId,
        logLevel: logLevel.toDto(),
        flushIntervalSeconds: flushIntervalSeconds,
        maxQueueSize: maxQueueSize,
        maxRetries: maxRetries,
        sessionTimeoutSeconds: sessionTimeoutSeconds,
        enableAutoSessionTracking: enableAutoSessionTracking,
        enableAutoDeviceInfo: enableAutoDeviceInfo,
        deepLinkHosts: deepLinkHosts,
        customScheme: customScheme,
      );
}

/// Fluent builder for [DyplinkConfig]. Mirrors the Android SDK's
/// `DyplinkConfig.Builder`.
class DyplinkConfigBuilder {
  DyplinkConfigBuilder._({
    required this.baseUrl,
    required this.apiKey,
    required this.projectId,
  });

  final String baseUrl;
  final String apiKey;
  final String projectId;

  DyplinkLogLevel _logLevel = DyplinkLogLevel.none;
  int _flushIntervalSeconds = 30;
  int _maxQueueSize = 1000;
  int _maxRetries = 3;
  int _sessionTimeoutSeconds = 300;
  bool _enableAutoSessionTracking = true;
  bool _enableAutoDeviceInfo = true;
  List<String> _deepLinkHosts = const <String>[];
  String? _customScheme;

  DyplinkConfigBuilder logLevel(DyplinkLogLevel level) {
    _logLevel = level;
    return this;
  }

  DyplinkConfigBuilder flushInterval(Duration interval) {
    _flushIntervalSeconds = interval.inSeconds;
    return this;
  }

  DyplinkConfigBuilder maxQueueSize(int size) {
    _maxQueueSize = size;
    return this;
  }

  DyplinkConfigBuilder maxRetries(int retries) {
    _maxRetries = retries;
    return this;
  }

  DyplinkConfigBuilder sessionTimeout(Duration timeout) {
    _sessionTimeoutSeconds = timeout.inSeconds;
    return this;
  }

  DyplinkConfigBuilder enableAutoSessionTracking(bool enabled) {
    _enableAutoSessionTracking = enabled;
    return this;
  }

  DyplinkConfigBuilder enableAutoDeviceInfo(bool enabled) {
    _enableAutoDeviceInfo = enabled;
    return this;
  }

  DyplinkConfigBuilder deepLinkHosts(List<String> hosts) {
    _deepLinkHosts = List<String>.unmodifiable(hosts);
    return this;
  }

  DyplinkConfigBuilder customScheme(String scheme) {
    _customScheme = scheme;
    return this;
  }

  DyplinkConfig build() {
    if (baseUrl.isEmpty) throw ArgumentError('baseUrl must not be blank');
    if (apiKey.isEmpty) throw ArgumentError('apiKey must not be blank');
    if (projectId.isEmpty) throw ArgumentError('projectId must not be blank');
    if (_flushIntervalSeconds <= 0) {
      throw ArgumentError('flushInterval must be positive');
    }
    if (_maxQueueSize <= 0) {
      throw ArgumentError('maxQueueSize must be positive');
    }
    if (_maxRetries < 0) {
      throw ArgumentError('maxRetries must be non-negative');
    }
    return DyplinkConfig._(
      baseUrl: baseUrl,
      apiKey: apiKey,
      projectId: projectId,
      logLevel: _logLevel,
      flushIntervalSeconds: _flushIntervalSeconds,
      maxQueueSize: _maxQueueSize,
      maxRetries: _maxRetries,
      sessionTimeoutSeconds: _sessionTimeoutSeconds,
      enableAutoSessionTracking: _enableAutoSessionTracking,
      enableAutoDeviceInfo: _enableAutoDeviceInfo,
      deepLinkHosts: _deepLinkHosts,
      customScheme: _customScheme,
    );
  }
}

// ─── IdentifyParams / IdentifyResult ─────────────────────────────────────────

/// Parameters for [Dyplink.identify]. Use [IdentifyParams.builder].
class IdentifyParams {
  IdentifyParams._(this._dto);
  final pg.IdentifyParamsDto _dto;

  static IdentifyParamsBuilder builder() => IdentifyParamsBuilder._();

  pg.IdentifyParamsDto toDto() => _dto;
}

class IdentifyParamsBuilder {
  IdentifyParamsBuilder._();

  String? _distinctId;
  String? _externalUserId;
  String? _firstName;
  String? _lastName;
  String? _phone;
  String? _avatar;
  String? _locale;
  String? _language;
  String? _appVersion;
  String? _appBuild;
  Map<String, Object>? _traits;
  String? _utmSource;
  String? _utmMedium;
  String? _utmCampaign;
  String? _utmContent;
  String? _utmTerm;
  String? _installSource;
  String? _installCampaign;
  bool? _emailOptIn;
  bool? _smsOptIn;
  bool? _pushOptIn;
  bool? _gdprConsent;
  bool? _doNotTrack;

  IdentifyParamsBuilder distinctId(String v) {
    _distinctId = v;
    return this;
  }

  IdentifyParamsBuilder externalUserId(String v) {
    _externalUserId = v;
    return this;
  }

  IdentifyParamsBuilder firstName(String v) {
    _firstName = v;
    return this;
  }

  IdentifyParamsBuilder lastName(String v) {
    _lastName = v;
    return this;
  }

  IdentifyParamsBuilder phone(String v) {
    _phone = v;
    return this;
  }

  IdentifyParamsBuilder avatar(String v) {
    _avatar = v;
    return this;
  }

  IdentifyParamsBuilder locale(String v) {
    _locale = v;
    return this;
  }

  IdentifyParamsBuilder language(String v) {
    _language = v;
    return this;
  }

  IdentifyParamsBuilder appVersion(String v) {
    _appVersion = v;
    return this;
  }

  IdentifyParamsBuilder appBuild(String v) {
    _appBuild = v;
    return this;
  }

  IdentifyParamsBuilder traits(Map<String, Object> v) {
    _traits = Map<String, Object>.unmodifiable(v);
    return this;
  }

  IdentifyParamsBuilder utmSource(String v) {
    _utmSource = v;
    return this;
  }

  IdentifyParamsBuilder utmMedium(String v) {
    _utmMedium = v;
    return this;
  }

  IdentifyParamsBuilder utmCampaign(String v) {
    _utmCampaign = v;
    return this;
  }

  IdentifyParamsBuilder utmContent(String v) {
    _utmContent = v;
    return this;
  }

  IdentifyParamsBuilder utmTerm(String v) {
    _utmTerm = v;
    return this;
  }

  IdentifyParamsBuilder installSource(String v) {
    _installSource = v;
    return this;
  }

  IdentifyParamsBuilder installCampaign(String v) {
    _installCampaign = v;
    return this;
  }

  IdentifyParamsBuilder emailOptIn(bool v) {
    _emailOptIn = v;
    return this;
  }

  IdentifyParamsBuilder smsOptIn(bool v) {
    _smsOptIn = v;
    return this;
  }

  IdentifyParamsBuilder pushOptIn(bool v) {
    _pushOptIn = v;
    return this;
  }

  IdentifyParamsBuilder gdprConsent(bool v) {
    _gdprConsent = v;
    return this;
  }

  IdentifyParamsBuilder doNotTrack(bool v) {
    _doNotTrack = v;
    return this;
  }

  IdentifyParams build() => IdentifyParams._(
        pg.IdentifyParamsDto(
          distinctId: _distinctId,
          externalUserId: _externalUserId,
          firstName: _firstName,
          lastName: _lastName,
          phone: _phone,
          avatar: _avatar,
          locale: _locale,
          language: _language,
          appVersion: _appVersion,
          appBuild: _appBuild,
          traits: _traits,
          utmSource: _utmSource,
          utmMedium: _utmMedium,
          utmCampaign: _utmCampaign,
          utmContent: _utmContent,
          utmTerm: _utmTerm,
          installSource: _installSource,
          installCampaign: _installCampaign,
          emailOptIn: _emailOptIn,
          smsOptIn: _smsOptIn,
          pushOptIn: _pushOptIn,
          gdprConsent: _gdprConsent,
          doNotTrack: _doNotTrack,
        ),
      );
}

/// Result returned from a successful [Dyplink.identify] call.
class IdentifyResult {
  const IdentifyResult({
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

  factory IdentifyResult.fromDto(pg.IdentifyResultDto dto) => IdentifyResult(
        id: dto.id,
        projectId: dto.projectId,
        distinctId: dto.distinctId,
        externalUserId: dto.externalUserId,
        deviceFingerprint: dto.deviceFingerprint,
        platform: dto.platform,
      );
}

// ─── Deep Links ──────────────────────────────────────────────────────────────

/// A resolved deep link — either from a direct intent or from deferred
/// (post-install) matching.
class DeepLinkResult {
  const DeepLinkResult({
    required this.url,
    this.shortCode,
    this.params,
    required this.isDeferred,
    this.linkId,
  });

  final String url;
  final String? shortCode;
  final Map<String, Object?>? params;
  final bool isDeferred;
  final String? linkId;

  factory DeepLinkResult.fromDto(pg.DeepLinkResultDto dto) => DeepLinkResult(
        url: dto.url,
        shortCode: dto.shortCode,
        params: _coerceMap(dto.params),
        isDeferred: dto.isDeferred,
        linkId: dto.linkId,
      );

  /// Deserialize from the raw `Map<String, Object?>` that the native plugin
  /// emits over the EventChannel (see `DyplinkPlugin.deepLinkListener`).
  factory DeepLinkResult.fromEventMap(Map<Object?, Object?> m) => DeepLinkResult(
        url: m['url']! as String,
        shortCode: m['shortCode'] as String?,
        params: _coerceNestedMap(m['params']),
        isDeferred: m['isDeferred']! as bool,
        linkId: m['linkId'] as String?,
      );
}

/// Result of a [Dyplink.matchDeferredDeepLink] call.
class DeferredMatchResult {
  const DeferredMatchResult({
    required this.matched,
    this.linkId,
    this.shortCode,
    this.params,
  });

  final bool matched;
  final String? linkId;
  final String? shortCode;
  final Map<String, Object?>? params;

  factory DeferredMatchResult.fromDto(pg.DeferredMatchResultDto dto) =>
      DeferredMatchResult(
        matched: dto.matched,
        linkId: dto.linkId,
        shortCode: dto.shortCode,
        params: _coerceMap(dto.params),
      );
}

// ─── Conversions ─────────────────────────────────────────────────────────────

/// Parameters for [Dyplink.trackConversion].
class TrackConversionParams {
  const TrackConversionParams({
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
  final Map<String, Object>? metadata;

  pg.TrackConversionParamsDto toDto() => pg.TrackConversionParamsDto(
        eventType: eventType,
        shortCode: shortCode,
        linkId: linkId,
        externalUserId: externalUserId,
        metadata: metadata,
      );
}

// ─── Banners ─────────────────────────────────────────────────────────────────

/// A single banner returned by [DyplinkBanners.loadBanners].
class DyplinkBanner {
  const DyplinkBanner({
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
  final Map<String, Object?>? metadata;

  factory DyplinkBanner.fromDto(pg.BannerDto dto) => DyplinkBanner(
        id: dto.id,
        title: dto.title,
        imageUrl: dto.imageUrl,
        clickUrl: dto.clickUrl,
        ctaText: dto.ctaText,
        sortOrder: dto.sortOrder,
        isActive: dto.isActive,
        metadata: _coerceMap(dto.metadata),
      );
}

/// A category of banners with layout/display settings.
class BannerCategory {
  const BannerCategory({
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
  final List<DyplinkBanner> banners;

  factory BannerCategory.fromDto(pg.BannerCategoryDto dto) => BannerCategory(
        id: dto.id,
        name: dto.name,
        layout: dto.layout,
        aspectRatio: dto.aspectRatio,
        autoRotate: dto.autoRotate,
        rotationInterval: dto.rotationInterval,
        heading: dto.heading,
        backgroundColor: dto.backgroundColor,
        padding: dto.padding,
        banners: [
          for (final b in dto.banners)
            if (b != null) DyplinkBanner.fromDto(b),
        ],
      );
}

// ─── In-App Messages ─────────────────────────────────────────────────────────

class MessageButton {
  const MessageButton({
    required this.id,
    required this.text,
    required this.action,
    this.actionUrl,
    this.actionEvent,
    required this.style,
  });

  final String id;
  final String text;

  /// One of: "dismiss" | "deep_link" | "url" | "custom_event".
  final String action;
  final String? actionUrl;
  final String? actionEvent;

  /// One of: "primary" | "secondary" | "text".
  final String style;

  factory MessageButton.fromEventMap(Map<Object?, Object?> m) => MessageButton(
        id: m['id']! as String,
        text: m['text']! as String,
        action: m['action']! as String,
        actionUrl: m['actionUrl'] as String?,
        actionEvent: m['actionEvent'] as String?,
        style: m['style']! as String,
      );
}

class MessageTheme {
  const MessageTheme({
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

  factory MessageTheme.fromEventMap(Map<Object?, Object?> m) => MessageTheme(
        backgroundColor: m['backgroundColor'] as String?,
        textColor: m['textColor'] as String?,
        titleColor: m['titleColor'] as String?,
        buttonPrimaryColor: m['buttonPrimaryColor'] as String?,
        buttonSecondaryColor: m['buttonSecondaryColor'] as String?,
        overlayColor: m['overlayColor'] as String?,
        borderRadius: m['borderRadius'] as int?,
        animation: m['animation'] as String?,
      );
}

class InAppMessage {
  const InAppMessage({
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
  final List<MessageButton>? buttons;
  final MessageTheme? theme;
  final bool dismissOnTapOutside;
  final int? autoDismissSeconds;
  final int triggerDelay;

  factory InAppMessage.fromEventMap(Map<Object?, Object?> m) {
    final rawButtons = m['buttons'];
    final rawTheme = m['theme'];
    return InAppMessage(
      id: m['id']! as String,
      messageType: m['messageType']! as String,
      title: m['title']! as String,
      body: m['body'] as String?,
      imageUrl: m['imageUrl'] as String?,
      imagePosition: m['imagePosition']! as String,
      buttons: rawButtons is List
          ? [
              for (final b in rawButtons)
                if (b is Map) MessageButton.fromEventMap(b),
            ]
          : null,
      theme: rawTheme is Map ? MessageTheme.fromEventMap(rawTheme) : null,
      dismissOnTapOutside: m['dismissOnTapOutside']! as bool,
      autoDismissSeconds: m['autoDismissSeconds'] as int?,
      triggerDelay: m['triggerDelay']! as int,
    );
  }
}

/// Typed wrapper for events emitted on the message-event stream.
sealed class MessageEvent {
  const MessageEvent({required this.message});
  final InAppMessage message;
}

/// A lifecycle event (impression, click, dismiss) fired on an in-app message.
class MessageLifecycleEvent extends MessageEvent {
  const MessageLifecycleEvent({
    required super.message,
    required this.eventType,
    this.buttonId,
  });

  final String eventType;
  final String? buttonId;
}

/// A CTA button tap on an in-app message.
class MessageButtonAction extends MessageEvent {
  const MessageButtonAction({
    required super.message,
    required this.button,
  });

  final MessageButton button;
}

/// A button with `action="custom_event"` was tapped.
class MessageCustomEvent extends MessageEvent {
  const MessageCustomEvent({
    required super.message,
    required this.eventName,
  });

  final String eventName;
}

// ─── Private helpers ─────────────────────────────────────────────────────────

Map<String, Object?>? _coerceMap(Map<Object?, Object?>? input) {
  if (input == null) return null;
  final out = <String, Object?>{};
  for (final entry in input.entries) {
    final k = entry.key;
    if (k is String) out[k] = entry.value;
  }
  return out;
}

Map<String, Object?>? _coerceNestedMap(Object? input) {
  if (input is! Map) return null;
  return _coerceMap(input.cast<Object?, Object?>());
}

/// One frame of a push campaign's carousel.
///
/// No push provider carries a carousel, so the server sends the slides as data
/// and the client renders them. A build that ignores them shows an ordinary
/// notification — never nothing.
class PushCarouselSlide {
  const PushCarouselSlide({
    required this.imageUrl,
    this.caption,
    this.deepLinkUrl,
  });

  final String imageUrl;
  final String? caption;

  /// Where this slide leads. Null means the campaign's own deep link, so a
  /// carousel telling one story needs only that one.
  final String? deepLinkUrl;

  /// Built from a decoded payload entry, which crosses a platform channel and
  /// may hold anything — a value of the wrong type is treated as absent rather
  /// than throwing part-way through building a list.
  factory PushCarouselSlide.fromMap(Map<Object?, Object?> map) {
    String? optional(Object? value) =>
        value is String && value.isNotEmpty ? value : null;

    return PushCarouselSlide(
      imageUrl: optional(map['imageUrl']) ?? '',
      caption: optional(map['caption']),
      deepLinkUrl: optional(map['deepLinkUrl']),
    );
  }
}

/// A countdown carried by a push campaign, rendered by the client.
class PushTimer {
  const PushTimer({required this.endsAt, this.expiredTitle, this.expiredBody});

  final DateTime endsAt;

  /// Copy to show once the countdown has passed. Null means the campaign's own.
  final String? expiredTitle;
  final String? expiredBody;

  /// Whether the countdown has already run out, which is ordinary rather than
  /// exceptional: a notification can sit undelivered longer than it lasts.
  bool get hasExpired => DateTime.now().isAfter(endsAt);

  /// Returns null when `endsAt` is missing or unparseable — a countdown to an
  /// unknown moment is worse than none.
  static PushTimer? fromMap(Map<Object?, Object?> map) {
    final rawEndsAt = map['endsAt'];
    if (rawEndsAt is! String) return null;
    final endsAt = DateTime.tryParse(rawEndsAt);
    if (endsAt == null) return null;

    String? optional(Object? value) =>
        value is String && value.isNotEmpty ? value : null;

    return PushTimer(
      endsAt: endsAt,
      expiredTitle: optional(map['expiredTitle']),
      expiredBody: optional(map['expiredBody']),
    );
  }
}
