import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/utils/device_utils.dart';
import 'package:flutter/services.dart'
    show
        SystemChrome,
        MethodChannel,
        SystemUiOverlay,
        SystemUiMode,
        DeviceOrientation;

bool _isDesktopFullScreen = false;

@pragma('vm:notify-debugger-on-exception')
Future<void> enterDesktopFullScreen({bool inAppFullScreen = false}) async {
  if (!inAppFullScreen && !_isDesktopFullScreen) {
    _isDesktopFullScreen = true;
    try {
      await const MethodChannel(
        'com.alexmercerind/media_kit_video',
      ).invokeMethod('Utils.EnterNativeFullscreen');
    } catch (_) {}
  }
}

@pragma('vm:notify-debugger-on-exception')
Future<void> exitDesktopFullScreen() async {
  if (_isDesktopFullScreen) {
    _isDesktopFullScreen = false;
    try {
      await const MethodChannel(
        'com.alexmercerind/media_kit_video',
      ).invokeMethod('Utils.ExitNativeFullscreen');
    } catch (_) {}
  }
}

List<DeviceOrientation>? _lastOrientation;
List<DeviceOrientation>? _requestedOrientation;
Future<void>? _setPreferredOrientations(
  List<DeviceOrientation> orientations, {
  bool force = false,
}) {
  // Remember intent before awaiting the platform, including during rotation.
  _requestedOrientation = orientations;
  if (!force && _lastOrientation == orientations) {
    return null;
  }
  return SystemChrome.setPreferredOrientations(orientations).then((_) {
    if (_requestedOrientation == orientations) {
      _lastOrientation = orientations;
    }
  });
}

Future<void>? portraitUpMode() {
  return _setPreferredOrientations(const [.portraitUp]);
}

Future<void>? portraitDownMode() {
  return _setPreferredOrientations(const [.portraitDown]);
}

Future<void>? landscapeLeftMode() {
  return _setPreferredOrientations(const [.landscapeLeft]);
}

Future<void>? landscapeRightMode() {
  return _setPreferredOrientations(const [.landscapeRight]);
}

Future<void>? fullMode() {
  return _setPreferredOrientations(
    const [.portraitUp, .portraitDown, .landscapeLeft, .landscapeRight],
  );
}

bool _showSystemBar = true;
bool get showSystemBar_ => _showSystemBar;

// Focus returns after the notification shade or another app's floating window.
// Reapply the current page's intent, rather than the startup portrait default.
Future<void> restoreAndroidSystemChrome({required bool horizontalScreen}) async {
  await _setPreferredOrientations(
    _requestedOrientation ??
        (horizontalScreen
            ? const [
                DeviceOrientation.portraitUp,
                DeviceOrientation.portraitDown,
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp]),
    force: true,
  );
  await SystemChrome.setEnabledSystemUIMode(
    _showSystemBar ? _shownSystemUiMode : SystemUiMode.immersiveSticky,
    overlays: SystemUiOverlay.values,
  );
}

SystemUiMode get _shownSystemUiMode =>
    Platform.isAndroid && DeviceUtils.sdkInt < 29
    ? SystemUiMode.manual
    : SystemUiMode.edgeToEdge;

Future<void>? hideSystemBar() {
  if (!_showSystemBar) {
    return null;
  }
  _showSystemBar = false;
  return SystemChrome.setEnabledSystemUIMode(.immersiveSticky);
}

//退出全屏显示
Future<void>? showSystemBar() {
  if (_showSystemBar) {
    return null;
  }
  _showSystemBar = true;
  return SystemChrome.setEnabledSystemUIMode(
    _shownSystemUiMode,
    overlays: SystemUiOverlay.values,
  );
}
