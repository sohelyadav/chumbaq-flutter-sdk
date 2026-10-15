import DyplinkBanners
import DyplinkCore
import DyplinkMessages
import DyplinkPush
import Flutter
import UIKit

/// Flutter plugin bridge for the Dyplink iOS SDK.
///
/// This class is a *thin forwarding layer*, structured method-for-method like
/// `android/src/main/kotlin/com/dyplink/dyplink/DyplinkPlugin.kt` so the two
/// bridges read side by side. It holds NO business logic — every call is
/// forwarded to the already-tested native SDK singletons (`Dyplink`,
/// `DyplinkPush`, `DyplinkBanners`, `DyplinkMessages`).
///
/// Wiring:
///   - Pigeon HostApis  (method calls)  — [DyplinkHostApi], [DyplinkPushHostApi],
///     [DyplinkBannersHostApi], [DyplinkMessagesHostApi]
///   - EventChannels    (broadcast streams)
///       * com.dyplink.dyplink/deep_links     — `DeepLinkResult`s
///       * com.dyplink.dyplink/push_tokens    — installed for symmetry with
///         Android but never emits: iOS has no token-refresh callback, the
///         host app owns APNs registration. See `startTokenStream`.
///       * com.dyplink.dyplink/message_events — in-app message interactions
///   - URL intake, registered on both delegate paths because which one iOS
///     uses depends on whether the host app declares a scene manifest:
///       * `FlutterSceneLifeCycleDelegate` — `scene(_:openURLContexts:)`,
///         `scene(_:continue:)`, and `scene(_:willConnectTo:options:)` for a
///         link that launched the app
///       * `FlutterApplicationLifeCycleDelegate` — `application(_:open:options:)`
///         and `application(_:continue:restorationHandler:)`, for an app
///         without scenes
///
/// Three Pigeon methods have no iOS counterpart and throw rather than
/// pretending: `startTokenStream`, `stopTokenStream` and
/// `registerMiPushToken`. The Dart facade gates all three to Android, so a
/// Flutter app never reaches them; they fail loudly for anything that calls
/// the channel directly.
///
/// `Dyplink.shared.handleCampaignDeepLink(url:)` is deliberately not wired
/// up. The destination of a tapped push notification is routed in pure Dart
/// (`DyplinkPush.reportNotificationClicked` → `Dyplink.emitDeepLink`), and
/// reporting the tap natively as well would count every click twice.
public class DyplinkPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate,
  DyplinkHostApi, DyplinkPushHostApi, DyplinkBannersHostApi, DyplinkMessagesHostApi
{

  // ── Stream machinery ───────────────────────────────────────────────────
  //
  // EventSinks must be fed from the platform thread, but the SDK's listeners
  // fire on whichever thread did the work — [EventSinkHolder] hops to main,
  // the way the Android bridge posts to the main looper.
  private let deepLinkSink = EventSinkHolder()
  private let pushTokenSink = EventSinkHolder()
  private let messageEventSink = EventSinkHolder()

  // Retained so the channels outlive `register(with:)`.
  private var eventChannels: [FlutterEventChannel] = []

  // Track whether the Dart side has subscribed (start*Stream was called).
  private var deepLinkStreamActive = false
  private var messageStreamActive = false

  /// Forwards in-app message events to Flutter.
  ///
  /// Owned by the plugin because `DyplinkMessages.messageListener` is a weak
  /// reference — a listener the plugin did not retain would be released
  /// immediately and the stream would simply never emit.
  private lazy var messageListener = MessageEventForwarder(sink: messageEventSink)

  /// A URL that arrived before `Dyplink.init` had run, and the event it
  /// produced once it did.
  ///
  /// Both exist because of the cold-start ordering: iOS hands the launch URL
  /// over as the scene connects, while Flutter is still booting, so
  /// `handleDeepLink` would be called on an uninitialized SDK and drop it
  /// ([pendingLaunchURL] holds it until `initialize`), and the app's own
  /// `Dyplink.deepLinks` subscriber usually appears a moment after
  /// `Dyplink.init` returns, so the replayed result has nowhere to go yet
  /// ([pendingDeepLinkEvent] holds that until the stream opens).
  ///
  /// Each is delivered at most once. The alternative is losing every deep
  /// link that launches the app, which looks exactly like a link that was
  /// never clicked.
  private var pendingLaunchURL: URL?
  private var pendingDeepLinkEvent: [String: Any]?

  /// The URL the app was launched with, until something delivers it again.
  ///
  /// iOS does not agree with itself here. Apple documents the launch URL as
  /// arriving in the scene's connection options *instead of* through
  /// `scene(_:openURLContexts:)`, but iOS 26 delivers it both ways — first in
  /// the connection options, then again through `openURLContexts` about a
  /// second later, once the scene activates. Taking only the first would lose
  /// the link on a version that behaves as documented; taking both reports
  /// every link that launches the app twice, which is two deep-link opens in
  /// the backend for one tap.
  ///
  /// So the launch URL is remembered and the next identical delivery — only
  /// the next one, and only while the app stays foregrounded — is dropped.
  /// Any genuine second arrival of the same link requires the app to be
  /// backgrounded first, and [sceneDidEnterBackground] clears this.
  private var launchURL: URL?

  // ── Plugin lifecycle ───────────────────────────────────────────────────

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let instance = DyplinkPlugin()

    // Register all four Pigeon HostApis on the same plugin instance.
    DyplinkHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
    DyplinkPushHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
    DyplinkBannersHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
    DyplinkMessagesHostApiSetup.setUp(binaryMessenger: messenger, api: instance)

    instance.installEventChannels(messenger: messenger)

    // Deep link intake. Both delegates: a scene-based host app (the current
    // Flutter template, which installs a `FlutterSceneDelegate`) routes URLs
    // through the scene, an app without a scene manifest through the app
    // delegate. iOS only ever calls one of the two.
    registrar.addSceneDelegate(instance)
    registrar.addApplicationDelegate(instance)

    // Both registrations above hold their delegates weakly; `publish` is what
    // keeps this instance alive for the engine's lifetime — and what gets
    // `detachFromEngine` called on teardown.
    registrar.publish(instance)
  }

  private func installEventChannels(messenger: FlutterBinaryMessenger) {
    // Deep link stream — fed by the listener [startDeepLinkStream] installs.
    let deepLinks = FlutterEventChannel(
      name: "com.dyplink.dyplink/deep_links", binaryMessenger: messenger)
    deepLinkSink.onAttach = { [weak self] in self?.flushPendingDeepLinkEvent() }
    deepLinks.setStreamHandler(deepLinkSink)

    // Push token stream — never emits on iOS, see [startTokenStream].
    let pushTokens = FlutterEventChannel(
      name: "com.dyplink.dyplink/push_tokens", binaryMessenger: messenger)
    pushTokens.setStreamHandler(pushTokenSink)

    // Message events stream.
    let messageEvents = FlutterEventChannel(
      name: "com.dyplink.dyplink/message_events", binaryMessenger: messenger)
    messageEvents.setStreamHandler(messageEventSink)

    eventChannels = [deepLinks, pushTokens, messageEvents]
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    DyplinkHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
    DyplinkPushHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
    DyplinkBannersHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
    DyplinkMessagesHostApiSetup.setUp(binaryMessenger: messenger, api: nil)

    // `Dyplink.shared` is a singleton that outlives the engine, so a
    // listener left installed would keep pushing into a sink that is about
    // to be torn down — and keep this plugin's sink holders alive with it.
    if deepLinkStreamActive {
      Dyplink.shared.onDeepLink = nil
      deepLinkStreamActive = false
    }
    if messageStreamActive {
      DyplinkMessages.shared.messageListener = nil
      messageStreamActive = false
    }

    for channel in eventChannels {
      channel.setStreamHandler(nil)
    }
    eventChannels.removeAll()

    deepLinkSink.detach()
    pushTokenSink.detach()
    messageEventSink.detach()

    pendingLaunchURL = nil
    pendingDeepLinkEvent = nil
    launchURL = nil
  }

  // ──────────────────────────────────────────────────────────────────────
  // DyplinkHostApi — forwards to DyplinkCore.Dyplink
  // ──────────────────────────────────────────────────────────────────────

  func initialize(config: DyplinkConfigDto) throws {
    let nativeConfig: DyplinkConfig
    do {
      nativeConfig = try config.toNativeConfig()
    } catch {
      // The Builder's validation — blank apiKey, non-positive flushInterval.
      throw error.toPigeonError()
    }
    Dyplink.shared.initialize(config: nativeConfig)
    // A URL that arrived while the SDK was still uninitialized is only
    // parseable now — the config carries the hosts and scheme to match it
    // against.
    replayPendingLaunchURL()
  }

  // Satisfies DyplinkHostApi only. The push module's equivalent is
  // `isPushInitialized()` below — see the Pigeon schema for why the two
  // cannot share a name on a class that implements both protocols.
  func isInitialized() throws -> Bool {
    return Dyplink.shared.isInitialized
  }

  func distinctId() throws -> String {
    try Self.requireCoreInitialized()
    return Dyplink.shared.distinctId
  }

  func deviceFingerprint() throws -> String {
    try Self.requireCoreInitialized()
    return Dyplink.shared.deviceFingerprint
  }

  func identify(
    params: IdentifyParamsDto,
    completion: @escaping (Result<IdentifyResultDto, Error>) -> Void
  ) {
    let nativeParams = params.toNativeParams()
    Task {
      do {
        let result = try await Dyplink.shared.identify(nativeParams)
        reply(completion, .success(result.toDto()))
      } catch {
        reply(completion, .failure(error.toPigeonError()))
      }
    }
  }

  func track(eventName: String, properties: [String?: Any?]?) throws {
    try Self.requireCoreInitialized()
    Dyplink.shared.track(eventName, properties: properties?.sanitized())
  }

  func trackConversion(params: TrackConversionParamsDto) throws {
    try Self.requireCoreInitialized()
    Dyplink.shared.trackConversion(params.toNativeParams())
  }

  func trackRevenue(amount: Double, currency: String) throws {
    try Self.requireCoreInitialized()
    Dyplink.shared.trackRevenue(amount, currency: currency)
  }

  func matchDeferredDeepLink(
    completion: @escaping (Result<DeferredMatchResultDto, Error>) -> Void
  ) {
    // Guarded rather than forwarded: an uninitialized SDK answers
    // `.unmatched`, which reads as "this install came from no link" — the
    // same answer a working match gives, for a completely different reason.
    do {
      try Self.requireCoreInitialized()
    } catch {
      reply(completion, .failure(error.toPigeonError()))
      return
    }
    Task {
      let result = await Dyplink.shared.matchDeferredDeepLink()
      reply(completion, .success(result.toDto()))
    }
  }

  func getAttributedShortCode() throws -> String? {
    return Dyplink.shared.getAttributedShortCode()
  }

  func getAttributedLinkId() throws -> String? {
    return Dyplink.shared.getAttributedLinkId()
  }

  func reset() throws {
    try Self.requireCoreInitialized()
    Dyplink.shared.reset()
  }

  func flush(completion: @escaping (Result<Void, Error>) -> Void) {
    do {
      try Self.requireCoreInitialized()
    } catch {
      reply(completion, .failure(error.toPigeonError()))
      return
    }
    Task {
      await Dyplink.shared.flush()
      reply(completion, .success(()))
    }
  }

  func startDeepLinkStream() throws {
    guard !deepLinkStreamActive else { return }
    // The closure captures the sink holder, not the plugin: `onDeepLink`
    // lives on a singleton, so capturing `self` here would keep the plugin
    // (and the engine's messenger with it) alive for the life of the process.
    let sink = deepLinkSink
    Dyplink.shared.onDeepLink = { result in
      sink.send(result.toEventMap())
    }
    deepLinkStreamActive = true
    flushPendingDeepLinkEvent()
  }

  func stopDeepLinkStream() throws {
    guard deepLinkStreamActive else { return }
    Dyplink.shared.onDeepLink = nil
    deepLinkStreamActive = false
  }

  // ──────────────────────────────────────────────────────────────────────
  // DyplinkPushHostApi — forwards to DyplinkPush.DyplinkPush
  // ──────────────────────────────────────────────────────────────────────

  // Note: this `initialize()` satisfies DyplinkPushHostApi (distinct from the
  // DyplinkHostApi.initialize(config:) above by signature).
  func initialize() throws {
    // The native module asserts this instead of throwing, which would take
    // the whole app down on a Dart-side ordering mistake.
    try Self.requireCoreInitialized()
    DyplinkPush.shared.initialize()
  }

  func isPushInitialized() throws -> Bool {
    return DyplinkPush.shared.isInitialized
  }

  func isRegistered() throws -> Bool {
    return DyplinkPush.shared.isRegistered
  }

  func registerToken(token: String, completion: @escaping (Result<Void, Error>) -> Void) {
    Task {
      do {
        try await DyplinkPush.shared.registerToken(token)
        reply(completion, .success(()))
      } catch {
        reply(completion, .failure(error.toPigeonError()))
      }
    }
  }

  func registerMiPushToken(regId: String, completion: @escaping (Result<Void, Error>) -> Void) {
    // Mi Push is a Xiaomi delivery channel, and Xiaomi devices are Android
    // devices — there is nothing on iOS to register, and no iOS SDK API to
    // register it with.
    reply(
      completion,
      .failure(
        Self.unsupportedOnIOS(
          "DyplinkPush.registerMiPushToken",
          because: "Mi Push is a Xiaomi/Android delivery channel"
        )))
  }

  func unregisterToken(completion: @escaping (Result<Void, Error>) -> Void) {
    Task {
      do {
        try await DyplinkPush.shared.unregisterToken()
        reply(completion, .success(()))
      } catch {
        reply(completion, .failure(error.toPigeonError()))
      }
    }
  }

  func startTokenStream() throws {
    // Android republishes FCM token refreshes through
    // DyplinkFlutterMessagingService. iOS has no equivalent: APNs hands the
    // device token to the host app's own
    // `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`,
    // and the app passes it to `DyplinkPush.registerToken`. There is no
    // token source here to stream from, so this throws rather than
    // installing a listener that could never fire.
    throw Self.unsupportedOnIOS(
      "DyplinkPush.startTokenStream",
      because: "iOS has no token-refresh callback — the host app owns APNs registration"
    )
  }

  func stopTokenStream() throws {
    throw Self.unsupportedOnIOS(
      "DyplinkPush.stopTokenStream",
      because: "iOS has no token-refresh callback — the host app owns APNs registration"
    )
  }

  // ──────────────────────────────────────────────────────────────────────
  // DyplinkBannersHostApi — forwards to DyplinkBanners.DyplinkBanners
  // ──────────────────────────────────────────────────────────────────────

  func loadBanners(
    categoryId: String,
    completion: @escaping (Result<BannerCategoryDto, Error>) -> Void
  ) {
    // `loadBanners` asserts on an uninitialized SDK; a thrown
    // NOT_INITIALIZED is the same information without the crash.
    do {
      try Self.requireCoreInitialized()
    } catch {
      reply(completion, .failure(error.toPigeonError()))
      return
    }
    Task {
      do {
        let category = try await DyplinkBanners.shared.loadBanners(categoryId: categoryId)
        reply(completion, .success(category.toDto()))
      } catch {
        reply(completion, .failure(error.toPigeonError()))
      }
    }
  }

  func clearCache() throws {
    DyplinkBanners.shared.clearCache()
  }

  // ──────────────────────────────────────────────────────────────────────
  // DyplinkMessagesHostApi — forwards to DyplinkMessages.DyplinkMessages
  // ──────────────────────────────────────────────────────────────────────

  func onAppOpen() throws {
    try Self.requireCoreInitialized()
    DyplinkMessages.shared.onAppOpen()
  }

  func onScreenView(screen: String) throws {
    try Self.requireCoreInitialized()
    DyplinkMessages.shared.onScreenView(screen)
  }

  func onEvent(event: String) throws {
    try Self.requireCoreInitialized()
    DyplinkMessages.shared.onEvent(event)
  }

  func startMessageEventStream() throws {
    DyplinkMessages.shared.messageListener = messageListener
    messageStreamActive = true
  }

  func stopMessageEventStream() throws {
    DyplinkMessages.shared.messageListener = nil
    messageStreamActive = false
  }

  // ──────────────────────────────────────────────────────────────────────
  // iOS URL intake — scene delegate
  //
  // Android receives deep links through the Activity intent, which the
  // native SDK reads for itself. On iOS the URL is delivered to the app, so
  // the plugin has to hand it to the SDK.
  //
  // A scene-based app — every app from the current Flutter template —
  // receives URLs here and never through the UIApplicationDelegate methods
  // further down.
  // ──────────────────────────────────────────────────────────────────────

  /// A link that launched the app.
  ///
  /// iOS passes the launch URL (custom scheme) or user activity (Universal
  /// Link) in the scene's connection options and does *not* follow up with
  /// `scene(_:openURLContexts:)` / `scene(_:continue:)` for it, so this is
  /// the only chance to see it.
  public func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let connectionOptions else { return false }
    var handled = false
    for context in connectionOptions.urlContexts {
      handled = handleIncoming(url: context.url, isLaunch: true) || handled
    }
    for activity in connectionOptions.userActivities {
      handled = handleIncoming(userActivity: activity, isLaunch: true) || handled
    }
    return handled
  }

  /// Ends the window in which a redelivered launch URL is a duplicate rather
  /// than a new link — see [launchURL].
  public func sceneDidEnterBackground(_ scene: UIScene) {
    launchURL = nil
  }

  public func sceneDidDisconnect(_ scene: UIScene) {
    launchURL = nil
  }

  /// Custom-scheme opens while the app is running — `myapp://product/42`.
  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    var handled = false
    for context in URLContexts {
      handled = handleIncoming(url: context.url) || handled
    }
    return handled
  }

  /// Universal Links while the app is running — `https://links.example.com/aB3dE`.
  public func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
    return handleIncoming(userActivity: userActivity)
  }

  // ──────────────────────────────────────────────────────────────────────
  // iOS URL intake — application delegate
  //
  // The same two cases for a host app that has no scene manifest.
  // ──────────────────────────────────────────────────────────────────────

  /// Custom-scheme opens — `myapp://product/42`.
  public func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return handleIncoming(url: url)
  }

  /// Universal Links — `https://links.example.com/aB3dE`.
  public func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([Any]) -> Void
  ) -> Bool {
    return handleIncoming(userActivity: userActivity)
  }

  /// Hands a Universal Link's URL to the SDK, ignoring every other kind of
  /// activity (Handoff, Siri, Spotlight) — those are the host app's.
  private func handleIncoming(userActivity: NSUserActivity, isLaunch: Bool = false) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
      let url = userActivity.webpageURL
    else {
      return false
    }
    return handleIncoming(url: url, isLaunch: isLaunch)
  }

  /// Hands [url] to the SDK and reports whether it was a Dyplink link.
  ///
  /// Returns false for a URL the SDK does not recognize so the host app's
  /// own handlers — and other plugins — still see it. `handleDeepLink`
  /// answering nil is what makes that distinction possible, which is why it
  /// is used here rather than `handleCampaignDeepLink`.
  private func handleIncoming(url: URL, isLaunch: Bool = false) -> Bool {
    if isLaunch {
      launchURL = url
    } else if let launchURL, launchURL == url {
      // iOS handing the launch URL over a second time — see [launchURL].
      self.launchURL = nil
      return true
    }

    guard Dyplink.shared.isInitialized else {
      // Cold start: Flutter has not run `Dyplink.init` yet, so the SDK has
      // no config to match this URL against. Hold it for `initialize`.
      //
      // False, not true: whether this is even a Dyplink link is exactly
      // what cannot be known yet, and claiming it would take it away from
      // every other handler.
      pendingLaunchURL = url
      return false
    }

    guard let result = Dyplink.shared.handleDeepLink(url: url) else {
      return false
    }

    // When the stream is open the listener installed by
    // [startDeepLinkStream] has already delivered this. When it is not —
    // the usual case for a link that launched the app — hold the result for
    // the subscriber that is about to appear.
    if !deepLinkStreamActive || !deepLinkSink.isAttached {
      pendingDeepLinkEvent = result.toEventMap()
    }
    return true
  }

  private func replayPendingLaunchURL() {
    guard let url = pendingLaunchURL else { return }
    pendingLaunchURL = nil
    // `isLaunch`: this *is* the launch delivery, just late — it must not be
    // mistaken for the redelivery that [launchURL] exists to drop.
    _ = handleIncoming(url: url, isLaunch: true)
  }

  private func flushPendingDeepLinkEvent() {
    guard deepLinkStreamActive, deepLinkSink.isAttached,
      let event = pendingDeepLinkEvent
    else {
      return
    }
    pendingDeepLinkEvent = nil
    deepLinkSink.send(event)
  }

  // MARK: - Helpers

  /// The guard the Android SDK applies inside every one of these calls and
  /// the iOS SDK does not: `Dyplink` logs and no-ops when uninitialized, so
  /// without this a Flutter app would see `track` succeed while nothing was
  /// recorded, and `matchDeferredDeepLink` answer "no match" because the
  /// SDK was never started.
  private static func requireCoreInitialized() throws {
    guard Dyplink.shared.isInitialized else {
      throw PigeonError(
        code: "NOT_INITIALIZED",
        message: "Dyplink SDK not initialized — call Dyplink.init() first",
        details: nil
      )
    }
  }

  private static func unsupportedOnIOS(_ method: String, because reason: String) -> PigeonError {
    return PigeonError(
      code: "UNSUPPORTED_ON_IOS",
      message: "\(method) is Android-only: \(reason).",
      details: nil
    )
  }
}

