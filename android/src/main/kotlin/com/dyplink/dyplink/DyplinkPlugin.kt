package com.dyplink.dyplink

import android.content.Context
import com.dyplink.banners.DyplinkBanners
import com.dyplink.messages.DyplinkMessages
import com.dyplink.messages.MessageListener
import com.dyplink.messages.model.InAppMessage
import com.dyplink.messages.model.MessageButton
import com.dyplink.push.DyplinkPush
import com.dyplink.sdk.Dyplink
import com.dyplink.sdk.DyplinkConfig
import com.dyplink.sdk.deeplink.DeepLinkListener
import com.dyplink.sdk.internal.util.LogLevel
import com.dyplink.sdk.model.DeepLinkResult
import com.dyplink.sdk.model.DeferredMatchResult
import com.dyplink.sdk.model.DyplinkError
import com.dyplink.sdk.model.IdentifyParams
import com.dyplink.sdk.model.IdentifyResult
import com.dyplink.sdk.model.TrackConversionParams
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
 * Flutter plugin bridge for the Dyplink Android SDK.
 *
 * This class is a *thin forwarding layer*. It holds NO business logic —
 * every call is forwarded to the already-tested native SDK objects
 * (`Dyplink`, `DyplinkPush`, `DyplinkBanners`, `DyplinkMessages`).
 *
 * Wiring:
 *   - Pigeon HostApis  (method calls)  — [DyplinkHostApi], [DyplinkPushHostApi],
 *     [DyplinkBannersHostApi], [DyplinkMessagesHostApi]
 *   - EventChannels    (broadcast streams)
 *       * com.dyplink.dyplink/deep_links     — [DeepLinkResult]s
 *       * com.dyplink.dyplink/push_tokens    — FCM token strings, republished
 *         by [DyplinkFlutterMessagingService] on a Firebase token refresh
 *       * com.dyplink.dyplink/message_events — in-app message interactions
 *   - PlatformViewFactory  (native UI)
 *       * com.dyplink.dyplink/banner_carousel — embeds [com.dyplink.banners.ui.BannerCarouselView]
 */
