// Session orchestrator for the thread-ripper engine.
//
// Primary path: DASH video/audio play urls -> per-video CDN pool ->
// hedged concurrent Range fetching -> loopback proxy -> mpv.
// Fallback path: the existing manual CDN logic (VideoUtils.getCdnUrl +
// CdnSelectDialog) is intentionally left untouched; callers fall back to it
// whenever the engine is disabled or fails to start.
library;

import 'package:PiliPlus/services/thread_ripper/ripper_proxy_server.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

enum RipperCdnMode {
  mainland('大陆 CDN'),
  overseas('海外 CDN');

  const RipperCdnMode(this.label);

  final String label;

  static RipperCdnMode fromName(String? name) => RipperCdnMode.values
      .firstWhere((e) => e.name == name, orElse: () => overseas);
}

/// Resolved playback urls for one video session.
class RipperSources {
  const RipperSources({required this.video, required this.audio});

  final String video;
  final String? audio;
}

class ThreadRipper {
  ThreadRipper._();

  static final ThreadRipper instance = ThreadRipper._();

  RipperProxyServer? _server;

  bool get enabled => Pref.threadRipperEnabled;

  bool get active => _server != null;

  /// Starts a proxy session for one DASH video. Returns null when the engine
  /// is disabled or cannot start, in which case the caller must use the
  /// manual CDN fallback.
  Future<RipperSources?> startForDash({
    required Iterable<String> videoPlayUrls,
    required Iterable<String> audioPlayUrls,
  }) async {
    await stop();
    if (!enabled) return null;
    final videoList = videoPlayUrls.where((u) => u.isNotEmpty).toList();
    if (videoList.isEmpty) return null;
    try {
      final server = await RipperProxyServer.start(
        videoPlayUrls: videoList,
        audioPlayUrls: audioPlayUrls.where((u) => u.isNotEmpty),
        overseas:
            RipperCdnMode.fromName(Pref.threadRipperCdnModeName) ==
            RipperCdnMode.overseas,
        concurrency: Pref.threadRipperConcurrency,
      ).timeout(const Duration(seconds: 20));
      if (server == null) return null;
      _server = server;
      return RipperSources(
        video: server.videoProxyUrl,
        audio: server.audioProxyUrl,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[ripper] session start failed: $e');
      await stop();
      return null;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.stop();
      } catch (_) {}
    }
  }
}