// =============================================================================
// Async bridging
// =============================================================================

/// Hops a Pigeon completion onto the platform thread, the way the Android
/// bridge resolves its callbacks on the main dispatcher.
///
/// A free function and not a method so the `Task { }` blocks that call it
/// capture nothing but their own arguments — a plugin captured into one would
/// be held alive by it.
private func reply<T>(
  _ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>
) {
  if Thread.isMainThread {
    completion(result)
  } else {
    DispatchQueue.main.async { completion(result) }
  }
}

// =============================================================================
// Stream plumbing
// =============================================================================

/// Bridges one `FlutterEventChannel` to a native SDK listener.
///
/// Sends hop to the platform thread, since the SDK's listeners fire on
/// whichever thread did the work — the iOS counterpart of the Android
/// bridge's `postToMain`.
final class EventSinkHolder: NSObject, FlutterStreamHandler, @unchecked Sendable {
  private let lock = NSLock()
  private var sink: FlutterEventSink?

  /// Called when Dart subscribes. Lets the deep-link channel deliver a link
  /// that arrived before anything was listening.
  var onAttach: (() -> Void)?

  var isAttached: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sink != nil
  }

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    lock.lock()
    sink = events
    lock.unlock()
    // Async so the subscription is fully established before anything is
    // pushed into it.
    if let onAttach {
      DispatchQueue.main.async(execute: onAttach)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    lock.lock()
    sink = nil
    lock.unlock()
    return nil
  }

  /// Drops the sink on plugin teardown, without going through the channel.
  func detach() {
    lock.lock()
    sink = nil
    lock.unlock()
    onAttach = nil
  }

  func send(_ value: Any?) {
    lock.lock()
    let sink = self.sink
    lock.unlock()
    guard let sink else { return }
    if Thread.isMainThread {
      sink(value)
    } else {
      DispatchQueue.main.async { sink(value) }
    }
  }
}

