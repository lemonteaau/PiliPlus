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
    this.onActiveRequestsChanged,
  }) : assert(concurrency > 0 && concurrency <= 128);

  final void Function(int active)? onActiveRequestsChanged;
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
  final _waiters = <_Waiter>[];
  int _sequence = 0;
  int _active = 0;
  int _normalActive = 0;
  int get _normalLimit => concurrency == 1
      ? 1
      : concurrency -
            max(1, (concurrency / 8).ceil()).clamp(1, concurrency - 1);
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

  String register(Iterable<String> urls, {bool isAudio = false}) {
    final originals = urls
        .map(Uri.parse)
        .where(RipperCdnResolver.supports)
        .toList();
    return registerCandidates(
      RipperCdnResolver.candidates(urls, overseas: overseas),
      originals: originals,
      isAudio: isAudio,
    );
  }

  // Explicit candidates are used by the loopback regression fixtures.
  String registerCandidates(
    List<Uri> urls, {
    List<Uri>? originals,
    bool isAudio = false,
  }) {
    if (_closed || _server == null || urls.isEmpty) {
      throw StateError('No download session or media candidates');
    }
    final id = '/$_token/${_tracks.length}';
    _tracks[id] = _Track(
      RipperCdnResolver(
        urls,
        bans: _bans,
        overseas: overseas,
        originals: originals,
      ),
      isAudio,
    );
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
      if (!waiter.ready.isCompleted) {
        waiter.ready.completeError(const HttpException('Session closed'));
      }
    }
    _waiters.clear();
    _tracks.clear();
  }

  Future<void> _slot(
    _Job job, {
    required bool rescue,
    required int priority,
  }) async {
    job.check();
    if (_closed) throw const HttpException('Download session closed');
    final waiter = _Waiter(rescue, priority, _sequence++);
    void cancel() {
      if (_waiters.remove(waiter)) {
        waiter.ready.completeError(const HttpException('Download cancelled'));
      }
    }

    job._listeners.add(cancel);
    _waiters.add(waiter);
    _drain();
    try {
      await waiter.ready.future;
    } finally {
      job._listeners.remove(cancel);
    }
  }

  void _drain() {
    _waiters.sort((a, b) {
      final priority = b.priority.compareTo(a.priority);
      return priority != 0 ? priority : a.sequence.compareTo(b.sequence);
    });
    while (_active < concurrency) {
      final index = _waiters.indexWhere(
        (w) => w.rescue || _normalActive < _normalLimit,
      );
      if (index < 0) return;
      final waiter = _waiters.removeAt(index);
      _active++;
      onActiveRequestsChanged?.call(_active);
      if (!waiter.rescue) _normalActive++;
      waiter.ready.complete();
    }
  }

  void _release({required bool rescue}) {
    _active--;
    onActiveRequestsChanged?.call(_active);
    if (!rescue) _normalActive--;
    _drain();
  }

  Future<_Piece> _attempt(
    _Track track,
    Uri url,
    int start,
    int end,
    _Job job, {
    required bool rescue,
    required int priority,
  }) async {
    await _slot(job, rescue: rescue, priority: priority);
    HttpClientRequest? request;
    final clock = Stopwatch()..start();
    Timer? deadline;
    int status = 0;
    int received = 0;
    bool completed = false;
    try {
      job.check();
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
      completed = true;
      track.resolver.success(url, bytes.length, clock.elapsed);
      return _Piece(bytes.takeBytes(), total, url);
    } catch (_) {
      if (!job.cancelled) {
        track.resolver.failure(url, status: status, received: received);
      }
      rethrow;
    } finally {
      deadline?.cancel();
      if (!completed) request?.abort();
      job.requests.remove(request);
      _release(rescue: rescue);
    }
  }

  // Equivalent to startupAttempt / downloadPiece's Promise.any: stagger
  // metadata at 0/120/300 ms, race startup heads immediately, and hedge media.
  Future<_Piece> _race(
    _Track track,
    List<Uri> urls,
    int start,
    int end,
    _Job parent, {
    required int priority,
    bool metadata = false,
    bool startup = false,
    bool hurry = false,
  }) async {
    final result = Completer<_Piece>();
    final jobs = <_Job>[];
    final timers = <Timer>[];
    final launched = <int>{};
    int failures = 0;
    void launch(int index) {
      if (result.isCompleted || parent.cancelled || !launched.add(index)) {
        return;
      }
      final job = _Job();
      jobs.add(job);
      parent.children.add(job);
      _attempt(
        track,
        urls[index],
        start,
        end,
        job,
        rescue: index > 0,
        priority: priority + (index > 0 && !metadata ? 20 : 0),
      ).then(
        (piece) {
          if (!result.isCompleted) result.complete(piece);
        },
        onError: (Object error, StackTrace stack) {
          failures++;
          if (index == 0 && urls.length > 1 && !metadata) launch(1);
          if (failures == urls.length && !result.isCompleted) {
            result.completeError(error, stack);
          }
        },
      );
    }

    launch(0);
    for (var i = 1; i < urls.length; i++) {
      final delay = metadata
          ? (i == 1 ? 120 : 300)
          : startup
          ? 0
          : hurry
          ? 250
          : 900;
      if (delay == 0) {
        launch(i);
      } else {
        timers.add(Timer(Duration(milliseconds: delay), () => launch(i)));
      }
    }
    try {
      return await parent.race(result.future);
    } finally {
      for (final timer in timers) {
        timer.cancel();
      }
      for (final job in jobs) {
        job.cancel();
        parent.children.remove(job);
      }
    }
  }

  Future<_Piece> _download(
    _Track track,
    int start,
    int end,
    _Job job, {
    List<Uri> preferred = const [],
    int pieceIndex = 0,
    int priority = 50,
    bool metadata = false,
    bool startup = false,
    bool hurry = false,
  }) async {
    final clock = Stopwatch()..start();
    Object error = const HttpException('No available CDN');
    for (var round = 0; round < 3; round++) {
      job.check();
      if (round > 0) {
        if (clock.elapsed > const Duration(seconds: 25)) break;
        await job.race(
          Future<void>.delayed(
            Duration(milliseconds: 500 * (1 << (round - 1))),
          ),
        );
      }
      if (metadata) {
        var urls = track.resolver.startupCandidates().take(3).toList();
        if (urls.isEmpty && round > 0) {
          urls = track.resolver.ordered(round).take(3).toList();
        }
        if (urls.isEmpty) break;
        try {
          return await _race(
            track,
            urls,
            start,
            end,
            job,
            priority: 220,
            metadata: true,
          );
        } catch (e) {
          error = e;
        }
        continue;
      }
      final candidates = track.resolver.pieceCandidates(
        preferred,
        pieceIndex,
        round,
      );
      final limit = min(8, candidates.length);
      final tried = <Uri>{};
      while (tried.length < limit) {
        job.check();
        final untried = candidates.where((u) => !tried.contains(u)).toList();
        final allowed = untried.where(track.resolver.bans.allows).toList();
        final pair = (allowed.isEmpty ? untried : allowed)
            .take(min(startup ? limit : 2, limit - tried.length))
            .toList();
        if (pair.isEmpty) break;
        tried.addAll(pair);
        try {
          return await _race(
            track,
            pair,
            start,
            end,
            job,
            priority: priority,
            startup: startup,
            hurry: hurry,
          );
        } catch (e) {
          error = e;
        }
      }
    }
    job.check();
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
        final probe = await _download(track, 0, 0, job, metadata: true);
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
        // Sliding bounded window: refill after each emitted piece, without
        // waiting for the slowest member of a batch. Larger steady-state
        // pieces amortize overseas request latency; keep the first one small.
        final headEnd = min(end, start + 64 * 1024 - 1);
        final head = await _download(
          track,
          start,
          headEnd,
          job,
          preferred: track.resolver.rangeCandidates(),
          startup: true,
          priority: 220,
        );
        job.check();
        response.add(head.bytes);
        sentHeaders = true;
        await response.flush();
        var cursor = headEnd + 1;
        var index = 1;
        final audioBudget = max(1, min(_normalLimit, (concurrency / 8).ceil()));
        final budget = track.isAudio
            ? audioBudget
            : max(1, _normalLimit - audioBudget);
        var preferred = <Uri>[head.url];
        final pieces = <Future<(_Piece?, Object?, StackTrace?)>>[];
        void enqueue() {
          if (cursor > end) return;
          if (index > budget && (index - 1) % budget == 0) {
            preferred = track.resolver.rangeCandidates();
          }
          // Native mpv requests are open-ended rather than SIDX segments.
          // Partition a bounded 2 MiB video window over the same piece budget
          // instead of turning the upstream 64 KiB minimum into a fixed size.
          final size = track.isAudio
              ? 64 * 1024
              : max(
                  64 * 1024,
                  (2 * 1024 * 1024 - 64 * 1024 + budget - 1) ~/ budget,
                );
          final last = min(end, cursor + size - 1);
          pieces.add(
            _download(
              track,
              cursor,
              last,
              job,
              preferred: preferred,
              pieceIndex: index,
              hurry: index <= budget,
              priority: index <= budget
                  ? 120 - min(30, index++)
                  : 55 - min(20, index++ % budget),
            ).then(
              (piece) => (piece, null, null),
              onError: (Object error, StackTrace stack) => (null, error, stack),
            ),
          );
          cursor = last + 1;
        }

        for (var i = 0; i < budget; i++) {
          enqueue();
        }
        while (pieces.isNotEmpty) {
          final (piece, error, stack) = await pieces.removeAt(0);
          if (error != null) Error.throwWithStackTrace(error, stack!);
          job.check();
          if (piece!.total != total) {
            throw const HttpException('Resource changed');
          }
          response.add(piece.bytes);
          sentHeaders = true;
          await response.flush();
          job.check();
          enqueue();
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
  _Track(this.resolver, this.isAudio);
  final bool isAudio;
  final RipperCdnResolver resolver;
  int? total;
}

class _Piece {
  _Piece(this.bytes, this.total, this.url);
  final Uri url;
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

class _Waiter {
  _Waiter(this.rescue, this.priority, this.sequence);
  final bool rescue;
  final int priority;
  final int sequence;
  final ready = Completer<void>();
}
