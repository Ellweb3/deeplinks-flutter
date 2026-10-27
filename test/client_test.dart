import 'dart:async';
import 'dart:convert';

import 'package:new_deeplinks/new_deeplinks.dart';
import 'package:new_deeplinks/src/api_client.dart';
import 'package:new_deeplinks/src/client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeBridge implements NativeBridge {
  FakeBridge({this.platform = 'ios', this.referrer, this.clipboard, this.initial});

  final String platform;
  final String? referrer;
  final String? clipboard;
  final String? initial;
  final Map<String, String> storage = {};
  final StreamController<String> incoming = StreamController<String>.broadcast();
  List<String>? clipboardHosts;

  @override
  Future<DeviceInfo> deviceInfo(String appKey) async => DeviceInfo(
    deviceId: 'device-$platform-0001',
    platform: platform,
    osVersion: platform == 'ios' ? '26.0.1' : '14',
    deviceModel: platform == 'ios' ? 'iPhone15,2' : 'Pixel 8',
    screenWidth: 393,
    screenHeight: 852,
    pixelRatio: 3,
    timezone: 'Europe/Moscow',
    language: 'ru-RU',
    appVersion: '1.0.0',
  );

  @override
  Future<String?> storageGet(String key) async => storage[key];

  @override
  Future<void> storageSet(String key, String value) async => storage[key] = value;

  @override
  Future<void> storageRemove(String key) async => storage.remove(key);

  @override
  Future<String?> installReferrer() async => referrer;

  @override
  Future<String?> clipboardLink(List<String> hosts) async {
    clipboardHosts = hosts;
    return clipboard;
  }

  @override
  Future<String?> initialLink() async => initial;

  @override
  Stream<String> get links => incoming.stream;
}

class FakeServer {
  final List<http.Request> requests = [];
  int installStatus = 200;
  int eventsStatus = 200;
  bool offline = false;
  Map<String, Object?>? installLink = {
    'link_id': 'link-1',
    'url': 'https://shop.lnk.example/Promo',
    'code': 'Promo',
    'deep_link_path': '/product/42',
    'payload': {'product_id': 42},
    'utm': {'source': 'ig'},
    'campaign': 'spring',
  };

  List<http.Request> calls(String path) => requests.where((r) => r.url.path.endsWith(path)).toList();

  Map<String, Object?> bodyOf(http.Request r) => jsonDecode(r.body) as Map<String, Object?>;

  MockClient client() => MockClient((request) async {
    requests.add(request);
    if (offline) throw http.ClientException('offline');
    final path = request.url.path;
    if (path.endsWith('/v1/install')) {
      return http.Response(
        jsonEncode({
          'install_id': 'install-1',
          'matched': installLink != null,
          'match_method': installLink != null ? 'clipboard' : 'organic',
          'confidence': installLink != null ? 1 : 0,
          'is_reinstall': false,
          'link': ?installLink,
          'referral_token': ?(installLink == null ? null : 'ref.token'),
        }),
        installStatus,
      );
    }
    if (path.endsWith('/v1/open')) {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final link = body['url'] == null
          ? null
          : {
              'link_id': 'link-2',
              'url': body['url'],
              'code': 'Open',
              'payload': {'from': 'open'},
              'utm': {},
            };
      return http.Response(jsonEncode({'link': link}), 200);
    }
    if (path.endsWith('/v1/events')) return http.Response('{}', eventsStatus);
    if (path.endsWith('/v1/links')) {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      if (body['kind'] == 'referral') {
        return http.Response(
          jsonEncode({
            'error': {'code': 'invalid_kind', 'message': 'setUserId first'},
          }),
          422,
        );
      }
      return http.Response(
        jsonEncode({'link_id': 'link-9', 'url': 'https://shop.lnk.example/AbCdEf12', 'code': 'AbCdEf12'}),
        201,
      );
    }
    return http.Response('{}', 200);
  });
}