/// Forwards in-app message interactions onto the message-event channel.
///
/// EventChannels use the Standard codec (no Pigeon schema), so the payload is
/// a plain map keyed by field name; the Dart facade decodes it in
/// `DyplinkMessages._parseEvent`.
final class MessageEventForwarder: NSObject, MessageListener {
  private let sink: EventSinkHolder

  init(sink: EventSinkHolder) {
    self.sink = sink
    super.init()
  }

  func onMessageEvent(message: InAppMessage, eventType: String, buttonId: String?) {
    sink.send(
      eventMap([
        "type": "message_event",
        "message": message.toEventMap(),
        "eventType": eventType,
        "buttonId": buttonId,
      ]))
  }

  func onButtonAction(message: InAppMessage, button: MessageButton) {
    sink.send(
      eventMap([
        "type": "button_action",
        "message": message.toEventMap(),
        "button": button.toEventMap(),
      ]))
  }

  func onCustomEvent(message: InAppMessage, eventName: String) {
    sink.send(
      eventMap([
        "type": "custom_event",
        "message": message.toEventMap(),
        "eventName": eventName,
      ]))
  }
}

// =============================================================================
// Conversion helpers: native SDK types ⇄ Pigeon DTOs
// =============================================================================

extension DyplinkConfigDto {
  func toNativeConfig() throws -> DyplinkConfig {
    let builder = DyplinkConfig.Builder(
      baseUrl: baseUrl,
      apiKey: apiKey,
      projectId: projectId
    )
    .logLevel(logLevel.toNativeLogLevel())
    .flushInterval(Int(flushIntervalSeconds))
    .maxQueueSize(Int(maxQueueSize))
    .maxRetries(Int(maxRetries))
    .sessionTimeout(Int(sessionTimeoutSeconds))
    .enableAutoSessionTracking(enableAutoSessionTracking)
    .enableAutoDeviceInfo(enableAutoDeviceInfo)
    .deepLinkHosts(deepLinkHosts)

    if let customScheme {
      builder.customScheme(customScheme)
    }
    return try builder.build()
  }
}

