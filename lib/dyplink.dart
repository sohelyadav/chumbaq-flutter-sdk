/// Dyplink Flutter SDK — deep linking, attribution, events, push notifications,
/// in-app banners, and in-app messages.
///
/// This package is a thin Flutter wrapper over the native Dyplink Android SDK
/// (and, when available, the Dyplink iOS SDK). All business logic — offline
/// event queueing, session tracking, HTTP retries, install referrer parsing,
/// FCM integration — lives in native code, so Flutter users get exactly the
/// same behavior as native users.
///
/// Entry points:
///   * [Dyplink] — core SDK (init, identify, track, deep links)
///   * [DyplinkPush] — push notification registration
///   * [DyplinkBanners] + [DyplinkBannerCarousel] — in-app banner carousel
///   * [DyplinkMessages] — in-app message trigger points and event stream
library;

// Core entry point.
export 'src/dyplink_core.dart' show Dyplink;

// Optional modules.
export 'src/dyplink_push.dart' show DyplinkPush;
export 'src/dyplink_banners.dart' show DyplinkBanners, DyplinkBannerCarousel;
export 'src/dyplink_messages.dart' show DyplinkMessages;

// Public models and builders.
export 'src/dyplink_models.dart'
    show
        DyplinkLogLevel,
        DyplinkConfig,
        DyplinkConfigBuilder,
        IdentifyParams,
        IdentifyParamsBuilder,
        IdentifyResult,
        DeepLinkResult,
        DeferredMatchResult,
        TrackConversionParams,
        DyplinkBanner,
        BannerCategory,
        MessageButton,
        MessageTheme,
        InAppMessage,
        MessageEvent,
        MessageLifecycleEvent,
        MessageButtonAction,
        MessageCustomEvent,
        PushCarouselSlide,
        PushTimer;

// Typed error hierarchy.
export 'src/dyplink_error.dart'
    show
        DyplinkError,
        DyplinkNotInitialized,
        DyplinkInvalidConfig,
        DyplinkNetworkError,
        DyplinkApiError,
        DyplinkUnknownError;
