# new_deeplinks

[![pub package](https://img.shields.io/pub/v/new_deeplinks.svg)](https://pub.dev/packages/new_deeplinks)
[![CI](https://github.com/Ellweb3/deeplinks-flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/Ellweb3/deeplinks-flutter/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Deep links, deferred deep linking and install attribution for Flutter apps, backed by **your own server**.

`new_deeplinks` is the Flutter client for [spbse](https://spbse.online), a self-hosted replacement for Branch, AppsFlyer OneLink and Firebase Dynamic Links. Clicks, installs and revenue stay in your PostgreSQL, and no advertising identifiers are collected.

- **Universal Links and App Links**: one stream for every link the app receives.
- **Deferred deep linking**: a user taps a link without the app installed, installs it from the store, and the first launch opens the right screen instead of the home screen.
- **Install attribution**: deterministic matching through the store referrer on Android and the clipboard on iOS, with a server-side fallback when neither is available.
- **App Store, Google Play and RuStore.**
- **Events and revenue** with last-link attribution, a persistent offline queue and idempotent delivery.
- **Links from the app**: share links and referral invites.
- **Consent first**: start disabled, enable after consent, forget the device on request.

| | |
|---|---|
| Flutter | 3.38+ |
| iOS | 15.0+, CocoaPods or Swift Package Manager |
| Android | minSdk 24 |

## Contents

- [How it works](#how-it-works)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Platform setup](#platform-setup)
- [Usage](#usage)
- [Privacy](#privacy)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Example app](#example-app)
- [Contributing](#contributing)

## How it works

```
 click on https://go.example.com/summer
   │
   ├─ app installed ──► Universal Link / App Link ──► onLink (launch / foreground)
   │
   └─ not installed ──► link page ──► App Store / Google Play / RuStore ──► install
                        ──► first launch: the server matches the install to the click
                        ──► onLink (deferred)
```

How a deferred link is matched:

1. **Install referrer** (Android): exact. Works for installs from Google Play, including internal testing, and from RuStore through [`installReferrer`](#rustore-and-other-stores).
2. **Clipboard** (iOS): exact. The link page leaves a link on one of your `linkDomains` in the clipboard; iOS asks the user to allow pasting.
3. **Fallback**: when neither is available, the server makes a probabilistic match and returns a link only when it is confident enough.

## Installation

```bash
flutter pub add new_deeplinks
```

You need a running spbse server with an app created in it. The app gives you two values:

- the **SDK host** of the server, for example `https://sdk.example.com`;
- the app's **public SDK key**, `dl_pk_…` (`sdk_public_key` in the management API). It is safe to ship in the app.

## Quick start

```dart
import 'package:new_deeplinks/new_deeplinks.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DeepLinks.init(
    baseUrl: 'https://sdk.example.com',
    appKey: 'dl_pk_…',
    linkDomains: ['go.example.com'],
  );
  runApp(const App());
}
```

Route on every link, including the deferred one:

```dart
DeepLinks.onLink.listen((link) {
  final path = link.path;
  if (path != null) router.push(path, extra: link.payload);
});
```

`onLink` buffers events until the first listener subscribes, so the launch link and the deferred link are not lost when you subscribe after the first frame.

If you only need the link the app started with:

```dart
final link = await DeepLinks.getInitialLink();
```

It returns the launch link, or the deferred link on the first launch after install, or `null`.

## Platform setup

### iOS

1. In Xcode, add the **Associated Domains** capability with an entry for every link host:

   ```
   applinks:go.example.com
   ```

   During development you can use `applinks:go.example.com?mode=developer` to skip Apple's CDN cache.

2. If the SDK captures links (`captureLinks: true`, the default), turn off Flutter's built-in deep linking in `ios/Runner/Info.plist`:

   ```xml
   <key>FlutterDeepLinkingEnabled</key>
   <false/>
   ```

3. For a custom URL scheme, add it to `CFBundleURLTypes` as usual.

4. On the server, set the app's `ios_team_id`, `ios_bundle_id` and `ios_app_store_id`. The server serves `apple-app-site-association` from these values.

iOS caches the association at install time. After changing the server's AASA settings, reinstall the app.

### Android

1. In `android/app/src/main/AndroidManifest.xml`, add an intent filter to the main activity for every link host, and turn off Flutter's built-in deep linking:

   ```xml
   <activity android:name=".MainActivity" ...>
     <intent-filter android:autoVerify="true">
       <action android:name="android.intent.action.VIEW" />
       <category android:name="android.intent.category.DEFAULT" />
       <category android:name="android.intent.category.BROWSABLE" />
       <data android:scheme="https" android:host="go.example.com" />
     </intent-filter>
     <meta-data android:name="flutter_deeplinking_enabled" android:value="false" />
   </activity>
   ```

2. On the server, set the app's `android_package` and `android_sha256_fingerprints`. Include the **Play App Signing** key from Google Play Console, otherwise App Links fail verification for store builds. Add your debug key's fingerprint to test debug builds:

   ```bash
   keytool -list -v -keystore ~/.android/debug.keystore -storepass android | grep SHA256
   ```

3. Check the verification on a device:

   ```bash
   adb shell pm verify-app-links --re-verify com.example.app
   adb shell pm get-app-links com.example.app
   ```

The Google Play Install Referrer is read automatically. Sideloaded installs have an empty referrer and use the fallback match.

### RuStore and other stores

Set `settings.android_store` to `"rustore"` for the app on the server, so links send Android users to RuStore. In the app, read the RuStore referrer with the RuStore Install Referrer SDK and pass it to the SDK:

```dart
await DeepLinks.init(
  baseUrl: 'https://sdk.example.com',
  appKey: 'dl_pk_…',
  installReferrer: () async => readRuStoreReferrerId(),
);
```

`readRuStoreReferrerId` is your own wrapper around the RuStore SDK. The function runs on Android before the Google Play referrer, with a 5 second timeout. If it fails or returns `null`, the SDK falls back to the Google Play referrer. The same hook works for any other store that passes a referrer.

## Usage

### Options

| Parameter | Default | |
|---|---|---|
| `baseUrl` | required | SDK host of your server. `https` only; plain `http` is accepted for `localhost`, `10.0.2.2` and `*.localhost`. |
| `appKey` | required | Public SDK key, `dl_pk_…`. |
| `linkDomains` | `[]` | Short link hosts of the app. On iOS the clipboard is read only for these hosts. |
| `startDisabled` | `false` | No network calls until `enable()`. See [Privacy](#privacy). |
| `captureLinks` | `true` | Receive Universal Links and App Links natively. Turn off when another package handles links. |
| `installReferrer` | `null` | Referrer from a store other than Google Play. |
| `httpClient` | `null` | Custom `http.Client`, for proxies or tests. |
| `bridge` | `null` | Custom `NativeBridge`, for tests. |

### The `DeepLink` object

| Field | |
|---|---|
| `source` | `launch`, `deferred`, `foreground` or `manual`. |
| `path` | The in-app route set on the link, such as `/product/42`. |
| `payload` | Custom data set on the link. |
| `utm`, `campaign`, `channel` | Marketing fields of the link. |
| `variant` | A/B variant chosen by the link's targeting rules. |
| `uri`, `shortUrl`, `code`, `linkId` | The link itself. |
| `matchMethod`, `confidence` | For deferred links: how the install was matched, and a confidence from 0 to 1. |
| `isReinstall` | The device had the app before. |
| `isResolved` | The server recognised the link. Unresolved links carry only `uri` and `path`. |
| `referralToken` | Present for referral invites. |

### When another package handles links

If the app already uses `go_router`, `app_links` or similar to receive links, keep it and pass each URI to the SDK:

```dart
await DeepLinks.init(
  baseUrl: 'https://sdk.example.com',
  appKey: 'dl_pk_…',
  captureLinks: false,
);

final link = await DeepLinks.handleUri(uri);
```

`handleUri` resolves the short link into its path and payload through the server and records the open for last-click attribution. The result is also emitted on `onLink`. Deferred links still arrive on `onLink` as usual.

### Events and revenue

```dart
await DeepLinks.track('signup', props: {'plan': 'pro'});
await DeepLinks.trackPurchase(amountMinor: 1999, currency: 'USD', productId: 'pro_monthly');
await DeepLinks.setUserId('user-42');
```

- Events are attributed to the last link that brought the user: the install link or a later open.
- `amountMinor` is in minor units: 1999 means 19.99.
- Events go into a persistent queue of up to 500 events and are sent in batches. Network errors, 408, 429 and 5xx are retried later; other 4xx responses drop the event. Each event has a client id, so retries never double count.
- `setUserId` links the install to your user, so webhooks and exports can be joined with your data.

### Links from the app

```dart
final link = await DeepLinks.createLink(
  path: '/product/42',
  payload: {'id': 42},
  channel: 'share',
  ogTitle: 'Look at this',
);
Share.share(link.url.toString());
```

Referral invites carry the current user id, so call `setUserId` first:

```dart
await DeepLinks.setUserId('user-42');
final invite = await DeepLinks.createLink(path: '/invite', referral: true);
```

A new user who installs through the invite gets `link.referralToken`. Send it to your backend together with the new user's id and exchange it there with `POST /v1/referrals/claim`, using the secret management key. The response names the inviting user, and the server sends a `referral` webhook. Each install can be claimed once.

## Privacy

- **No advertising identifiers.** The SDK does not read IDFA or the Android Advertising ID and needs no App Tracking Transparency prompt.
- **Device id.** On iOS a random id kept in the Keychain (`AfterFirstUnlockThisDeviceOnly`): it survives reinstalls but never leaves the device. On Android `SHA-256(app key + ANDROID_ID)`: stable across reinstalls and different for every app. The server uses it to tell a reinstall from a first install.
- **Clipboard.** Read only until the first install is registered, only when iOS reports a probable URL, only if the link is on one of your `linkDomains`, and never on a launch by a link. The SDK clears its own token from the clipboard after reading.
- **Consent.**

  ```dart
  await DeepLinks.init(baseUrl: …, appKey: …, startDisabled: true);
  // after the user agrees
  await DeepLinks.enable();
  ```

  - `startDisabled: true` keeps the SDK offline until `enable()`. The choice is stored and survives restarts.
  - `disable()` stops sending and clears the event queue.
  - `forget()` deletes the device's data on the server and locally, then disables the SDK. Use it for account deletion and data erasure requests.

- **App Store privacy manifest.** The plugin ships `PrivacyInfo.xcprivacy` declaring UserDefaults access (`CA92.1`) and Device ID collection for app functionality and analytics, not tracking.
- **Google Play Data safety.** Declare collection of *Device or other IDs* for *Analytics* and *App functionality*. SDK flags live in `noBackupFilesDir`, so Auto Backup does not restore them on another device.

## Testing

Pass your own bridge and HTTP client to run the SDK in widget or unit tests without a device or server:

```dart
setUp(() async {
  await DeepLinks.reset();
  await DeepLinks.init(
    baseUrl: 'https://sdk.test.localhost',
    appKey: 'dl_pk_test',
    bridge: FakeBridge(),
    httpClient: MockClient((request) async => http.Response('{}', 200)),
  );
});
```

`NativeBridge` is a small interface: device info, key-value storage, install referrer, clipboard link, initial link and a stream of links. See [`test/client_test.dart`](test/client_test.dart) for a complete fake.

To test deferred deep linking by hand:

- **Android emulator**: uninstall the app, open the short link in Chrome, then install a debug build and launch it. Without Google Play the referrer is empty, so the fallback match is used.
- **iOS Simulator**: uninstall the app, open the short link in Safari, tap *Open in the app* (the simulator has no App Store, so Safari shows an error, which is fine), then install and launch the app and allow pasting.

## Troubleshooting

**Links open the browser instead of the app.**
On iOS, check that the entitlement host matches the link host exactly and reinstall the app after any server change. On Android, run `adb shell pm get-app-links <package>`; anything other than `verified` means a wrong package name or a missing SHA-256 fingerprint on the server.

**The deferred link is `null`.**
Open the install in the dashboard to see how the server tried to match it. Common causes: more time passed between the click and the first launch than the app's attribution window, the app has no App Store ID on the server so the iOS link page skips the clipboard step, or the user denied the paste prompt on iOS.

**`ArgumentError: must be the public sdk key`.**
`appKey` must be the public SDK key `dl_pk_…`, not the secret management key `dl_sk_…`. Never ship a secret key in an app.

**`StateError: DeepLinks.init must be called first`.**
Call and await `DeepLinks.init` before using any other method, usually in `main`.

**Links arrive twice.**
Either Flutter's built-in deep linking is still on (see the platform setup) or links are handled by another package while `captureLinks` is `true`.

## Example app

[`example/`](example) is a go_router app that shows every link the SDK receives and has buttons for each API call. Run it against your server:

```bash
cd example
flutter run \
  --dart-define=DL_BASE_URL=https://sdk.example.com \
  --dart-define=DL_APP_KEY=dl_pk_… \
  --dart-define=DL_LINK_HOST=go.example.com \
  -P dlLinkHost=go.example.com
```

On iOS, set the `DL_LINK_HOST` build setting of the Runner target to your link host and pick your own development team.

## Contributing

Issues and pull requests are welcome.

```bash
git clone https://github.com/Ellweb3/deeplinks-flutter.git new_deeplinks
cd new_deeplinks
flutter pub get
flutter analyze
flutter test
```

Clone into a folder named `new_deeplinks`. With Swift Package Manager, Xcode requires the plugin folder name to match the package name when the example app is built from inside the repository; apps that depend on the published package are not affected.

Native unit tests for Android live in `android/src/test`.

## License

MIT, see [LICENSE](LICENSE). Parts of the deferred link handling are based on [smler_deferred_link](https://pub.dev/packages/smler_deferred_link) (MIT); see [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