extension DyplinkLogLevel {
  /// The Pigeon enum and the SDK's own log level share a name, so the SDK's
  /// has to be spelled out in full.
  func toNativeLogLevel() -> DyplinkCore.DyplinkLogLevel {
    switch self {
    case .none: return DyplinkCore.DyplinkLogLevel.none
    case .error: return .error
    case .warn: return .warn
    case .info: return .info
    case .debug: return .debug
    case .verbose: return .verbose
    }
  }
}

extension IdentifyParamsDto {
  func toNativeParams() -> IdentifyParams {
    let b = IdentifyParams.Builder()
    if let distinctId { b.distinctId(distinctId) }
    if let externalUserId { b.externalUserId(externalUserId) }
    if let firstName { b.firstName(firstName) }
    if let lastName { b.lastName(lastName) }
    if let phone { b.phone(phone) }
    if let avatar { b.avatar(avatar) }
    if let locale { b.locale(locale) }
    if let language { b.language(language) }
    if let appVersion { b.appVersion(appVersion) }
    if let appBuild { b.appBuild(appBuild) }
    if let traits = traits?.sanitized() { b.traits(traits) }
    if let utmSource { b.utmSource(utmSource) }
    if let utmMedium { b.utmMedium(utmMedium) }
    if let utmCampaign { b.utmCampaign(utmCampaign) }
    if let utmContent { b.utmContent(utmContent) }
    if let utmTerm { b.utmTerm(utmTerm) }
    if let installSource { b.installSource(installSource) }
    if let installCampaign { b.installCampaign(installCampaign) }
    if let emailOptIn { b.emailOptIn(emailOptIn) }
    if let smsOptIn { b.smsOptIn(smsOptIn) }
    if let pushOptIn { b.pushOptIn(pushOptIn) }
    if let gdprConsent { b.gdprConsent(gdprConsent) }
    if let doNotTrack { b.doNotTrack(doNotTrack) }
    return b.build()
  }
}

