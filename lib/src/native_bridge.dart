import 'dart:async';

import 'package:flutter/services.dart';

/// Device signals the native side reports for install matching.
class DeviceInfo {
  const DeviceInfo({
    required this.deviceId,
    required this.platform,
    this.osVersion,
    this.deviceModel,
    this.screenWidth,
    this.screenHeight,
    this.pixelRatio,
    this.timezone,
    this.language,
    this.appVersion,
  });

  /// Stable per-app device id: Keychain on iOS, a hash of `ANDROID_ID` and the app key on Android.
  final String deviceId;

  /// `ios` or `android`.
  final String platform;

  /// OS version.
  final String? osVersion;

  /// Hardware model.
  final String? deviceModel;

  /// Screen width in physical pixels.
  final int? screenWidth;

  /// Screen height in physical pixels.
  final int? screenHeight;

  /// Device pixel ratio.
  final double? pixelRatio;

  /// IANA time zone.
  final String? timezone;

  /// Preferred language tag.
  final String? language;

  /// App version.
  final String? appVersion;

  /// The matching signals sent to the server.
  Map<String, Object?> signals() => {
    'os_version': osVersion,
    'device_model': deviceModel,
    'screen_w': screenWidth,
    'screen_h': screenHeight,
    'dpr': pixelRatio,
    'timezone': timezone,
    'language': language,
  }..removeWhere((_, v) => v == null);

  /// Parses the platform channel response.
  factory DeviceInfo.fromMap(Map<Object?, Object?> map) => DeviceInfo(
    deviceId: map['device_id']! as String,
    platform: map['platform']! as String,
    osVersion: map['os_version'] as String?,
    deviceModel: map['device_model'] as String?,
    screenWidth: (map['screen_w'] as num?)?.round(),
    screenHeight: (map['screen_h'] as num?)?.round(),
    pixelRatio: (map['dpr'] as num?)?.toDouble(),
    timezone: map['timezone'] as String?,
    language: map['language'] as String?,
    appVersion: map['app_version'] as String?,
  );
}

/// Platform side of the SDK. Replace it in tests via `DeepLinks.init(bridge: …)`.
abstract class NativeBridge {
  /// Device signals.
  Future<DeviceInfo> deviceInfo(String appKey);

  /// Reads a value from SDK storage.
  Future<String?> storageGet(String key);

  /// Writes a value to SDK storage.
  Future<void> storageSet(String key, String value);

  /// Removes a value from SDK storage.
  Future<void> storageRemove(String key);

  /// The Google Play install referrer, or `null`.
  Future<String?> installReferrer();

  /// A click token link from the clipboard on one of [hosts], or `null`.
  Future<String?> clipboardLink(List<String> hosts);

  /// The link that launched the app.
  Future<String?> initialLink();

  /// Links opened while the app runs.
  Stream<String> get links;
}

class MethodChannelBridge implements NativeBridge {
  MethodChannelBridge({
    MethodChannel methods = const MethodChannel('io.deeplinks/sdk'),
    EventChannel events = const EventChannel('io.deeplinks/links'),
  }) : _methods = methods,
       _events = events;

  final MethodChannel _methods;
  final EventChannel _events;
  Stream<String>? _links;

  @override
  Future<DeviceInfo> deviceInfo(String appKey) async {
    final map = await _methods.invokeMapMethod<Object?, Object?>('deviceInfo', {'app_key': appKey});
    return DeviceInfo.fromMap(map!);
  }

  @override
  Future<String?> storageGet(String key) => _methods.invokeMethod<String>('storageGet', {'key': key});

  @override
  Future<void> storageSet(String key, String value) =>
      _methods.invokeMethod<void>('storageSet', {'key': key, 'value': value});

  @override
  Future<void> storageRemove(String key) => _methods.invokeMethod<void>('storageRemove', {'key': key});

  @override
  Future<String?> installReferrer() => _optional('installReferrer');

  @override
  Future<String?> clipboardLink(List<String> hosts) => _optional('clipboardLink', {'hosts': hosts});

  @override
  Future<String?> initialLink() => _methods.invokeMethod<String>('initialLink');

  @override
  Stream<String> get links => _links ??= _events.receiveBroadcastStream().where((e) => e is String).cast<String>();

  Future<String?> _optional(String method, [Object? arguments]) async {
    try {
      return await _methods.invokeMethod<String>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
