/// How a [DeepLink] reached the app.
enum DeepLinkSource {
  /// The link launched the app.
  launch,

  /// The link was clicked before install and matched on the first launch.
  deferred,

  /// The link was opened while the app was running.
  foreground,

  /// The link was passed to `DeepLinks.handleUri`.
  manual,
}

/// A link the app received, resolved through the server when possible.
class DeepLink {
  const DeepLink({
    required this.source,
    this.uri,
    this.linkId,
    this.shortUrl,
    this.code,
    this.path,
    this.payload = const {},
    this.utm = const {},
    this.campaign,
    this.channel,
    this.variant,
    this.matchMethod,
    this.confidence,
    this.isReinstall = false,
    this.isResolved = false,
    this.referralToken,
  });

  /// How the link reached the app.
  final DeepLinkSource source;

  /// The URI as opened, or the short link URL for deferred links.
  final Uri? uri;

  /// Server id of the link.
  final String? linkId;

  /// The short link URL.
  final String? shortUrl;

  /// The short link code, the last path segment of [shortUrl].
  final String? code;

  /// The in-app route set on the link (`deep_link_path`), such as `/product/42`.
  final String? path;

  /// Custom data set on the link.
  final Map<String, Object?> payload;

  /// UTM parameters set on the link.
  final Map<String, String> utm;

  /// Campaign of the link.
  final String? campaign;

  /// Channel of the link.
  final String? channel;

  /// A/B variant chosen by the link's targeting rules.
  final String? variant;

  /// How a deferred link was matched, such as `install_referrer` or `clipboard`.
  final String? matchMethod;

  /// Match confidence from 0 to 1 for deferred links.
  final double? confidence;

  /// Whether the device had the app installed before.
  final bool isReinstall;

  /// Whether the server recognised the link. Unresolved links carry only [uri] and [path].
  final bool isResolved;

  /// Token of a referral link; exchange it on your backend via `POST /v1/referrals/claim`.
  final String? referralToken;

  /// Whether the link is a referral invite.
  bool get isReferral => referralToken != null;

  /// Whether the link was matched after install.
  bool get isDeferred => source == DeepLinkSource.deferred;

  /// A link the server did not resolve.
  factory DeepLink.unresolved(Uri uri, DeepLinkSource source) =>
      DeepLink(source: source, uri: uri, path: uri.path.isEmpty ? null : uri.path);

  /// Builds a link from a server response.
  factory DeepLink.fromServer(
    Map<String, Object?> link, {
    required DeepLinkSource source,
    Uri? uri,
    String? matchMethod,
    double? confidence,
    bool isReinstall = false,
    String? referralToken,
  }) {
    final shortUrl = link['url'] as String?;
    return DeepLink(
      source: source,
      uri: uri ?? (shortUrl == null ? null : Uri.tryParse(shortUrl)),
      linkId: link['link_id'] as String?,
      shortUrl: shortUrl,
      code: link['code'] as String?,
      path: link['deep_link_path'] as String?,
      payload: _objectMap(link['payload']),
      utm: _stringMap(link['utm']),
      campaign: link['campaign'] as String?,
      channel: link['channel'] as String?,
      variant: link['variant'] as String?,
      matchMethod: matchMethod,
      confidence: confidence,
      isReinstall: isReinstall,
      isResolved: true,
      referralToken: referralToken,
    );
  }

  @override
  String toString() =>
      'DeepLink(source: ${source.name}, uri: $uri, path: $path, linkId: $linkId, payload: $payload, matchMethod: $matchMethod)';
}

Map<String, Object?> _objectMap(Object? value) =>
    value is Map ? value.map((k, v) => MapEntry(k.toString(), v as Object?)) : const {};

Map<String, String> _stringMap(Object? value) =>
    value is Map ? value.map((k, v) => MapEntry(k.toString(), v.toString())) : const {};

/// A short link created with `DeepLinks.createLink`.
class CreatedLink {
  const CreatedLink({required this.linkId, required this.url, required this.code});

  /// Server id of the link.
  final String linkId;

  /// The short link to share.
  final Uri url;

  /// The short link code.
  final String code;
}