extension TrackConversionParamsDto {
  func toNativeParams() -> TrackConversionParams {
    return TrackConversionParams(
      eventType: eventType,
      shortCode: shortCode,
      linkId: linkId,
      externalUserId: externalUserId,
      metadata: metadata?.sanitized()
    )
  }
}

extension IdentifyResult {
  func toDto() -> IdentifyResultDto {
    return IdentifyResultDto(
      id: id,
      projectId: projectId,
      distinctId: distinctId,
      externalUserId: externalUserId,
      deviceFingerprint: deviceFingerprint,
      platform: platform
    )
  }
}

extension DeferredMatchResult {
  func toDto() -> DeferredMatchResultDto {
    return DeferredMatchResultDto(
      matched: matched,
      linkId: linkId,
      shortCode: shortCode,
      params: pigeonMap(params)
    )
  }
}

extension DyplinkBanner {
  func toDto() -> BannerDto {
    return BannerDto(
      id: id,
      title: title,
      imageUrl: imageUrl,
      clickUrl: clickUrl,
      ctaText: ctaText,
      sortOrder: Int64(sortOrder),
      isActive: isActive,
      metadata: pigeonMap(metadata)
    )
  }
}

extension BannerCategory {
  func toDto() -> BannerCategoryDto {
    return BannerCategoryDto(
      id: id,
      name: name,
      layout: layout,
      aspectRatio: aspectRatio,
      autoRotate: autoRotate,
      rotationInterval: Int64(rotationInterval),
      heading: heading,
      backgroundColor: backgroundColor,
      padding: Int64(padding),
      banners: banners.map { $0.toDto() }
    )
  }
}

