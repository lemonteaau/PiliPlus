import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    await portraitUpMode();
    await showSystemBar();
    calls.clear();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  List<MethodCall> orientationCalls() => calls
      .where((call) => call.method == 'SystemChrome.setPreferredOrientations')
      .toList();

  Object? lastUiMode() => calls
      .lastWhere((call) => call.method == 'SystemChrome.setEnabledSystemUIMode')
      .arguments;

  for (final direction in [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]) {
    test('focus return preserves $direction and immersive fullscreen', () async {
      await (direction == DeviceOrientation.landscapeLeft
          ? landscapeLeftMode()
          : landscapeRightMode());
      await hideSystemBar();
      calls.clear();

      // The app's normal pages are portrait, as with system rotation locked.
      await restoreAndroidSystemChrome(horizontalScreen: false);
      await restoreAndroidSystemChrome(horizontalScreen: false);

      expect(orientationCalls(), hasLength(2));
      for (final call in orientationCalls()) {
        expect(call.arguments, [direction.toString()]);
      }
      expect(lastUiMode(), 'SystemUiMode.immersiveSticky');
    });
  }

  test('focus return after exiting fullscreen preserves portrait and bars', () async {
    await landscapeLeftMode();
    await hideSystemBar();
    await portraitUpMode();
    await showSystemBar();
    calls.clear();

    await restoreAndroidSystemChrome(horizontalScreen: false);

    expect(orientationCalls().single.arguments, [
      'DeviceOrientation.portraitUp',
    ]);
    expect(lastUiMode(), 'SystemUiMode.edgeToEdge');
  });

  test('focus return preserves the current choice with horizontal pages enabled',
      () async {
    await landscapeRightMode();
    calls.clear();

    await restoreAndroidSystemChrome(horizontalScreen: true);

    expect(orientationCalls().single.arguments, [
      'DeviceOrientation.landscapeRight',
    ]);
  });

  test('focus return preserves a fullscreen rotation still awaiting the platform',
      () async {
    final pendingRotation = Completer<Object?>();
    final rotationStarted = Completer<void>();
    var delayFirstRequest = true;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      if (call.method == 'SystemChrome.setPreferredOrientations' &&
          delayFirstRequest) {
        delayFirstRequest = false;
        rotationStarted.complete();
        return pendingRotation.future;
      }
      return null;
    });

    final enteringFullscreen = landscapeLeftMode();
    await rotationStarted.future;
    calls.clear();
    try {
      await restoreAndroidSystemChrome(horizontalScreen: false);
      expect(orientationCalls().single.arguments, [
        'DeviceOrientation.landscapeLeft',
      ]);
    } finally {
      pendingRotation.complete(null);
      await enteringFullscreen;
    }
  });
}
