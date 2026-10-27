import 'dart:async';

import 'package:new_deeplinks/new_deeplinks.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

const baseUrl = String.fromEnvironment('DL_BASE_URL', defaultValue: 'http://10.0.2.2:8090');
const appKey = String.fromEnvironment('DL_APP_KEY', defaultValue: 'dl_pk_replace_me');
const linkDomain = String.fromEnvironment('DL_LINK_HOST', defaultValue: 'links.example.com');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DeepLinks.init(baseUrl: baseUrl, appKey: appKey, linkDomains: const [linkDomain]);
  runApp(const ExampleApp());
}

class LinkLog extends ChangeNotifier {
  final List<DeepLink> entries = [];

  void add(DeepLink link) {
    entries.insert(0, link);
    notifyListeners();
  }
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  final LinkLog _log = LinkLog();
  late final GoRouter _router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => HomePage(log: _log),
      ),
      GoRoute(
        path: '/product/:id',
        builder: (_, state) => ProductPage(id: state.pathParameters['id']!, link: state.extra as DeepLink?),
      ),
    ],
  );
  StreamSubscription<DeepLink>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = DeepLinks.onLink.listen(_open);
  }

  void _open(DeepLink link) {
    _log.add(link);
    final path = link.path;
    if (path != null && path.startsWith('/product/')) {
      _router.push(path, extra: link);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'DeepLinks example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    routerConfig: _router,
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.log});

  final LinkLog log;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _uri = TextEditingController(text: 'https://$linkDomain/promo');
  String _initial = 'waiting…';
  String _status = '';

  @override
  void initState() {
    super.initState();
    DeepLinks.getInitialLink().then((link) {
      if (mounted) setState(() => _initial = link?.toString() ?? 'none');
    });
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    try {
      await action();
      setState(() => _status = '$label: ok');
    } catch (e) {
      setState(() => _status = '$label: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('DeepLinks')),
    body: ListenableBuilder(
      listenable: widget.log,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Server: $baseUrl', style: Theme.of(context).textTheme.bodySmall),
          Text('Tracking enabled: ${DeepLinks.isEnabled}'),
          const SizedBox(height: 8),
          Text('Initial link: $_initial'),
          const Divider(),
          TextField(
            controller: _uri,
            decoration: const InputDecoration(labelText: 'URI for handleUri'),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: () => _run('handleUri', () => DeepLinks.handleUri(Uri.parse(_uri.text))),
                child: const Text('handleUri'),
              ),
              OutlinedButton(
                onPressed: () => _run('track', () => DeepLinks.track('example_tap', props: {'screen': 'home'})),
                child: const Text('track'),
              ),
              OutlinedButton(
                onPressed: () => _run('purchase', () => DeepLinks.trackPurchase(amountMinor: 499, currency: 'USD')),
                child: const Text('purchase'),
              ),
              OutlinedButton(
                onPressed: () => _run('identify', () => DeepLinks.setUserId('example-user')),
                child: const Text('setUserId'),
              ),
              OutlinedButton(
                onPressed: () => _run(
                  DeepLinks.isEnabled ? 'disable' : 'enable',
                  () => DeepLinks.isEnabled ? DeepLinks.disable() : DeepLinks.enable(),
                ),
                child: Text(DeepLinks.isEnabled ? 'disable' : 'enable'),
              ),
              OutlinedButton(onPressed: () => _run('forget', DeepLinks.forget), child: const Text('forget')),
            ],
          ),
          if (_status.isNotEmpty) Text(_status),
          const Divider(),
          Text('Received links', style: Theme.of(context).textTheme.titleMedium),
          for (final link in widget.log.entries)
            Card(
              child: ListTile(
                title: Text('${link.source.name} · ${link.path ?? link.uri}'),
                subtitle: Text(
                  'method: ${link.matchMethod ?? '-'}  confidence: ${link.confidence ?? '-'}\n'
                  'payload: ${link.payload}  utm: ${link.utm}',
                ),
                isThreeLine: true,
              ),
            ),
        ],
      ),
    ),
  );
}

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.id, this.link});

  final String id;
  final DeepLink? link;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Product $id')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Text('Opened from ${link?.source.name ?? 'navigation'}\npayload: ${link?.payload ?? {}}'),
    ),
  );
}