// ── EventChannel serialization (Standard codec, not Pigeon) ──────────────────
//
// These helpers produce maps the Standard codec can encode without knowing
// anything about Pigeon. The Dart facade has a matching `.fromEventMap(...)`
// for each type.

extension DeepLinkResult {
  func toEventMap() -> [String: Any] {
    return eventMap([
      "url": url,
      "shortCode": shortCode,
      "params": params?.asFoundationJSON(),
      "isDeferred": isDeferred,
      "linkId": linkId,
    ])
  }
}

extension InAppMessage {
  func toEventMap() -> [String: Any] {
    return eventMap([
      "id": id,
      "messageType": messageType,
      "title": title,
      "body": body,
      "imageUrl": imageUrl,
      "imagePosition": imagePosition,
      "buttons": buttons?.map { $0.toEventMap() },
      "theme": theme?.toEventMap(),
      "dismissOnTapOutside": dismissOnTapOutside,
      "autoDismissSeconds": autoDismissSeconds,
      "triggerDelay": triggerDelay,
    ])
  }
}

extension MessageButton {
  func toEventMap() -> [String: Any] {
    return eventMap([
      "id": id,
      "text": text,
      "action": action,
      "actionUrl": actionUrl,
      "actionEvent": actionEvent,
      "style": style,
    ])
  }
}