class DyplinkPlugin :
    FlutterPlugin,
    DyplinkHostApi,
    DyplinkPushHostApi,
    DyplinkBannersHostApi,
    DyplinkMessagesHostApi {

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
    // Registered with DyplinkFlutterMessagingService rather than with the
    // native SDK: DyplinkPush.onTokenRefresh is internal to that module, and
    // the service's override point is the only public hook on a refresh.
    private val tokenRefreshObserver =
        DyplinkFlutterMessagingService.TokenRefreshObserver { token ->
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
        DyplinkHostApi.setUp(messenger, this)
        DyplinkPushHostApi.setUp(messenger, this)
        DyplinkBannersHostApi.setUp(messenger, this)
        DyplinkMessagesHostApi.setUp(messenger, this)

        // Deep link stream
        EventChannel(messenger, "com.dyplink.dyplink/deep_links").setStreamHandler(
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
        EventChannel(messenger, "com.dyplink.dyplink/push_tokens").setStreamHandler(
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
        EventChannel(messenger, "com.dyplink.dyplink/message_events").setStreamHandler(
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
            "com.dyplink.dyplink/banner_carousel",
            BannerCarouselViewFactory(),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        DyplinkHostApi.setUp(binding.binaryMessenger, null)
        DyplinkPushHostApi.setUp(binding.binaryMessenger, null)
        DyplinkBannersHostApi.setUp(binding.binaryMessenger, null)
        DyplinkMessagesHostApi.setUp(binding.binaryMessenger, null)

        if (deepLinkStreamActive) {
            runCatching { Dyplink.setDeepLinkListener(null) }
            deepLinkStreamActive = false
        }
        // The observer list is static and outlives the engine, so leaving the
        // observer registered would leak this plugin and push tokens into a
        // sink that is about to be nulled.
        stopTokenStream()
        runCatching { DyplinkMessages.setMessageListener(null) }

        deepLinkEventSink = null
        pushTokenEventSink = null
        messageEventSink = null

        scope.cancel()
    }

    // ──────────────────────────────────────────────────────────────────────
    // DyplinkHostApi — forwards to com.dyplink.sdk.Dyplink
    // ──────────────────────────────────────────────────────────────────────

    override fun initialize(config: DyplinkConfigDto) {
        val nativeConfig = config.toNativeConfig()
        Dyplink.init(applicationContext, nativeConfig)
    }

    override fun isInitialized(): Boolean = Dyplink.isInitialized

    override fun distinctId(): String = Dyplink.distinctId

    override fun deviceFingerprint(): String = Dyplink.deviceFingerprint

    override fun identify(
        params: IdentifyParamsDto,
        callback: (Result<IdentifyResultDto>) -> Unit,
    ) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { Dyplink.identify(params.toNativeParams()) }
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
        Dyplink.track(eventName, safeProps)
    }

    override fun trackConversion(params: TrackConversionParamsDto) {
        Dyplink.trackConversion(params.toNativeParams())
    }

    override fun trackRevenue(amount: Double, currency: String) {
        Dyplink.trackRevenue(amount, currency)
    }

    override fun matchDeferredDeepLink(callback: (Result<DeferredMatchResultDto>) -> Unit) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { Dyplink.matchDeferredDeepLink() }
            }
                .onSuccess { callback(Result.success(it.toDto())) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun getAttributedShortCode(): String? = Dyplink.getAttributedShortCode()

    override fun getAttributedLinkId(): String? = Dyplink.getAttributedLinkId()

    override fun reset() = Dyplink.reset()

    override fun flush(callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { Dyplink.flush() }
            }
                .onSuccess { callback(Result.success(Unit)) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun startDeepLinkStream() {
        if (!deepLinkStreamActive) {
            Dyplink.setDeepLinkListener(deepLinkListener)
            deepLinkStreamActive = true
        }
    }

    override fun stopDeepLinkStream() {
        if (deepLinkStreamActive) {
            Dyplink.setDeepLinkListener(null)
            deepLinkStreamActive = false
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // DyplinkPushHostApi — forwards to com.dyplink.push.DyplinkPush
    // ──────────────────────────────────────────────────────────────────────

    override fun initialize() {
        DyplinkPush.init(applicationContext)
    }

    override fun isPushInitialized(): Boolean = DyplinkPush.isInitialized

    override fun isRegistered(): Boolean = DyplinkPush.isRegistered

    override fun registerToken(token: String, callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { DyplinkPush.registerToken(token) }
            }
                .onSuccess { callback(Result.success(Unit)) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun registerMiPushToken(regId: String, callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { DyplinkPush.registerMiPushToken(regId) }
            }
                .onSuccess { callback(Result.success(Unit)) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun unregisterToken(callback: (Result<Unit>) -> Unit) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { DyplinkPush.unregisterToken() }
            }
                .onSuccess { callback(Result.success(Unit)) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun startTokenStream() {
        if (!tokenStreamActive) {
            DyplinkFlutterMessagingService.addObserver(tokenRefreshObserver)
            tokenStreamActive = true
        }
    }

    override fun stopTokenStream() {
        if (tokenStreamActive) {
            DyplinkFlutterMessagingService.removeObserver(tokenRefreshObserver)
            tokenStreamActive = false
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // DyplinkBannersHostApi — forwards to com.dyplink.banners.DyplinkBanners
    // ──────────────────────────────────────────────────────────────────────

    override fun loadBanners(
        categoryId: String,
        callback: (Result<BannerCategoryDto>) -> Unit,
    ) {
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) { DyplinkBanners.loadBanners(categoryId) }
            }
                .onSuccess { callback(Result.success(it.toDto())) }
                .onFailure { callback(Result.failure(it.toFlutterError())) }
        }
    }

    override fun clearCache() = DyplinkBanners.clearCache()

    // ──────────────────────────────────────────────────────────────────────
    // DyplinkMessagesHostApi — forwards to com.dyplink.messages.DyplinkMessages
    // ──────────────────────────────────────────────────────────────────────

    override fun onAppOpen() {
        DyplinkMessages.onAppOpen(applicationContext)
    }

    override fun onScreenView(screen: String) {
        DyplinkMessages.onScreenView(applicationContext, screen)
    }

    override fun onEvent(event: String) {
        DyplinkMessages.onEvent(applicationContext, event)
    }

    override fun startMessageEventStream() {
        DyplinkMessages.setMessageListener(messageListener)
    }

    override fun stopMessageEventStream() {
        DyplinkMessages.setMessageListener(null)
    }
}

// =============================================================================
// Conversion helpers: Native SDK types ⇄ Pigeon DTOs
// =============================================================================

private fun DyplinkConfigDto.toNativeConfig(): DyplinkConfig {
    val builder = DyplinkConfig.Builder(
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

private fun DyplinkLogLevel.toNativeLogLevel(): LogLevel = when (this) {
    DyplinkLogLevel.NONE -> LogLevel.NONE
    DyplinkLogLevel.ERROR -> LogLevel.ERROR
    DyplinkLogLevel.WARN -> LogLevel.WARN
    DyplinkLogLevel.INFO -> LogLevel.INFO
    DyplinkLogLevel.DEBUG -> LogLevel.DEBUG
    DyplinkLogLevel.VERBOSE -> LogLevel.VERBOSE
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

private fun com.dyplink.banners.model.Banner.toDto(): BannerDto = BannerDto(
    id = id,
    title = title,
    imageUrl = imageUrl,
    clickUrl = clickUrl,
    ctaText = ctaText,
    sortOrder = sortOrder.toLong(),
    isActive = isActive,
    metadata = metadata?.mapKeys { it.key as String? },
)

private fun com.dyplink.banners.model.BannerCategory.toDto(): BannerCategoryDto = BannerCategoryDto(
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

private fun com.dyplink.messages.model.MessageTheme.toDto(): MessageThemeDto = MessageThemeDto(
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

private fun com.dyplink.messages.model.MessageTheme.toEventMap(): Map<String, Any?> = mapOf(
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
 * Rewrap native [DyplinkError] and related exceptions as a [FlutterError]
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
    is DyplinkError.NotInitialized ->
        FlutterError("NOT_INITIALIZED", message ?: "Dyplink SDK not initialized", null)

    is DyplinkError.InvalidConfig ->
        FlutterError("INVALID_CONFIG", message ?: "Invalid Dyplink configuration", null)

    is DyplinkError.NetworkError ->
        FlutterError(
            "NETWORK_ERROR",
            message ?: "Network error",
            mapOf("statusCode" to statusCode),
        )

    is DyplinkError.ApiError ->
        FlutterError(
            "API_ERROR:$statusCode",
            message ?: "Dyplink API error",
            mapOf("statusCode" to statusCode, "responseBody" to responseBody),
        )

    is IllegalStateException ->
        FlutterError("INVALID_STATE", message ?: "Invalid SDK state", null)

    is IllegalArgumentException ->
        FlutterError("INVALID_ARGUMENT", message ?: "Invalid argument", null)

    else ->
        FlutterError("UNKNOWN", message ?: this::class.java.simpleName, null)
}
