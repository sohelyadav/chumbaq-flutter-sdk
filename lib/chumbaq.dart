/// Chumbaq Flutter SDK — deep linking, attribution, events, push notifications,
/// in-app banners, and in-app messages.
///
/// This package is a thin Flutter wrapper over the native Chumbaq Android SDK
/// (and, when available, the Chumbaq iOS SDK). All business logic — offline
/// event queueing, session tracking, HTTP retries, install referrer parsing,
/// FCM integration — lives in native code, so Flutter users get exactly the
/// same behavior as native users.
///
/// Entry points:
///   * [Chumbaq] — core SDK (init, identify, track, deep links)
///   * [ChumbaqPush] — push notification registration
///   * [ChumbaqBanners] + [ChumbaqBannerCarousel] — in-app banner carousel
///   * [ChumbaqMessages] — in-app message trigger points and event stream
///   * [ChumbaqDiagnostics] — opt-in reporting of swallowed failures
library;

// Core entry point.
export 'src/chumbaq_core.dart' show Chumbaq;

// Optional modules.
export 'src/chumbaq_push.dart' show ChumbaqPush;
export 'src/chumbaq_banners.dart' show ChumbaqBanners, ChumbaqBannerCarousel;
export 'src/chumbaq_messages.dart' show ChumbaqMessages;

// Debugging aid, off by default.
export 'src/chumbaq_diagnostics.dart' show ChumbaqDiagnostics;

// Public models and builders.
export 'src/chumbaq_models.dart'
    show
        ChumbaqLogLevel,
        ChumbaqConfig,
        ChumbaqConfigBuilder,
        IdentifyParams,
        IdentifyParamsBuilder,
        IdentifyResult,
        DeepLinkResult,
        DeferredMatchResult,
        TrackConversionParams,
        ChumbaqBanner,
        BannerCategory,
        MessageButton,
        MessageTheme,
        InAppMessage,
        MessageEvent,
        MessageLifecycleEvent,
        MessageButtonAction,
        MessageCustomEvent,
        PushAction,
        PushCarouselSlide,
        PushTimer;

// Typed error hierarchy.
export 'src/chumbaq_error.dart'
    show
        ChumbaqError,
        ChumbaqNotInitialized,
        ChumbaqInvalidConfig,
        ChumbaqNetworkError,
        ChumbaqApiError,
        ChumbaqUnknownError;
