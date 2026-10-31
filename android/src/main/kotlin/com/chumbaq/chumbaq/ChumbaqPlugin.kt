package com.chumbaq.chumbaq

import android.content.Context
import com.chumbaq.banners.ChumbaqBanners
import com.chumbaq.messages.ChumbaqMessages
import com.chumbaq.messages.MessageListener
import com.chumbaq.messages.model.InAppMessage
import com.chumbaq.messages.model.MessageButton
import com.chumbaq.push.ChumbaqPush
import com.chumbaq.sdk.Chumbaq
import com.chumbaq.sdk.ChumbaqConfig
import com.chumbaq.sdk.deeplink.DeepLinkListener
import com.chumbaq.sdk.internal.util.LogLevel
import com.chumbaq.sdk.model.DeepLinkResult
import com.chumbaq.sdk.model.DeferredMatchResult
import com.chumbaq.sdk.model.ChumbaqError
import com.chumbaq.sdk.model.IdentifyParams
import com.chumbaq.sdk.model.IdentifyResult
import com.chumbaq.sdk.model.TrackConversionParams
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import android.os.Handler
import android.os.Looper

/**
 * Flutter plugin bridge for the Chumbaq Android SDK.
 *
 * This class is a *thin forwarding layer*. It holds NO business logic —
 * every call is forwarded to the already-tested native SDK objects
 * (`Chumbaq`, `ChumbaqPush`, `ChumbaqBanners`, `ChumbaqMessages`).
 *
 * Wiring:
 *   - Pigeon HostApis  (method calls)  — [ChumbaqHostApi], [ChumbaqPushHostApi],
 *     [ChumbaqBannersHostApi], [ChumbaqMessagesHostApi]
 *   - EventChannels    (broadcast streams)
 *       * com.chumbaq.chumbaq/deep_links     — [DeepLinkResult]s
 *       * com.chumbaq.chumbaq/push_tokens    — FCM token strings, republished
 *         by [ChumbaqFlutterMessagingService] on a Firebase token refresh
 *       * com.chumbaq.chumbaq/message_events — in-app message interactions
 *   - PlatformViewFactory  (native UI)
 *       * com.chumbaq.chumbaq/banner_carousel — embeds [com.chumbaq.banners.ui.BannerCarouselView]
 */
