## 0.1.1

- iOS: the clipboard is no longer read when the app is launched by a link, so the paste prompt does not appear on that launch.

## 0.1.0

- First public release.
- Universal Links and App Links in a single `onLink` stream, with `getInitialLink` and `handleUri` for apps that receive links through another package.
- Deferred deep linking through the Google Play Install Referrer, a custom referrer hook for RuStore and other stores, the iOS clipboard and a server-side fallback.
- Events and purchases with a persistent offline queue and last-link attribution.
- Share and referral links from the app with `createLink`.
- Consent controls: `startDisabled`, `enable`, `disable` and `forget`.
- iOS privacy manifest; CocoaPods and Swift Package Manager support.
