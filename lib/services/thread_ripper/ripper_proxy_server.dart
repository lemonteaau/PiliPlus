// Local loopback HTTP proxy that feeds mpv/media_kit with bytes fetched
// through the thread-ripper engine. Each player Range request is fanned out
// into concurrent upstream sub-ranges (IDM-style) across the CDN pool.
library;

import 'dart:async' show unawaited;
import 'dart:io'
    show
        ContentType,
        HttpHeaders,
        HttpRequest,
        HttpServer,
        HttpStatus,
        InternetAddress;

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/idm_downloader.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// Above this size a player request is streamed window-by-window so a seek
/// near the end of a large file never buffers the whole tail in memory.
const int _singleShotLimit = 16 * 1024 * 1024;
const int _streamWindow = 4 * 1024 * 1024;

class _Mount {
  _Mount({required this.urls, required this.contentType});

  final List<String> urls;
  final String contentType;
  int? totalLength;
}

class RipperProxyServer {
  RipperProxyServer._(
    this._server,
    this._downloader,
    this._mounts,
    this._resolvers,
    this._concurrency,
    this._overseas,
  );

  final HttpServer _server;
  final RipperDownloader _downloader;
  final Map<String, _Mount> _mounts;
  final Map<String, CdnResolver> _resolvers;
  final int _concurrency;
  final bool _overseas;

  int requests = 0;
  int bytesServed = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<RipperProxyServer?> start({
    required Iterable<String> videoPlayUrls,
    required Iterable<String> audioPlayUrls,
    required bool overseas,
    required int concurrency,
    Dio? dio,
  }) async {
    final banList = CdnBanList();
    final videoUrls = ripperCandidateUrls(videoPlayUrls, overseas: overseas);
    final audioUrls = ripperCandidateUrls(audioPlayUrls, overseas: overseas);
    if (videoUrls.isEmpty) return null;
    final downloader = RipperDownloader(
      dio: dio,
      concurrency: concurrency,
    );
    final mounts = <String, _Mount>{
      '/video': _Mount(urls: videoUrls, contentType: 'video/mp4'),
      if (audioUrls.isNotEmpty)
        '/audio': _Mount(urls: audioUrls, contentType: 'audio/mp4'),
    };
    final resolvers = {
      for (final entry in mounts.entries)
        entry.key: CdnResolver(entry.value.urls, banList: banList),
    };
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxy = RipperProxyServer._(
        server,
        downloader,
        mounts,
        resolvers,
        concurrency,
        overseas,
      );
      server.listen(proxy._handle);
      return proxy;
    } catch (e) {
      if (kDebugMode) debugPrint('[ripper] proxy bind failed: $e');
      return null;
    }
  }

  bool get hasAudio => _mounts.containsKey('/audio');

  String get videoProxyUrl => '$baseUrl/video';

  String? get audioProxyUrl => hasAudio ? '$baseUrl/audio' : null;

  Future<void> stop() async {
    try {
      await _server.close(force: true);
    } catch (_) {}
  }

  Future<void> _handle(HttpRequest req) async {
    final mount = _mounts[req.uri.path];
    if (mount == null) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final method = req.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      req.response.statusCode = HttpStatus.methodNotAllowed;
      await req.response.close();
      return;
    }
    requests++;
    final outer = CancelToken();
    unawaited(
      req.response.done.then((_) {
        if (!outer.isCancelled) outer.cancel('client gone');
      }),
    );
    try {
      final resolver = _resolvers[req.uri.path]!;
      mount.totalLength ??= await _downloader.probeTotalLength(
        resolver,
        outer,
      );
      final total = mount.totalLength;
      if (total == null || total <= 0) {
        throw RipperHttpException('cannot determine media length');
      }
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      if (method == 'HEAD') {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        req.response.headers.contentType = mount.contentType == 'audio/mp4'
            ? ContentType('audio', 'mp4')
            : ContentType('video', 'mp4');
        req.response.contentLength = total;
        await req.response.close();
        return;
      }
      if (rangeHeader == null) {
        await _serveWindowed(
          req,
          resolver,
          mount,
          0,
          total - 1,
          total,
          outer,
        );
        return;
      }
      final range = _parseRequestRange(rangeHeader, total);
      if (range == null) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$total',
        );
        await req.response.close();
        return;
      }
      final length = range.end - range.start + 1;
      if (length <= _singleShotLimit) {
        final result = await _downloader.downloadRange(
          range.start,
          range.end,
          resolver,
          outer,
          preferredUrls: resolver.rangeCandidates(overseas: _overseas),
          concurrency: _concurrency,
        );
        bytesServed += result.bytes.length;
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        req.response.headers.contentType = mount.contentType == 'audio/mp4'
            ? ContentType('audio', 'mp4')
            : ContentType('video', 'mp4');
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$total',
        );
        req.response.contentLength = result.bytes.length;
        req.response.add(result.bytes);
        await req.response.close();
        return;
      }
      await _serveWindowed(
        req,
        resolver,
        mount,
        range.start,
        range.end,
        total,
        outer,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[ripper] proxy serve failed: $e');
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    }
  }

  ByteRange? _parseRequestRange(String header, int total) {
    // Supports `bytes=A-B` and open-ended `bytes=A-`; multi-range is rejected.
    final single = RegExp(
      r'^bytes=(\d+)-(\d*)$',
      caseSensitive: false,
    ).firstMatch(header.trim());
    if (single == null) return null;
    final start = int.tryParse(single.group(1)!);
    if (start == null || start >= total) return null;
    final endRaw = single.group(2)!;
    final end = endRaw.isEmpty ? total - 1 : int.tryParse(endRaw);
    if (end == null || end < start) return null;
    return ByteRange(start, end > total - 1 ? total - 1 : end);
  }

  Future<void> _serveWindowed(
    HttpRequest req,
    CdnResolver resolver,
    _Mount mount,
    int start,
    int end,
    int total,
    CancelToken outer,
  ) async {
    final isFull = start == 0 && end == total - 1;
    req.response.statusCode = isFull
        ? HttpStatus.ok
        : HttpStatus.partialContent;
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    req.response.headers.contentType = mount.contentType == 'audio/mp4'
        ? ContentType('audio', 'mp4')
        : ContentType('video', 'mp4');
    if (!isFull) {
      req.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$total',
      );
    }
    req.response.contentLength = end - start + 1;
    var cursor = start;
    while (cursor <= end) {
      if (outer.isCancelled) break;
      final windowEnd = cursor + _streamWindow - 1 > end
          ? end
          : cursor + _streamWindow - 1;
      final result = await _downloader.downloadRange(
        cursor,
        windowEnd,
        resolver,
        outer,
        preferredUrls: resolver.rangeCandidates(overseas: _overseas),
        startup: cursor == start,
        concurrency: _concurrency,
      );
      bytesServed += result.bytes.length;
      req.response.add(result.bytes);
      await req.response.flush();
      cursor = windowEnd + 1;
    }
    await req.response.close();
  }
}
