import Flutter
import Security
import UIKit

public final class DeepLinksPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, FlutterSceneLifeCycleDelegate {
  private static let storageSuite = "io.deeplinks.sdk"
  private static let keychainService = "io.deeplinks.sdk"
  private static let keychainAccount = "device_id"
  private static let duplicateWindow: TimeInterval = 1
  private static let fallbackDeviceIdKey = "device_id_fallback"

  private let storage = UserDefaults(suiteName: DeepLinksPlugin.storageSuite) ?? .standard
  private var eventSink: FlutterEventSink?
  private var pendingLinks: [String] = []
  private var initialLink: String?
  private var initialLinkRequested = false
  private var lastLink: (url: String, at: Date)?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = DeepLinksPlugin()
    let methods = FlutterMethodChannel(name: "io.deeplinks/sdk", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(name: "io.deeplinks/links", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    registrar.addApplicationDelegate(instance)
    registrar.addSceneDelegate(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "deviceInfo":
      result(deviceInfo())
    case "storageGet":
      result((arguments["key"] as? String).flatMap { storage.string(forKey: $0) })
    case "storageSet":
      if let key = arguments["key"] as? String, let value = arguments["value"] as? String {
        storage.set(value, forKey: key)
      }
      result(nil)
    case "storageRemove":
      if let key = arguments["key"] as? String {
        storage.removeObject(forKey: key)
      }
      result(nil)
    case "installReferrer":
      result(nil)
    case "clipboardLink":
      clipboardLink(hosts: arguments["hosts"] as? [String] ?? [], result: result)
    case "initialLink":
      initialLinkRequested = true
      result(initialLink)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    let queued = pendingLinks
    pendingLinks.removeAll()
    queued.forEach { events($0) }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any] = [:]
  ) -> Bool {
    if let url = launchOptions[UIApplication.LaunchOptionsKey.url] as? URL {
      receive(url)
    }
    if let activities = launchOptions[UIApplication.LaunchOptionsKey.userActivityDictionary] as? [AnyHashable: Any] {
      activities.values.compactMap { ($0 as? NSUserActivity)?.webpageURL }.forEach(receive)
    }
    return true
  }

  public func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    receive(url)
    return false
  }

  public func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([Any]) -> Void
  ) -> Bool {
    receive(activity: userActivity)
    return false
  }

  public func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    connectionOptions?.urlContexts.forEach { receive($0.url) }
    connectionOptions?.userActivities.forEach { receive(activity: $0) }
    return false
  }

  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    URLContexts.forEach { receive($0.url) }
    return false
  }

  public func scene(_ scene: UIScene, continue userActivity: NSUserActivity) -> Bool {
    receive(activity: userActivity)
    return false
  }

  private func receive(activity: NSUserActivity) {
    guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else { return }
    receive(url)
  }

  private func receive(_ url: URL) {
    let value = url.absoluteString
    let now = Date()
    if let last = lastLink, last.url == value, now.timeIntervalSince(last.at) < DeepLinksPlugin.duplicateWindow {
      return
    }
    lastLink = (value, now)
    if !initialLinkRequested && initialLink == nil {
      initialLink = value
      return
    }
    if let sink = eventSink {
      sink(value)
    } else {
      pendingLinks.append(value)
    }
  }

  private func deviceInfo() -> [String: Any] {
    let screen = currentScreen()
    let bounds = screen.bounds
    var info: [String: Any] = [
      "device_id": deviceId(),
      "platform": "ios",
      "os_version": UIDevice.current.systemVersion,
      "device_model": modelIdentifier(),
      "screen_w": Int(bounds.width.rounded()),
      "screen_h": Int(bounds.height.rounded()),
      "dpr": Double(screen.scale),
      "timezone": TimeZone.current.identifier,
    ]
    if let language = Locale.preferredLanguages.first {
      info["language"] = language
    }
    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
      info["app_version"] = version
    }
    return info
  }

  private func currentScreen() -> UIScreen {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let active = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
      return active.screen
    }
    return UIScreen.main
  }

  private func modelIdentifier() -> String {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return simulated
    }
    var systemInfo = utsname()
    uname(&systemInfo)
    let bytes = withUnsafeBytes(of: &systemInfo.machine) { Array($0) }
    return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
  }

  private func deviceId() -> String {
    let lookup: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: DeepLinksPlugin.keychainService,
      kSecAttrAccount as String: DeepLinksPlugin.keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let existing = String(data: data, encoding: .utf8),
      !existing.isEmpty
    {
      return existing
    }
    let created = UUID().uuidString.lowercased()
    let insert: (String) -> [String: Any] = { value in
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: DeepLinksPlugin.keychainService,
        kSecAttrAccount as String: DeepLinksPlugin.keychainAccount,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecValueData as String: Data(value.utf8),
      ]
    }
    if let fallback = storage.string(forKey: DeepLinksPlugin.fallbackDeviceIdKey), !fallback.isEmpty {
      if SecItemAdd(insert(fallback) as CFDictionary, nil) == errSecSuccess {
        storage.removeObject(forKey: DeepLinksPlugin.fallbackDeviceIdKey)
      }
      return fallback
    }
    SecItemDelete(lookup.filter { $0.key != kSecReturnData as String && $0.key != kSecMatchLimit as String } as CFDictionary)
    if SecItemAdd(insert(created) as CFDictionary, nil) != errSecSuccess {
      storage.set(created, forKey: DeepLinksPlugin.fallbackDeviceIdKey)
    }
    return created
  }

  private func clipboardLink(hosts: [String], result: @escaping FlutterResult) {
    let pasteboard = UIPasteboard.general
    let allowedHosts = Set(hosts.map { $0.lowercased() })
    let changeCount = pasteboard.changeCount
    pasteboard.detectPatterns(for: [\UIPasteboard.DetectedValues.probableWebURL]) { detection in
      DispatchQueue.main.async {
        guard case .success(let patterns) = detection, patterns.contains(\UIPasteboard.DetectedValues.probableWebURL) else {
          result(nil)
          return
        }
        let candidate = pasteboard.url ?? pasteboard.string.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let url = candidate, DeepLinksPlugin.isClickToken(url, allowedHosts: allowedHosts) else {
          result(nil)
          return
        }
        if pasteboard.changeCount == changeCount {
          pasteboard.items = []
        }
        result(url.absoluteString)
      }
    }
  }

  static func isClickToken(_ url: URL, allowedHosts: Set<String>) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = url.host?.lowercased()
    else {
      return false
    }
    let segments = url.path.split(separator: "/")
    guard segments.count == 2, segments[0] == "t", !segments[1].isEmpty else { return false }
    return allowedHosts.isEmpty || allowedHosts.contains(host)
  }
}