class ChumbaqPlugin :
    FlutterPlugin,
    ChumbaqHostApi,
    ChumbaqPushHostApi,
    ChumbaqBannersHostApi,
    ChumbaqMessagesHostApi {

    private lateinit var applicationContext: Context

    // Scope for bridging suspend SDK calls into Pigeon's callback-style handlers.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // EventSinks must be fed from the main thread, but the SDK's listeners
    // fire on whichever thread did the work.
    //
    // `by lazy` and not a field initializer: Looper.getMainLooper() is null
    // under a plain JVM unit test, so constructing the Handler eagerly would
    // make the whole class unconstructible there. Overridable for the same
    // reason — a test substitutes an inline dispatch.
    internal var postToMain: (Runnable) -> Unit = { mainHandler.post(it) }
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    // Stream machinery
    private var deepLinkEventSink: EventChannel.EventSink? = null
    private var pushTokenEventSink: EventChannel.EventSink? = null
    private var messageEventSink: EventChannel.EventSink? = null

    // Track whether the Dart side has subscribed (start*Stream was called).
    private var deepLinkStreamActive = false
    private var tokenStreamActive = false

    // The observer that forwards republished FCM tokens to Flutter.
    //
    // Registered with ChumbaqFlutterMessagingService rather than with the
    // native SDK: ChumbaqPush.onTokenRefresh is internal to that module, and
    // the service's override point is the only public hook on a refresh.
    private val tokenRefreshObserver =
        ChumbaqFlutterMessagingService.TokenRefreshObserver { token ->
            postToMain { pushTokenEventSink?.success(token) }
        }

    // The listener that forwards native DeepLinkResults to Flutter.
    //
    // EventChannels use the Standard codec (no Pigeon schema), so we send a
    // Map<String, Any?> keyed by field name. The Dart facade decodes it back
    // into a DeepLinkResult via DeepLinkResult._fromEventMap.
    private val deepLinkListener = DeepLinkListener { result ->
        postToMain {
            deepLinkEventSink?.success(result.toEventMap())
        }
    }

    // The listener that forwards in-app message events to Flutter.
    private val messageListener = object : MessageListener {
        override fun onMessageEvent(message: InAppMessage, eventType: String, buttonId: String?) {
            postToMain {
                messageEventSink?.success(
                    mapOf(
                        "type" to "message_event",
                        "message" to message.toEventMap(),
                        "eventType" to eventType,
                        "buttonId" to buttonId,
                    ),
                )
            }
        }

        override fun onButtonAction(message: InAppMessage, button: MessageButton) {
            postToMain {
                messageEventSink?.success(
                    mapOf(
                        "type" to "button_action",
                        "message" to message.toEventMap(),
                        "button" to button.toEventMap(),
                    ),
                )
            }
        }

        override fun onCustomEvent(message: InAppMessage, eventName: String) {
            postToMain {
                messageEventSink?.success(
                    mapOf(
                        "type" to "custom_event",
                        "message" to message.toEventMap(),
                        "eventName" to eventName,
                    ),
                )
            }
        }
    }

    // ── Plugin lifecycle ───────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        val messenger = binding.binaryMessenger

        // Register all four Pigeon HostApis on the same plugin instance.
        ChumbaqHostApi.setUp(messenger, this)
        ChumbaqPushHostApi.setUp(messenger, this)
        ChumbaqBannersHostApi.setUp(messenger, this)
        ChumbaqMessagesHostApi.setUp(messenger, this)

        // Deep link stream
        EventChannel(messenger, "com.chumbaq.chumbaq/deep_links").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    deepLinkEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    deepLinkEventSink = null
                }
            },
        )

        // Push token stream — fed by [tokenRefreshObserver] once the Dart
        // side calls startTokenStream.
        EventChannel(messenger, "com.chumbaq.chumbaq/push_tokens").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    pushTokenEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    pushTokenEventSink = null
                }
            },
        )

        // Message events stream
        EventChannel(messenger, "com.chumbaq.chumbaq/message_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    messageEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    messageEventSink = null
                }
            },
        )

        // PlatformView — native BannerCarouselView embedded inside a Flutter widget.
        binding.platformViewRegistry.registerViewFactory(
            "com.chumbaq.chumbaq/banner_carousel",
            BannerCarouselViewFactory(),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ChumbaqHostApi.setUp(binding.binaryMessenger, null)
        ChumbaqPushHostApi.setUp(binding.binaryMessenger, null)
        ChumbaqBannersHostApi.setUp(binding.binaryMessenger, null)
        ChumbaqMessagesHostApi.setUp(binding.binaryMessenger, null)

        if (deepLinkStreamActive) {
            runCatching { Chumbaq.setDeepLinkListener(null) }
            deepLinkStreamActive = false
        }
        // The observer list is static and outlives the engine, so leaving the
        // observer registered would leak this plugin and push tokens into a
        // sink that is about to be nulled.
        stopTokenStream()
        runCatching { ChumbaqMessages.setMessageListener(null) }

        deepLinkEventSink = null
        pushTokenEventSink = null
        messageEventSink = null

        scope.cancel()
    }

    // ──────────────────────────────────────────────────────────────────────
    // ChumbaqHostApi — forwards to com.chumbaq.sdk.Chumbaq
    // ──────────────────────────────────────────────────────────────────────

    override fun initialize(config: ChumbaqConfigDto) {
        val nativeConfig = config.toNativeConfig()
        Chumbaq.init(applicationContext, nativeConfig)
    }

    override fun isInitialized(): Boolean = Chumbaq.isInitialized

    override fun distinctId(): String = Chumbaq.distinctId

    override fun deviceFingerprint(): String = Chumbaq.deviceFingerprint

    override fun identify(
        params: IdentifyParamsDto,
        callback: (Result<IdentifyResultDto>) -> Unit,
    ) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { Chumbaq.identify(params.toNativeParams()) }
            }
                .onSuccess { callback(Result.success(it.toDto())) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun track(eventName: String, properties: Map<String?, Any?>?) {
        @Suppress("UNCHECKED_CAST")
        val safeProps = properties
            ?.filterKeys { it != null }
            ?.mapKeys { it.key as String }
            ?.filterValues { it != null }
            ?.mapValues { it.value as Any }
        Chumbaq.track(eventName, safeProps)
    }

    override fun trackConversion(params: TrackConversionParamsDto) {
        Chumbaq.trackConversion(params.toNativeParams())
    }

    override fun trackRevenue(amount: Double, currency: String) {
        Chumbaq.trackRevenue(amount, currency)
    }

    override fun matchDeferredDeepLink(callback: (Result<DeferredMatchResultDto>) -> Unit) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { Chumbaq.matchDeferredDeepLink() }
            }
                .onSuccess { callback(Result.success(it.toDto())) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun getAttributedShortCode(): String? = Chumbaq.getAttributedShortCode()

    override fun getAttributedLinkId(): String? = Chumbaq.getAttributedLinkId()

    override fun reset() = Chumbaq.reset()

    override fun flush(callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { Chumbaq.flush() }
            }
                .onSuccess { callback(Result.success(Unit)) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun startDeepLinkStream() {
        if (!deepLinkStreamActive) {
            Chumbaq.setDeepLinkListener(deepLinkListener)
            deepLinkStreamActive = true
        }
    }

    override fun stopDeepLinkStream() {
        if (deepLinkStreamActive) {
            Chumbaq.setDeepLinkListener(null)
            deepLinkStreamActive = false
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // ChumbaqPushHostApi — forwards to com.chumbaq.push.ChumbaqPush
    // ──────────────────────────────────────────────────────────────────────

    override fun initialize() {
        ChumbaqPush.init(applicationContext)
    }

    override fun isPushInitialized(): Boolean = ChumbaqPush.isInitialized

    override fun isRegistered(): Boolean = ChumbaqPush.isRegistered

    override fun registerToken(token: String, callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { ChumbaqPush.registerToken(token) }
            }
                .onSuccess { callback(Result.success(Unit)) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun registerMiPushToken(regId: String, callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { ChumbaqPush.registerMiPushToken(regId) }
            }
                .onSuccess { callback(Result.success(Unit)) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun unregisterToken(callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { ChumbaqPush.unregisterToken() }
            }
                .onSuccess { callback(Result.success(Unit)) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun startTokenStream() {
        if (!tokenStreamActive) {
            ChumbaqFlutterMessagingService.addObserver(tokenRefreshObserver)
            tokenStreamActive = true
        }
    }

    override fun stopTokenStream() {
        if (tokenStreamActive) {
            ChumbaqFlutterMessagingService.removeObserver(tokenRefreshObserver)
            tokenStreamActive = false
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // ChumbaqBannersHostApi — forwards to com.chumbaq.banners.ChumbaqBanners
    // ──────────────────────────────────────────────────────────────────────

    override fun loadBanners(
        categoryId: String,
        callback: (Result<BannerCategoryDto>) -> Unit,
    ) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { ChumbaqBanners.loadBanners(categoryId) }
            }
                .onSuccess { callback(Result.success(it.toDto())) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun clearCache() = ChumbaqBanners.clearCache()

    // ──────────────────────────────────────────────────────────────────────
    // ChumbaqMessagesHostApi — forwards to com.chumbaq.messages.ChumbaqMessages
    // ──────────────────────────────────────────────────────────────────────

    override fun onAppOpen() {
        ChumbaqMessages.onAppOpen(applicationContext)
    }

    override fun onScreenView(screen: String) {
        ChumbaqMessages.onScreenView(applicationContext, screen)
    }

    override fun onEvent(event: String) {
        ChumbaqMessages.onEvent(applicationContext, event)
    }

    override fun startMessageEventStream() {
        ChumbaqMessages.setMessageListener(messageListener)
    }

    override fun stopMessageEventStream() {
        ChumbaqMessages.setMessageListener(null)
    }
}

// =============================================================================
// Conversion helpers: Native SDK types ⇄ Pigeon DTOs
// =============================================================================

private fun ChumbaqConfigDto.toNativeConfig(): ChumbaqConfig {
    val builder = ChumbaqConfig.Builder(
        baseUrl = baseUrl,
        apiKey = apiKey,
        projectId = projectId,
    )
        .logLevel(logLevel.toNativeLogLevel())
        .flushInterval(flushIntervalSeconds.toInt())
        .maxQueueSize(maxQueueSize.toInt())
        .maxRetries(maxRetries.toInt())
        .sessionTimeout(sessionTimeoutSeconds.toInt())
        .enableAutoSessionTracking(enableAutoSessionTracking)
        .enableAutoDeviceInfo(enableAutoDeviceInfo)
        .deepLinkHosts(deepLinkHosts)

    customScheme?.let { builder.customScheme(it) }
    return builder.build()
}

private fun ChumbaqLogLevel.toNativeLogLevel(): LogLevel = when (this) {
    ChumbaqLogLevel.NONE -> LogLevel.NONE
    ChumbaqLogLevel.ERROR -> LogLevel.ERROR
    ChumbaqLogLevel.WARN -> LogLevel.WARN
    ChumbaqLogLevel.INFO -> LogLevel.INFO
    ChumbaqLogLevel.DEBUG -> LogLevel.DEBUG
    ChumbaqLogLevel.VERBOSE -> LogLevel.VERBOSE
}

private fun IdentifyParamsDto.toNativeParams(): IdentifyParams {
    val b = IdentifyParams.Builder()
    distinctId?.let { b.distinctId(it) }
    externalUserId?.let { b.externalUserId(it) }
    firstName?.let { b.firstName(it) }
    lastName?.let { b.lastName(it) }
    phone?.let { b.phone(it) }
    avatar?.let { b.avatar(it) }
    locale?.let { b.locale(it) }
    language?.let { b.language(it) }
    appVersion?.let { b.appVersion(it) }
    appBuild?.let { b.appBuild(it) }
    traits?.sanitizeMap()?.let { b.traits(it) }
    utmSource?.let { b.utmSource(it) }
    utmMedium?.let { b.utmMedium(it) }
    utmCampaign?.let { b.utmCampaign(it) }
    utmContent?.let { b.utmContent(it) }
    utmTerm?.let { b.utmTerm(it) }
    installSource?.let { b.installSource(it) }
    installCampaign?.let { b.installCampaign(it) }
    emailOptIn?.let { b.emailOptIn(it) }
    smsOptIn?.let { b.smsOptIn(it) }
    pushOptIn?.let { b.pushOptIn(it) }
    gdprConsent?.let { b.gdprConsent(it) }
    doNotTrack?.let { b.doNotTrack(it) }
    return b.build()
}

private fun IdentifyResult.toDto(): IdentifyResultDto = IdentifyResultDto(
    id = id,
    projectId = projectId,
    distinctId = distinctId,
    externalUserId = externalUserId,
    deviceFingerprint = deviceFingerprint,
    platform = platform,
)

private fun DeepLinkResult.toDto(): DeepLinkResultDto = DeepLinkResultDto(
    url = url,
    shortCode = shortCode,
    params = params?.mapKeys { it.key as String? },
    isDeferred = isDeferred,
    linkId = linkId,
)

private fun DeferredMatchResult.toDto(): DeferredMatchResultDto = DeferredMatchResultDto(
    matched = matched,
    linkId = linkId,
    shortCode = shortCode,
    params = params?.mapKeys { it.key as String? },
)

private fun TrackConversionParamsDto.toNativeParams(): TrackConversionParams =
    TrackConversionParams(
        eventType = eventType,
        shortCode = shortCode,
        linkId = linkId,
        externalUserId = externalUserId,
        metadata = metadata?.sanitizeMap(),
    )

private fun com.chumbaq.banners.model.Banner.toDto(): BannerDto = BannerDto(
    id = id,
    title = title,
    imageUrl = imageUrl,
    clickUrl = clickUrl,
    ctaText = ctaText,
    sortOrder = sortOrder.toLong(),
    isActive = isActive,
    metadata = metadata?.mapKeys { it.key as String? },
)

private fun com.chumbaq.banners.model.BannerCategory.toDto(): BannerCategoryDto = BannerCategoryDto(
    id = id,
    name = name,
    layout = layout,
    aspectRatio = aspectRatio,
    autoRotate = autoRotate,
    rotationInterval = rotationInterval.toLong(),
    heading = heading,
    backgroundColor = backgroundColor,
    padding = padding.toLong(),
    banners = banners.map { it.toDto() },
)

private fun InAppMessage.toDto(): InAppMessageDto = InAppMessageDto(
    id = id,
    messageType = messageType,
    title = title,
    body = body,
    imageUrl = imageUrl,
    imagePosition = imagePosition,
    buttons = buttons?.map { it.toDto() },
    theme = theme?.toDto(),
    dismissOnTapOutside = dismissOnTapOutside,
    autoDismissSeconds = autoDismissSeconds?.toLong(),
    triggerDelay = triggerDelay.toLong(),
)

private fun MessageButton.toDto(): MessageButtonDto = MessageButtonDto(
    id = id,
    text = text,
    action = action,
    actionUrl = actionUrl,
    actionEvent = actionEvent,
    style = style,
)

private fun com.chumbaq.messages.model.MessageTheme.toDto(): MessageThemeDto = MessageThemeDto(
    backgroundColor = backgroundColor,
    textColor = textColor,
    titleColor = titleColor,
    buttonPrimaryColor = buttonPrimaryColor,
    buttonSecondaryColor = buttonSecondaryColor,
    overlayColor = overlayColor,
    borderRadius = borderRadius?.toLong(),
    animation = animation,
)

/**
 * Pigeon delivers maps as `Map<String?, Any?>?` but the Kotlin SDK APIs
 * require `Map<String, Any>`. Strip null keys/values so calling code can pass
 * the sanitized map straight through.
 */
private fun Map<String?, Any?>.sanitizeMap(): Map<String, Any> =
    this.filterKeys { it != null }
        .filterValues { it != null }
        .mapKeys { it.key as String }
        .mapValues { it.value as Any }

// ── EventChannel serialization (Standard codec, not Pigeon) ──────────────────
//
// These helpers produce Map<String, Any?> payloads that the Standard codec
// can encode without knowing anything about Pigeon. The Dart facade has a
// matching `.fromEventMap(...)` for each type.

private fun DeepLinkResult.toEventMap(): Map<String, Any?> = mapOf(
    "url" to url,
    "shortCode" to shortCode,
    "params" to params,
    "isDeferred" to isDeferred,
    "linkId" to linkId,
)

private fun InAppMessage.toEventMap(): Map<String, Any?> = mapOf(
    "id" to id,
    "messageType" to messageType,
    "title" to title,
    "body" to body,
    "imageUrl" to imageUrl,
    "imagePosition" to imagePosition,
    "buttons" to buttons?.map { it.toEventMap() },
    "theme" to theme?.toEventMap(),
    "dismissOnTapOutside" to dismissOnTapOutside,
    "autoDismissSeconds" to autoDismissSeconds,
    "triggerDelay" to triggerDelay,
)

private fun MessageButton.toEventMap(): Map<String, Any?> = mapOf(
    "id" to id,
    "text" to text,
    "action" to action,
    "actionUrl" to actionUrl,
    "actionEvent" to actionEvent,
    "style" to style,
)

private fun com.chumbaq.messages.model.MessageTheme.toEventMap(): Map<String, Any?> = mapOf(
    "backgroundColor" to backgroundColor,
    "textColor" to textColor,
    "titleColor" to titleColor,
    "buttonPrimaryColor" to buttonPrimaryColor,
    "buttonSecondaryColor" to buttonSecondaryColor,
    "overlayColor" to overlayColor,
    "borderRadius" to borderRadius,
    "animation" to animation,
)

/**
 * Rewrap native [ChumbaqError] and related exceptions as a [FlutterError]
 * so the Dart side receives a typed [PlatformException] with a stable code.
 *
 * Codes:
 *   NOT_INITIALIZED   — SDK not initialised yet
 *   INVALID_CONFIG    — bad config fields (from Kotlin require(...) checks)
 *   NETWORK_ERROR     — transport failure
 *   API_ERROR:<http>  — server-side failure; HTTP status suffixed
 *   UNKNOWN           — anything else; message preserved
 */
private fun Throwable.toFlutterError(): FlutterError = when (this) {
    is ChumbaqError.NotInitialized ->
        FlutterError("NOT_INITIALIZED", message ?: "Chumbaq SDK not initialized", null)

    is ChumbaqError.InvalidConfig ->
        FlutterError("INVALID_CONFIG", message ?: "Invalid Chumbaq configuration", null)

    is ChumbaqError.NetworkError ->
        FlutterError(
            "NETWORK_ERROR",
            message ?: "Network error",
            mapOf("statusCode" to statusCode),
        )

    is ChumbaqError.ApiError ->
        FlutterError(
            "API_ERROR:$statusCode",
            message ?: "Chumbaq API error",
            mapOf("statusCode" to statusCode, "responseBody" to responseBody),
        )

    is IllegalStateException ->
        FlutterError("INVALID_STATE", message ?: "Invalid SDK state", null)

    is IllegalArgumentException ->
        FlutterError("INVALID_ARGUMENT", message ?: "Invalid argument", null)

    else ->
        FlutterError("UNKNOWN", message ?: this::class.java.simpleName, null)
}
