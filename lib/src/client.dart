import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'api_client.dart';
import 'buffered_stream.dart';
import 'deep_link.dart';
import 'native_bridge.dart';

class StorageKeys {
  static const installInstanceId = 'install_instance_id';
  static const installId = 'install_id';
  static const deferredDone = 'deferred_done';
  static const consent = 'consent';
  static const eventQueue = 'event_queue';
  static const userId = 'user_id';
  static const userIdSynced = 'user_id_synced';

  static const resettable = [installInstanceId, installId, deferredDone, eventQueue, userId, userIdSynced];
}

/// Returns an install referrer from a store other than Google Play, such as
/// the RuStore `referrerId`, or `null` to fall back to Google Play.
typedef InstallReferrerProvider = Future<String?> Function();

class ClientOptions {
  const ClientOptions({
    required this.baseUrl,
    required this.appKey,
    this.startDisabled = false,
    this.linkDomains = const [],
    this.captureLinks = true,
    this.installRetries = 3,
    this.referrerTimeout = const Duration(seconds: 2),
    this.initialLinkTimeout = const Duration(seconds: 6),
    this.eventFlushDelay = const Duration(seconds: 2),
    this.maxQueuedEvents = 500,
    this.eventBatchSize = 50,
    this.installReferrer,
    this.customReferrerTimeout = const Duration(seconds: 5),
  });

  final Uri baseUrl;
  final String appKey;
  final bool startDisabled;
  final List<String> linkDomains;
  final bool captureLinks;
  final int installRetries;
  final Duration referrerTimeout;
  final Duration initialLinkTimeout;
  final Duration eventFlushDelay;
  final int maxQueuedEvents;
  final int eventBatchSize;
  final InstallReferrerProvider? installReferrer;
  final Duration customReferrerTimeout;
}

class DeepLinksClient {
  DeepLinksClient({
    required this.options,
    required NativeBridge bridge,
    required ApiClient api,
    DateTime Function()? clock,
    Duration Function(int attempt)? retryDelay,
  }) : _bridge = bridge,
       _api = api,
       _clock = clock ?? DateTime.now,
       _retryDelay = retryDelay ?? ((attempt) => Duration(milliseconds: 500 * (1 << attempt)));

  final ClientOptions options;
  final NativeBridge _bridge;
  final ApiClient _api;
  final DateTime Function() _clock;
  final Duration Function(int attempt) _retryDelay;
  final BufferedBroadcast<DeepLink> _links = BufferedBroadcast<DeepLink>();
  Completer<DeepLink?> _initialLink = Completer<DeepLink?>();
  final Random _random = Random.secure();

  bool _enabled = false;
  bool _sessionStarted = false;
  DeviceInfo? _device;
  Future<void>? _installFuture;
  DeepLink? _launchLink;
  DeepLink? _deferredLink;
  StreamSubscription<String>? _linkSubscription;
  Timer? _flushTimer;
  Future<void>? _flushing;

  Stream<DeepLink> get onLink => _links.stream;
  bool get isEnabled => _enabled;

  Future<void> start() async {
    final consent = await _bridge.storageGet(StorageKeys.consent);
    _enabled = consent == null ? !options.startDisabled : consent == '1';
    if (options.captureLinks) {
      _linkSubscription = _bridge.links.listen((raw) {
        final uri = Uri.tryParse(raw);
        if (uri != null) {
          unawaited(handleUri(uri, source: DeepLinkSource.foreground));
        }
      });
    }
    final initial = options.captureLinks ? await _bridge.initialLink() : null;
    final initialUri = initial == null ? null : Uri.tryParse(initial);
    if (_enabled) {
      _startSession(hasLaunchLink: initialUri != null);
    }
    unawaited(_processInitialLink(initialUri));
  }

  Future<void> _processInitialLink(Uri? uri) async {
    if (uri != null) {
      _launchLink = await handleUri(uri, source: DeepLinkSource.launch);
    }
    await _resolveInitialLink();
  }

  Future<DeepLink?> getInitialLink() => _initialLink.future;

  Future<void> _resolveInitialLink() async {
    final install = _installFuture;
    if (_launchLink == null && install != null) {
      await install.timeout(options.initialLinkTimeout, onTimeout: () {});
    }
    if (!_initialLink.isCompleted) {
      _initialLink.complete(_launchLink ?? _deferredLink);
    }
  }

  Future<DeepLink> handleUri(Uri uri, {DeepLinkSource source = DeepLinkSource.manual}) async {
    if (!_enabled) {
      final link = DeepLink.unresolved(uri, source);
      _links.add(link);
      return link;
    }
    final install = _installFuture;
    if (install != null) {
      await install.timeout(options.initialLinkTimeout, onTimeout: () {});
    }
    DeepLink link;
    try {
      final device = await _deviceInfo();
      final response = await _api.post('v1/open', {
        'device_id': device.deviceId,
        'url': uri.toString(),
        'source': _openSource(uri, device.platform),
      });
      final data = response.body['link'];
      link = response.isSuccess && data is Map<String, Object?>
          ? DeepLink.fromServer(
              data,
              source: source,
              uri: uri,
              referralToken: response.body['referral_token'] as String?,
            )
          : DeepLink.unresolved(uri, source);
    } on ApiUnavailable {
      link = DeepLink.unresolved(uri, source);
    }
    _links.add(link);
    return link;
  }

