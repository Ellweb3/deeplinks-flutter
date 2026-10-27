/// Deep linking, deferred deep linking and install attribution for apps
/// served by a self-hosted spbse server.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'src/api_client.dart';
import 'src/client.dart';
import 'src/deep_link.dart';
import 'src/native_bridge.dart';

export 'src/client.dart' show InstallReferrerProvider;
export 'src/deep_link.dart';
export 'src/native_bridge.dart' show DeviceInfo, NativeBridge;

/// Entry point of the SDK.
///
/// Call [init] once at startup, then listen to [onLink] to route the user
/// to the screen a link points at.
class DeepLinks {
  DeepLinks._();

  static DeepLinksClient? _client;
  static Future<void>? _starting;

  /// Starts the SDK.
  ///
  /// [baseUrl] is the SDK host of your spbse server, for example
  /// `https://sdk.example.com`. Plain `http` is accepted only for `localhost`,
  /// `10.0.2.2` and `*.localhost`. [appKey] is the public SDK key of the app
  /// (`dl_pk_…`).
  ///
  /// [linkDomains] lists the short link hosts of the app; on iOS the clipboard
  /// is read only when it holds a link on one of these hosts.
  ///
  /// With [startDisabled] the SDK makes no network calls until [enable] is
  /// called; the choice persists across launches. Set [captureLinks] to
  /// `false` when another package (go_router, app_links) already receives
  /// links, and pass them to [handleUri] instead.
  ///
  /// [installReferrer] supplies a referrer from a store other than Google
  /// Play, such as RuStore. It is tried first on Android, with a 5 second
  /// timeout.
  ///
  /// Repeated calls return the first call's future.
  static Future<void> init({
    required String baseUrl,
    required String appKey,
    bool startDisabled = false,
    List<String> linkDomains = const [],
    bool captureLinks = true,
    http.Client? httpClient,
    NativeBridge? bridge,
    InstallReferrerProvider? installReferrer,
  }) {
    if (_starting != null) return _starting!;
    WidgetsFlutterBinding.ensureInitialized();
    if (!appKey.startsWith('dl_pk_') && !appKey.startsWith('dm_pk_')) {
      throw ArgumentError.value(appKey, 'appKey', 'must be the public sdk key (dl_pk_...)');
    }
    final base = validateBaseUrl(baseUrl);
    final client = DeepLinksClient(
      options: ClientOptions(
        baseUrl: base,
        appKey: appKey,
        startDisabled: startDisabled,
        linkDomains: linkDomains.map((d) => d.toLowerCase()).toList(),
        captureLinks: captureLinks,
        installReferrer: installReferrer,
      ),
      bridge: bridge ?? MethodChannelBridge(),
      api: ApiClient(baseUrl: base, appKey: appKey, httpClient: httpClient),
    );
    _client = client;
    return _starting = client.start();
  }

  static DeepLinksClient get _require {
    final client = _client;
    if (client == null) throw StateError('DeepLinks.init must be called first');
    return client;
  }

  /// Every link the app receives: the launch link, the deferred link after
  /// install, links opened while the app runs and links passed to
  /// [handleUri]. Events are buffered until the first listener subscribes.
  static Stream<DeepLink> get onLink => _require.onLink;

  /// The link that launched the app, or the deferred link of the first launch
  /// after install. Completes with `null` when there is neither.
  static Future<DeepLink?> getInitialLink() => _require.getInitialLink();

  /// Resolves [uri] through the server and records the open.
  ///
  /// Use it when links reach the app through another package. The result is
  /// also emitted on [onLink].
  static Future<DeepLink> handleUri(Uri uri) => _require.handleUri(uri);

  /// Whether the SDK is allowed to send data.
  static bool get isEnabled => _client?.isEnabled ?? false;

  /// Allows network calls after `startDisabled: true` or [disable].
  static Future<void> enable() => _require.enable();

  /// Stops sending data and clears the queued events. Persists across launches.
  static Future<void> disable() => _require.disable();

  /// Queues an in-app event. Events are stored on disk and sent in batches.
  static Future<void> track(String name, {Map<String, Object?>? props}) => _require.track(name, props: props);

  /// Queues a purchase. [amountMinor] is in minor units (cents), [currency]
  /// is an ISO 4217 code.
  static Future<void> trackPurchase({
    required int amountMinor,
    required String currency,
    String? productId,
    Map<String, Object?>? props,
  }) => _require.trackPurchase(amountMinor: amountMinor, currency: currency, productId: productId, props: props);

  /// Links this install to your own user id. Required for referral links.
  static Future<void> setUserId(String id) => _require.setUserId(id);

  /// Creates a short link from the app, for sharing or invites.
  ///
  /// With [referral] the link carries the current user id, so a new user who
  /// installs through it receives [DeepLink.referralToken].
  static Future<CreatedLink> createLink({
    String? path,
    Map<String, Object?>? payload,
    bool referral = false,
    String? campaign,
    String? channel,
    String? ogTitle,
    String? ogDescription,
    String? ogImageUrl,
  }) => _require.createLink(
    path: path,
    payload: payload,
    referral: referral,
    campaign: campaign,
    channel: channel,
    ogTitle: ogTitle,
    ogDescription: ogDescription,
    ogImageUrl: ogImageUrl,
  );

  /// Deletes the device data on the server and locally, then disables the SDK.
  static Future<void> forget() => _require.forget();

  /// Disposes the SDK so [init] can be called again. For tests only.
  @visibleForTesting
  static Future<void> reset() async {
    await _client?.dispose();
    _client = null;
    _starting = null;
  }
}