DeepLinksClient buildClient(
  FakeBridge bridge,
  FakeServer server, {
  bool startDisabled = false,
  bool captureLinks = true,
  InstallReferrerProvider? installReferrer,
}) {
  final base = Uri.parse('https://sdk.example.com/');
  return DeepLinksClient(
    options: ClientOptions(
      baseUrl: base,
      appKey: 'dl_pk_test',
      startDisabled: startDisabled,
      captureLinks: captureLinks,
      linkDomains: const ['shop.lnk.example'],
      eventFlushDelay: const Duration(milliseconds: 10),
      initialLinkTimeout: const Duration(seconds: 1),
      installReferrer: installReferrer,
    ),
    bridge: bridge,
    api: ApiClient(baseUrl: base, appKey: 'dl_pk_test', httpClient: server.client()),
    retryDelay: (_) => Duration.zero,
    clock: () => DateTime.utc(2026, 10, 26, 12),
  );
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  test('deferred link is fetched once and buffered until the first listener', () async {
    final bridge = FakeBridge(clipboard: 'https://shop.lnk.example/t/token123');
    final server = FakeServer();
    final client = buildClient(bridge, server);
    await client.start();
    await settle();

    final received = <DeepLink>[];
    client.onLink.listen(received.add);
    await settle();
    expect(received, hasLength(1));
    expect(received.single.source, DeepLinkSource.deferred);
    expect(received.single.path, '/product/42');
    expect(received.single.payload['product_id'], 42);
    expect(received.single.matchMethod, 'clipboard');
    expect(bridge.clipboardHosts, ['shop.lnk.example']);

    final install = server.bodyOf(server.calls('/v1/install').single);
    expect(install['clipboard_url'], 'https://shop.lnk.example/t/token123');
    expect(install['platform'], 'ios');
    expect((install['signals']! as Map)['screen_w'], 393);
    expect(install['client_ts'], '2026-10-26T12:00:00.000Z');
    expect(bridge.storage[StorageKeys.deferredDone], '1');
    expect(await client.getInitialLink(), same(received.single));

    final second = buildClient(bridge, server);
    await second.start();
    await settle();
    expect(server.calls('/v1/install'), hasLength(1));
  });

  test('install instance id is generated once and reused on retry', () async {
    final bridge = FakeBridge();
    final server = FakeServer()..offline = true;
    final client = buildClient(bridge, server);
    await client.start();
    await settle();
    expect(server.calls('/v1/install'), hasLength(3));
    expect(bridge.storage[StorageKeys.deferredDone], isNull);
    final ids = server.calls('/v1/install').map((r) => server.bodyOf(r)['install_instance_id']).toSet();
    expect(ids, hasLength(1));

    server.offline = false;
    final retry = buildClient(bridge, server);
    await retry.start();
    await settle();
    expect(bridge.storage[StorageKeys.deferredDone], '1');
    expect(server.bodyOf(server.calls('/v1/install').last)['install_instance_id'], ids.single);
  });

  test('client errors are not retried within a launch', () async {
    final bridge = FakeBridge();
    final server = FakeServer()..installStatus = 422;
    final client = buildClient(bridge, server);
    await client.start();
    await settle();
    expect(server.calls('/v1/install'), hasLength(1));
    expect(bridge.storage[StorageKeys.deferredDone], isNull);
  });

  test('ios skips the clipboard when launched by a link', () async {
    final bridge = FakeBridge(
      clipboard: 'https://shop.lnk.example/t/token123',
      initial: 'https://shop.lnk.example/promo',
    );
    final server = FakeServer();
    await buildClient(bridge, server).start();
    await settle();
    expect(bridge.clipboardHosts, isNull);
    final body = server.bodyOf(server.calls('/v1/install').single);
    expect(body.containsKey('clipboard_url'), isFalse);
  });

  test('android sends the install referrer', () async {
    final bridge = FakeBridge(platform: 'android', referrer: 'dl_t%3Dtok', clipboard: 'https://ignored');
    final server = FakeServer();
    await buildClient(bridge, server).start();
    await settle();
    final body = server.bodyOf(server.calls('/v1/install').single);
    expect(body['install_referrer'], 'dl_t%3Dtok');
    expect(body.containsKey('clipboard_url'), isFalse);
  });

  test('a custom referrer provider wins over the play referrer', () async {
    final bridge = FakeBridge(platform: 'android', referrer: 'dl_t%3Dplay');
    final server = FakeServer();
    await buildClient(bridge, server, installReferrer: () async => 'rustore-token').start();
    await settle();
    expect(server.bodyOf(server.calls('/v1/install').single)['install_referrer'], 'rustore-token');
  });

  test('a failing or empty custom referrer falls back to the play referrer', () async {
    for (final provider in <InstallReferrerProvider>[() async => throw StateError('no store'), () async => '']) {
      final bridge = FakeBridge(platform: 'android', referrer: 'dl_t%3Dplay');
      final server = FakeServer();
      await buildClient(bridge, server, installReferrer: provider).start();
      await settle();
      expect(server.bodyOf(server.calls('/v1/install').single)['install_referrer'], 'dl_t%3Dplay');
    }
  });

  test('disabled client makes no requests until enabled', () async {
    final bridge = FakeBridge();
    final server = FakeServer();
    final client = buildClient(bridge, server, startDisabled: true);
    await client.start();
    final link = await client.handleUri(Uri.parse('https://shop.lnk.example/Promo'));
    await client.track('signup');
    await settle();
    expect(server.requests, isEmpty);
    expect(link.isResolved, isFalse);
    expect(link.path, '/Promo');
    expect(bridge.storage[StorageKeys.eventQueue], isNull);

    await client.enable();
    await settle();
    expect(server.calls('/v1/install'), hasLength(1));
    expect(bridge.storage[StorageKeys.consent], '1');

    final restarted = buildClient(bridge, FakeServer(), startDisabled: true);
    await restarted.start();
    expect(restarted.isEnabled, isTrue);
  });

  test('launch link is resolved and preferred as the initial link', () async {
    final bridge = FakeBridge(initial: 'https://shop.lnk.example/Open?x=1');
    final server = FakeServer()..installLink = null;
    final client = buildClient(bridge, server);
    await client.start();
    final initial = await client.getInitialLink();
    expect(initial?.source, DeepLinkSource.launch);
    expect(initial?.payload['from'], 'open');
    await settle();
    final opens = server.calls('/v1/open').map(server.bodyOf).toList();
    expect(opens, hasLength(1));
    expect(opens.single['source'], 'universal_link');
    expect(opens.single['url'], 'https://shop.lnk.example/Open?x=1');
  });

  test('organic session open is recorded when the app starts without a link', () async {
    final bridge = FakeBridge();
    final server = FakeServer()..installLink = null;
    final client = buildClient(bridge, server);
    await client.start();
    await settle();
    expect(await client.getInitialLink(), isNull);
    final open = server.bodyOf(server.calls('/v1/open').single);
    expect(open['source'], 'organic');
    expect(open.containsKey('url'), isFalse);
  });

  test('incoming links use the platform specific open source', () async {
    final bridge = FakeBridge(platform: 'android');
    final server = FakeServer()..installLink = null;
    final client = buildClient(bridge, server);
    await client.start();
    final received = <DeepLink>[];
    client.onLink.listen(received.add);
    bridge.incoming.add('https://shop.lnk.example/Promo');
    bridge.incoming.add('shop://item/1');
    await settle();
    final sources = server.calls('/v1/open').map((r) => server.bodyOf(r)['source']).toList();
    expect(sources, containsAll(['app_link', 'scheme']));
    expect(received.map((l) => l.source), everyElement(DeepLinkSource.foreground));
  });

  test('events are persisted, batched and dropped only on client errors', () async {
    final bridge = FakeBridge();
    final server = FakeServer()..eventsStatus = 503;
    final client = buildClient(bridge, server);
    await client.start();
    await client.track('signup', props: {'plan': 'pro'});
    await client.trackPurchase(amountMinor: 1999, currency: 'USD', productId: 'sku.pro');
    await settle();
    await client.flushEvents();
    final queued = jsonDecode(bridge.storage[StorageKeys.eventQueue]!) as List;
    expect(queued, hasLength(2));
    expect((queued[1] as Map)['revenue_minor'], 1999);
    expect(((queued[1] as Map)['properties'] as Map)['product_id'], 'sku.pro');

    server.eventsStatus = 200;
    await client.flushEvents();
    expect(bridge.storage[StorageKeys.eventQueue], isNull);
    final sent = server.bodyOf(server.calls('/v1/events').last);
    expect((sent['events']! as List).map((e) => (e as Map)['name']), ['signup', 'purchase']);

    server.eventsStatus = 400;
    await client.track('broken');
    await client.flushEvents();
    expect(bridge.storage[StorageKeys.eventQueue], isNull);
  });

  test('purchase and event validation', () async {
    final client = buildClient(FakeBridge(), FakeServer());
    await client.start();
    expect(() => client.trackPurchase(amountMinor: 100, currency: 'usd'), throwsArgumentError);
    expect(() => client.trackPurchase(amountMinor: -1, currency: 'USD'), throwsArgumentError);
    expect(() => client.track(''), throwsArgumentError);
    expect(() => client.track('x' * 65), throwsArgumentError);
  });

  test('user id syncs once and forget clears local state', () async {
    final bridge = FakeBridge();
    final server = FakeServer();
    final client = buildClient(bridge, server);
    await client.start();
    await settle();
    await client.setUserId('user-42');
    await client.setUserId('user-42');
    expect(server.calls('/v1/identify'), hasLength(2));
    expect(bridge.storage[StorageKeys.userIdSynced], 'user-42');

    await client.forget();
    expect(server.calls('/v1/forget'), hasLength(1));
    expect(bridge.storage.containsKey(StorageKeys.deferredDone), isFalse);
    expect(bridge.storage.containsKey(StorageKeys.userId), isFalse);
    expect(bridge.storage[StorageKeys.consent], '0');
    expect(client.isEnabled, isFalse);
  });

  test('consent flow still delivers the deferred link through getInitialLink', () async {
    final bridge = FakeBridge();
    final server = FakeServer();
    final client = buildClient(bridge, server, startDisabled: true);
    await client.start();
    expect(await client.getInitialLink(), isNull);
    await client.enable();
    final initial = await client.getInitialLink();
    expect(initial?.source, DeepLinkSource.deferred);
    expect(initial?.payload['product_id'], 42);
  });

  test('enable after disable restarts the session', () async {
    final bridge = FakeBridge();
    final server = FakeServer()..installLink = null;
    final client = buildClient(bridge, server);
    await client.start();
    await settle();
    await client.disable();
    await client.enable();
    await settle();
    expect(server.calls('/v1/install'), hasLength(1));
    expect(server.calls('/v1/open'), hasLength(2));
  });

  test('forget resets the install instance', () async {
    final bridge = FakeBridge();
    final server = FakeServer();
    final client = buildClient(bridge, server);
    await client.start();
    await settle();
    final before = bridge.storage[StorageKeys.installInstanceId];
    await client.forget();
    expect(bridge.storage.containsKey(StorageKeys.installInstanceId), isFalse);
    final again = buildClient(bridge, server);
    await again.enable();
    await settle();
    expect(server.bodyOf(server.calls('/v1/install').last)['install_instance_id'], isNot(before));
  });

  test('createLink returns the short url and surfaces server errors', () async {
    final server = FakeServer();
    final client = buildClient(FakeBridge(), server);
    await client.start();
    final created = await client.createLink(path: '/item/7', payload: {'item': 7});
    expect(created.url.toString(), 'https://shop.lnk.example/AbCdEf12');
    final body = server.bodyOf(server.calls('/v1/links').single);
    expect(body['deep_link_path'], '/item/7');
    expect(body.containsKey('campaign'), isFalse);
    expect(() => client.createLink(referral: true), throwsStateError);
  });

  test('referral token is exposed on the deferred link', () async {
    final client = buildClient(FakeBridge(), FakeServer());
    await client.start();
    final link = await client.getInitialLink();
    expect(link?.referralToken, 'ref.token');
    expect(link?.isReferral, isTrue);
  });

  test('base url validation', () {
    expect(validateBaseUrl('https://sdk.example.com').toString(), 'https://sdk.example.com/');
    expect(validateBaseUrl('http://10.0.2.2:8090/api').toString(), 'http://10.0.2.2:8090/api/');
    expect(() => validateBaseUrl('http://sdk.example.com'), throwsArgumentError);
    expect(() => validateBaseUrl('sdk.example.com'), throwsArgumentError);
  });
}