  String _openSource(Uri uri, String platform) {
    if (uri.scheme != 'https' && uri.scheme != 'http') return 'scheme';
    return platform == 'android' ? 'app_link' : 'universal_link';
  }

  void _startSession({bool hasLaunchLink = false}) {
    if (_sessionStarted) return;
    _sessionStarted = true;
    _installFuture = _ensureInstall();
    unawaited(
      _installFuture!.then((_) async {
        if (!hasLaunchLink) await _recordSessionOpen();
        await _syncUserId();
        await flushEvents();
      }),
    );
  }

  Future<void> _ensureInstall() async {
    if (await _bridge.storageGet(StorageKeys.deferredDone) == '1') return;
    final instanceId = await _installInstanceId();
    final device = await _deviceInfo();
    final body = <String, Object?>{
      'device_id': device.deviceId,
      'install_instance_id': instanceId,
      'platform': device.platform,
      'app_version': device.appVersion,
      'sdk_version': sdkVersion,
      'signals': device.signals(),
      'client_ts': _clock().toUtc().toIso8601String(),
    };
    if (device.platform == 'android') {
      final referrer =
          await _customReferrer() ??
          await _bridge.installReferrer().timeout(options.referrerTimeout, onTimeout: () => null);
      if (referrer != null && referrer.isNotEmpty) body['install_referrer'] = referrer;
    } else if (device.platform == 'ios') {
      final clipboard = await _bridge.clipboardLink(options.linkDomains);
      if (clipboard != null && clipboard.isNotEmpty) body['clipboard_url'] = clipboard;
    }
    body.removeWhere((_, v) => v == null);
    for (var attempt = 0; attempt < options.installRetries; attempt++) {
      try {
        final response = await _api.post('v1/install', body);
        if (response.isSuccess) {
          await _completeInstall(response.body);
          return;
        }
        if (!response.isRetryable) return;
      } on ApiUnavailable {
        if (!_enabled) return;
      }
      if (attempt + 1 < options.installRetries) {
        await Future<void>.delayed(_retryDelay(attempt));
      }
    }
  }

  Future<void> _completeInstall(Map<String, Object?> body) async {
    final installId = body['install_id'];
    if (installId is String) {
      await _bridge.storageSet(StorageKeys.installId, installId);
    }
    await _bridge.storageSet(StorageKeys.deferredDone, '1');
    final link = body['link'];
    if (link is Map<String, Object?>) {
      _deferredLink = DeepLink.fromServer(
        link,
        source: DeepLinkSource.deferred,
        matchMethod: body['match_method'] as String?,
        confidence: (body['confidence'] as num?)?.toDouble(),
        isReinstall: body['is_reinstall'] == true,
        referralToken: body['referral_token'] as String?,
      );
      _links.add(_deferredLink!);
    }
  }

