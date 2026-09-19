// Native download-layer adaptation of Bilibili-thread-ripper (MIT).
// The existing media_kit player continues to demux, decode, seek and render.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';

class RipperRangeProxy {
  RipperRangeProxy({
    this.concurrency = 8,
    this.overseas = true,
    required this.userAgent,
    this.referer = 'https://www.bilibili.com/',
  }) : assert(concurrency > 0 && concurrency <= 128);

  final int concurrency;
  final bool overseas;
  final String userAgent;
  final String referer;
  final _tracks = <String, _Track>{};
  final _bans = RipperBanList();
  final _jobs = <_Job>{};
  final _client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(milliseconds: 5500);
  final _waiters = <Completer<void>>[];
  int _active = 0;
  bool _closed = false;
  HttpServer? _server;
  final String _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('Download session closed');
    }
    _server = server;
    // Transport disconnects can also fail response.close(); each request owns
    // its cleanup in finally, so never leak those errors to the app's zone.
    server.listen((request) => _serve(request).ignore());
  }

  String register(Iterable<String> urls) => registerCandidates(
    RipperCdnResolver.candidates(urls, overseas: overseas),
  );

  // Also permits loopback fixtures for deterministic transport tests. Production
  // callers use register(), which only accepts Bilibili media addresses.
  String registerCandidates(List<Uri> urls) {
    if (_closed || _server == null || urls.isEmpty) {
      throw StateError('No download session or media candidates');
    }
    final id = '/$_token/${_tracks.length}';
    _tracks[id] = _Track(RipperCdnResolver(urls, bans: _bans));
    return 'http://127.0.0.1:${_server!.port}$id';
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final job in _jobs.toList()) {
      job.cancel();
    }
    _client.close(force: true);
    unawaited(_server?.close(force: true));
    for (final waiter in _waiters) {
      waiter.complete();
    }
    _waiters.clear();
    _tracks.clear();
  }

  Future<void> _slot(_Job job) async {
    while (_active >= concurrency) {
      job.check();
      final waiter = Completer<void>();
      _waiters.add(waiter);
      try {
        await job.race(waiter.future);
      } finally {
        _waiters.remove(waiter);
      }
    }
    job.check();
    if (_closed) throw const HttpException('Download session closed');
    _active++;
  }

  void _release() {
    _active--;
    if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
  }

  Future<_Piece> _attempt(
    _Track track,
    Uri url,
    int start,
    int end,
    _Job job,
  ) async {
    await _slot(job);
    HttpClientRequest? request;
    final clock = Stopwatch()..start();
    Timer? deadline;
    int status = 0;
    int received = 0;
    try {
      request = await _client
          .getUrl(url)
          .timeout(const Duration(milliseconds: 5500));
      job.check();
      job.requests.add(request);
      deadline = Timer(const Duration(seconds: 15), () {
        request?.abort(const HttpException('Range attempt timed out'));
      });
      request.headers
        ..set(HttpHeaders.rangeHeader, 'bytes=$start-$end')
        ..set(HttpHeaders.acceptEncodingHeader, 'identity')
        ..set(HttpHeaders.userAgentHeader, userAgent)
        ..set(HttpHeaders.refererHeader, referer);
      final response = await request.close().timeout(
        const Duration(milliseconds: 5500),
      );
      status = response.statusCode;
      final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      if (response.statusCode != 206 ||
          match == null ||
          int.parse(match[1]!) != start ||
          int.parse(match[2]!) != end) {
        throw const HttpException('Invalid CDN Range response');
      }
      final total = int.parse(match[3]!);
      if (total <= end || (track.total != null && total != track.total)) {
        throw const HttpException('Inconsistent CDN resource length');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 4))) {
        job.check();
        received += chunk.length;
        bytes.add(chunk);
        if (bytes.length > end - start + 1) {
          throw const HttpException('Oversized CDN Range body');
        }
      }
      if (bytes.length != end - start + 1) {
        throw const HttpException('Truncated CDN Range body');
      }
      track.resolver.success(url, bytes.length, clock.elapsed);
      return _Piece(bytes.takeBytes(), total);
    } catch (_) {
      if (!job.cancelled) {
        track.resolver.failure(url, status: status, received: received);
      }
      rethrow;
    } finally {
      deadline?.cancel();
      request?.abort();
      job.requests.remove(request);
      _release();
    }
  }

  // Start a second copy after 900 ms, or immediately if the first fails.
  // First validated response wins; the losing connection is aborted.
  Future<_Piece> _race(
    _Track track,
    List<Uri> urls,
    int start,
    int end,
    _Job parent,
  ) async {
    final result = Completer<_Piece>();
    final jobs = <_Job>[];
    int failures = 0;
    Timer? hedge;
    bool secondStarted = false;
    void launch(int index) {
      if (result.isCompleted || parent.cancelled) return;
      final job = _Job();
      jobs.add(job);
      parent.children.add(job);
      _attempt(track, urls[index], start, end, job).then(
        (piece) {
          if (!result.isCompleted) result.complete(piece);
        },
        onError: (Object error, StackTrace stack) {
          failures++;
          if (index == 0 && urls.length > 1 && !secondStarted) {
            secondStarted = true;
            hedge?.cancel();
            launch(1);
          }
          if (failures == urls.length && !result.isCompleted) {
            result.completeError(error, stack);
          }
        },
      );
    }

    launch(0);
    if (urls.length > 1) {
      hedge = Timer(const Duration(milliseconds: 900), () {
        if (!secondStarted) {
          secondStarted = true;
          launch(1);
        }
      });
    }
    try {
      return await parent.race(result.future);
    } finally {
      hedge?.cancel();
      for (final job in jobs) {
        job.cancel();
        parent.children.remove(job);
      }
    }
  }

  Future<_Piece> _download(_Track track, int start, int end, _Job job) async {
    final clock = Stopwatch()..start();
    Object error = const HttpException('No available CDN');
    for (var round = 0; round < 3; round++) {
      job.check();
      final urls = track.resolver.ordered().take(8).toList();
      for (var i = 0; i < urls.length; i += 2) {
        job.check();
        if (clock.elapsed > const Duration(seconds: 25)) throw error;
        try {
          return await _race(
            track,
            urls.sublist(i, min(i + 2, urls.length)),
            start,
            end,
            job,
          );
        } catch (e) {
          error = e;
        }
      }
    }
    throw error;
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final track = _tracks[request.uri.path];
    if (track == null || _closed) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final job = _Job();
    _jobs.add(job);
    // A seek closes the old HTTP response and cancels all queued/in-flight work.
    unawaited(
      response.done.then(
        (_) => job.cancel(),
        onError: (Object _) => job.cancel(),
      ),
    );
    bool sentHeaders = false;
    try {
      if (track.total == null) {
        final probe = await _download(track, 0, 0, job);
        track.total = probe.total;
      }
      final total = track.total!;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final (start, end) = parseRange(range, total);
      response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      response.contentLength = end - start + 1;
      if (range != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
      }
      if (request.method != 'HEAD') {
        // A bounded window prevents mpv's open-ended ranges from buffering an
        // entire movie in memory. Flush in file order with socket backpressure.
        const chunkSize = 64 * 1024;
        for (var cursor = start; cursor <= end;) {
          job.check();
          final pieces = <Future<(_Piece?, Object?, StackTrace?)>>[];
          for (var i = 0; i < concurrency && cursor <= end; i++) {
            final last = min(end, cursor + chunkSize - 1);
            pieces.add(
              _download(track, cursor, last, job).then(
                (piece) => (piece, null, null),
                onError: (Object error, StackTrace stack) =>
                    (null, error, stack),
              ),
            );
            cursor = last + 1;
          }
          for (final pending in pieces) {
            final (piece, error, stack) = await pending;
            if (error != null) Error.throwWithStackTrace(error, stack!);
            job.check();
            if (piece!.total != total) {
              throw const HttpException('Resource changed');
            }
            response.add(piece.bytes);
            sentHeaders = true;
            await response.flush();
          }
        }
      }
      await response.close();
    } on FormatException {
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..contentLength = 0;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${track.total}',
      );
      await response.close();
    } catch (_) {
      if (!sentHeaders) {
        try {
          response
            ..statusCode = HttpStatus.badGateway
            ..contentLength = 0;
          await response.close();
        } catch (_) {}
      } else {
        // Never pretend a truncated byte stream completed successfully.
        try {
          final socket = await response.detachSocket(writeHeaders: false);
          socket.destroy();
        } catch (_) {}
      }
    } finally {
      job.cancel();
      _jobs.remove(job);
    }
  }

  static (int, int) parseRange(String? value, int total) {
    if (value == null) return (0, total - 1);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
      throw const FormatException('Invalid Range');
    }
    final int start;
    final int end;
    if (match[1]!.isEmpty) {
      final suffix = int.parse(match[2]!);
      if (suffix <= 0) throw const FormatException('Invalid suffix');
      start = max(0, total - suffix);
      end = total - 1;
    } else {
      start = int.parse(match[1]!);
      end = match[2]!.isEmpty
          ? total - 1
          : min(int.parse(match[2]!), total - 1);
    }
    if (start >= total || end < start) {
      throw const FormatException('Unsatisfiable Range');
    }
    return (start, end);
  }
}

class _Track {
  _Track(this.resolver);
  final RipperCdnResolver resolver;
  int? total;
}

class _Piece {
  _Piece(this.bytes, this.total);
  final Uint8List bytes;
  final int total;
}

class _Job {
  final requests = <HttpClientRequest>{};
  final children = <_Job>{};
  final _listeners = <void Function()>{};
  bool cancelled = false;

  Future<T> race<T>(Future<T> operation) async {
    final result = Completer<T>();
    void cancelWait() {
      if (!result.isCompleted) {
        result.completeError(const HttpException('Cancelled'));
      }
    }

    _listeners.add(cancelWait);
    operation.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    if (cancelled) cancelWait();
    try {
      return await result.future;
    } finally {
      _listeners.remove(cancelWait);
    }
  }

  void check() {
    if (cancelled) throw const HttpException('Download cancelled');
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    for (final request in requests) {
      request.abort();
    }
    for (final child in children) {
      child.cancel();
    }
  }
}