extension MessageTheme {
  func toEventMap() -> [String: Any] {
    return eventMap([
      "backgroundColor": backgroundColor,
      "textColor": textColor,
      "titleColor": titleColor,
      "buttonPrimaryColor": buttonPrimaryColor,
      "buttonSecondaryColor": buttonSecondaryColor,
      "overlayColor": overlayColor,
      "borderRadius": borderRadius,
      "animation": animation,
    ])
  }
}

/// Drops the nil-valued entries from an event payload.
///
/// Every Dart `fromEventMap` reads optional fields as `map['key'] as T?`, for
/// which an absent key and a null one are the same thing — and an absent key
/// is one less value to bridge through `NSNull`.
private func eventMap(_ fields: [String: Any?]) -> [String: Any] {
  return fields.compactMapValues { $0 }
}

/// A JSON map in the shape Pigeon's generated DTOs expect.
private func pigeonMap(_ map: [String: AnyJSONValue]?) -> [String?: Any?]? {
  guard let map else { return nil }
  var out: [String?: Any?] = [:]
  for (key, value) in map {
    out[key] = value.asFoundationJSON()
  }
  return out
}

extension Dictionary where Key == String?, Value == Any? {
  /// Pigeon delivers maps as `[String?: Any?]`, but the SDK's APIs take
  /// `[String: Any]`. Strip the null keys and values so the result can be
  /// passed straight through — the iOS counterpart of the Android bridge's
  /// `sanitizeMap`.
  fileprivate func sanitized() -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in self {
      guard let key, let value, !(value is NSNull) else { continue }
      out[key] = value
    }
    return out
  }
}