  Future<String> _installInstanceId() async {
    final existing = await _bridge.storageGet(StorageKeys.installInstanceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = _randomId();
    await _bridge.storageSet(StorageKeys.installInstanceId, created);
    return created;
  }

  Future<DeviceInfo> _deviceInfo() async => _device ??= await _bridge.deviceInfo(options.appKey);

  Future<void> _recordSessionOpen() async {
    if (!_enabled) return;
    try {
      final device = await _deviceInfo();
      await _api.post('v1/open', {'device_id': device.deviceId, 'source': 'organic'});
    } on ApiUnavailable {
      return;
    }
  }

  Future<void> enable() async {
    await _bridge.storageSet(StorageKeys.consent, '1');
    _enabled = true;
    _startSession();
    if (_initialLink.isCompleted && _launchLink == null && _deferredLink == null) {
      _initialLink = Completer<DeepLink?>();
      unawaited(_resolveInitialLink());
    }
  }

  Future<void> disable() async {
    await _bridge.storageSet(StorageKeys.consent, '0');
    _enabled = false;
    _sessionStarted = false;
    _flushTimer?.cancel();
    await _bridge.storageRemove(StorageKeys.eventQueue);
  }

  Future<void> setUserId(String id) async {
    final trimmed = id.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
    await _bridge.storageSet(StorageKeys.userId, trimmed);
    await _bridge.storageRemove(StorageKeys.userIdSynced);
    await _syncUserId();
  }

  Future<void> _syncUserId() async {
    if (!_enabled) return;
    final userId = await _bridge.storageGet(StorageKeys.userId);
    if (userId == null || await _bridge.storageGet(StorageKeys.userIdSynced) == userId) return;
    try {
      final device = await _deviceInfo();
      final response = await _api.post('v1/identify', {'device_id': device.deviceId, 'user_id': userId});
      if (response.isSuccess) await _bridge.storageSet(StorageKeys.userIdSynced, userId);
    } on ApiUnavailable {
      return;
    }
  }

  Future<void> forget() async {
    final device = await _deviceInfo();
    try {
      await _api.post('v1/forget', {'device_id': device.deviceId});
    } finally {
      for (final key in StorageKeys.resettable) {
        await _bridge.storageRemove(key);
      }
      await disable();
    }
  }

  Future<CreatedLink> createLink({
    String? path,
    Map<String, Object?>? payload,
    bool referral = false,
    String? campaign,
    String? channel,
    String? ogTitle,
    String? ogDescription,
    String? ogImageUrl,
  }) async {
    if (!_enabled) throw StateError('DeepLinks is disabled');
    final install = _installFuture;
    if (install != null) await install;
    final device = await _deviceInfo();
    final response = await _api.post('v1/links', {
      'device_id': device.deviceId,
      'kind': referral ? 'referral' : 'standard',
      'deep_link_path': ?path,
      'payload': ?payload,
      'campaign': ?campaign,
      'channel': ?channel,
      'og_title': ?ogTitle,
      'og_description': ?ogDescription,
      'og_image_url': ?ogImageUrl,
    });
    final body = response.body;
    if (!response.isSuccess || body['url'] is! String) {
      final error = body['error'];
      throw StateError('createLink failed (${response.statusCode}): ${error is Map ? error['message'] : body}');
    }
    return CreatedLink(
      linkId: body['link_id']! as String,
      url: Uri.parse(body['url']! as String),
      code: body['code']! as String,
    );
  }

  Future<void> track(String name, {Map<String, Object?>? props}) => _enqueue({'name': name, 'properties': ?props});

  Future<void> trackPurchase({
    required int amountMinor,
    required String currency,
    String name = 'purchase',
    String? productId,
    Map<String, Object?>? props,
  }) {
    if (amountMinor < 0) throw ArgumentError.value(amountMinor, 'amountMinor', 'must not be negative');
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      throw ArgumentError.value(currency, 'currency', 'must be an ISO 4217 code like USD');
    }
    return _enqueue({
      'name': name,
      'revenue_minor': amountMinor,
      'currency': currency,
      'properties': {...?props, 'product_id': ?productId},
    });
  }

  Future<void> _enqueue(Map<String, Object?> event) async {
    final name = event['name']! as String;
    if (name.trim().isEmpty || name.length > 64) {
      throw ArgumentError.value(name, 'name', 'must be 1-64 characters');
    }
    if (!_enabled) return;
    final queue = await _loadQueue();
    queue.add({...event, 'client_event_id': _randomId(), 'occurred_at': _clock().toUtc().toIso8601String()});
    while (queue.length > options.maxQueuedEvents) {
      queue.removeAt(0);
    }
    await _saveQueue(queue);
    _flushTimer?.cancel();
    _flushTimer = Timer(options.eventFlushDelay, () => unawaited(flushEvents()));
  }

  Future<void> flushEvents() => _flushing ??= _flush().whenComplete(() => _flushing = null);

  Future<void> _flush() async {
    if (!_enabled) return;
    final install = _installFuture;
    if (install != null) await install;
    final device = await _deviceInfo();
    while (_enabled) {
      final queue = await _loadQueue();
      if (queue.isEmpty) return;
      final batch = queue.take(options.eventBatchSize).toList();
      ApiResponse response;
      try {
        response = await _api.post('v1/events', {'device_id': device.deviceId, 'events': batch});
      } on ApiUnavailable {
        return;
      }
      if (response.isRetryable) return;
      final sent = batch.map((e) => e['client_event_id']).toSet();
      final remaining = (await _loadQueue()).where((e) => !sent.contains(e['client_event_id'])).toList();
      await _saveQueue(remaining);
    }
  }

  Future<List<Map<String, Object?>>> _loadQueue() async {
    final raw = await _bridge.storageGet(StorageKeys.eventQueue);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.whereType<Map<String, Object?>>().toList();
    } on FormatException {
      return [];
    }
  }

  Future<void> _saveQueue(List<Map<String, Object?>> queue) => queue.isEmpty
      ? _bridge.storageRemove(StorageKeys.eventQueue)
      : _bridge.storageSet(StorageKeys.eventQueue, jsonEncode(queue));

  String _randomId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    await _flushing;
    await _linkSubscription?.cancel();
    await _links.close();
    _api.close();
  }

  Future<String?> _customReferrer() async {
    final provider = options.installReferrer;
    if (provider == null) return null;
    try {
      final value = await provider()
          .then<String?>((v) => v)
          .timeout(options.customReferrerTimeout, onTimeout: () => null);
      return value == null || value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }
}