// =============================================================================
// Error mapping
// =============================================================================

extension Error {
  /// Rewraps a native `DyplinkError` as a `PigeonError` so the Dart side
  /// receives a typed `PlatformException` with a stable code.
  ///
  /// The codes match `Throwable.toFlutterError()` in `DyplinkPlugin.kt`
  /// exactly — `DyplinkError.fromPlatformException` in Dart is the single
  /// reader for both platforms:
  ///   NOT_INITIALIZED   — SDK not initialised yet
  ///   INVALID_CONFIG    — bad config fields (from the Builder's validation)
  ///   NETWORK_ERROR     — transport failure
  ///   API_ERROR:<http>  — server-side failure; HTTP status suffixed
  ///   UNKNOWN           — anything else; message preserved
  func toPigeonError() -> PigeonError {
    if let pigeonError = self as? PigeonError {
      return pigeonError
    }

    guard let dyplinkError = self as? DyplinkError else {
      return PigeonError(code: "UNKNOWN", message: localizedDescription, details: nil)
    }

    switch dyplinkError {
    case .notInitialized(let message):
      return PigeonError(code: "NOT_INITIALIZED", message: message, details: nil)

    case .invalidConfig(let message):
      return PigeonError(code: "INVALID_CONFIG", message: message, details: nil)

    case .networkError(let message, let statusCode, _):
      var details: [String: Any] = [:]
      if let statusCode { details["statusCode"] = statusCode }
      return PigeonError(code: "NETWORK_ERROR", message: message, details: details)

    case .apiError(let message, let statusCode, let responseBody):
      var details: [String: Any] = ["statusCode": statusCode]
      if let responseBody { details["responseBody"] = responseBody }
      return PigeonError(
        code: "API_ERROR:\(statusCode)", message: message, details: details)
    }
  }
}
