// Ported from MrTangLuyao/Bilibili-thread-ripper (MIT), src/idm-downloader.js.
// Hedged concurrent HTTP Range fetching with per-host health feedback.
library;

import 'dart:async'
    show
        Completer,
        Future,
        StreamSubscription,
        TimeoutException,
        Timer,
        unawaited;
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

const Duration _firstByteTimeout = Duration(milliseconds: 5500);
const Duration _stallTimeout = Duration(milliseconds: 4000);
const Duration _attemptTimeout = Duration(milliseconds: 15000);
const Duration _hedgeDelay = Duration(milliseconds: 900);
const Duration _startupHedgeDelay = Duration(milliseconds: 250);

class RipperHttpException implements Exception {
  RipperHttpException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'RipperHttpException($statusCode): $message';
}

class RipperPieceResult {
  RipperPieceResult({
    required this.bytes,
    required this.total,
    required this.url,
  });

  final Uint8List bytes;
  final int? total;
  final String url;
}

/// Caps concurrent upstream connections so a burst of pieces cannot exceed
/// the configured thread budget.
class _Semaphore {
  _Semaphore(this.limit);

  int limit;
  int _active = 0;
  final List<Completer<void>> _queue = [];

  void setLimit(int value) {
    limit = value.clamp(1, 512).toInt();
    _drain();
  }

  Future<void> acquire() {
    if (_active < limit) {
      _active++;
      return Future.value();
    }
    final completer = Completer<void>();
    _queue.add(completer);
    return completer.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else if (_active > 0) {
      _active--;
    }
  }

  void _drain() {
    while (_active < limit && _queue.isNotEmpty) {
      _queue.removeAt(0).complete();
      _active++;
    }
  }
}

/// IDM-style concurrent Range downloader. Each byte range is split into
/// pieces fetched in parallel across CDN candidates; slow pieces are hedged
/// on a second host instead of stalling the whole range.
class RipperDownloader {
  RipperDownloader({Dio? dio, int concurrency = 8})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: _firstByteTimeout,
              receiveTimeout: _attemptTimeout,
              headers: {
                'user-agent': BrowserUa.pc,
                'referer': HttpString.baseUrl,
              },
            ),
          ),
      _semaphore = _Semaphore(concurrency.clamp(1, 128).toInt());

  final Dio _dio;
  final _Semaphore _semaphore;

  void setConcurrency(int value) => _semaphore.setLimit(value);

  Map<String, String> _rangeHeaders(ByteRange piece) => {
    'Range': 'bytes=${piece.start}-${piece.end}',
    'user-agent': BrowserUa.pc,
    'referer': HttpString.baseUrl,
  };

  Future<RipperPieceResult> _attempt(
    ByteRange piece,
    String url,
    CdnResolver resolver,
    CancelToken outer,
  ) async {
    await _semaphore.acquire();
    final token = CancelToken();
    void cancelLinked() {
      if (!token.isCancelled) token.cancel('outer cancelled');
    }

    Timer? firstByteTimer;
    Timer? totalTimer;
    Timer? stallTimer;
    String? timeoutReason;
    var received = 0;
    final stopwatch = Stopwatch()..start();
    try {
      if (outer.isCancelled) throw TimeoutException('cancelled');
      unawaited(outer.whenCancel.then((_) => cancelLinked()));
      firstByteTimer = Timer(_firstByteTimeout, () {
        timeoutReason ??= 'first byte timeout';
        if (!token.isCancelled) token.cancel(timeoutReason);
      });
      totalTimer = Timer(_attemptTimeout, () {
        timeoutReason ??= 'attempt timeout';
        if (!token.isCancelled) token.cancel(timeoutReason);
      });

      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: _rangeHeaders(piece),
        ),
        cancelToken: token,
      );
      final status = response.statusCode ?? 0;
      final contentRange = parseContentRange(
        response.headers.value('content-range'),
      );
      if (status != 206 ||
          contentRange == null ||
          contentRange.start != piece.start ||
          contentRange.end != piece.end) {
        throw RipperHttpException(
          'range check failed: HTTP $status',
          statusCode: status,
        );
      }

      final builder = BytesBuilder(copy: false);
      final stream = response.data!.stream;
      final done = Completer<void>();
      void armStall() {
        stallTimer?.cancel();
        stallTimer = Timer(_stallTimeout, () {
          timeoutReason ??= 'stall timeout';
          if (!token.isCancelled) token.cancel(timeoutReason);
        });
      }

      armStall();
      late final StreamSubscription<Uint8List> sub;
      sub = stream.listen(
        (Uint8List chunk) {
          firstByteTimer?.cancel();
          armStall();
          builder.add(chunk);
          received += chunk.length;
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
        cancelOnError: true,
      );
      try {
        await done.future;
      } finally {
        await sub.cancel();
      }
      final bytes = builder.takeBytes();
      if (bytes.length != piece.length) {
        throw RipperHttpException(
          'sub-range length mismatch: ${bytes.length}/${piece.length}',
          statusCode: status,
        );
      }
      final seconds = stopwatch.elapsedMilliseconds / 1000.0;
      resolver.success(url, bytes.length / (seconds <= 0 ? 0.001 : seconds));
      return RipperPieceResult(
        bytes: bytes,
        total: contentRange.total,
        url: url,
      );
    } catch (e) {
      final reason = timeoutReason;
      final userCancelled = outer.isCancelled && reason == null;
      final dioCancelled =
          e is DioException &&
          e.type == DioExceptionType.cancel &&
          reason == null;
      if (userCancelled || dioCancelled) rethrow;
      if (reason != null) {
        resolver.failure(url, TimeoutException(reason), received);
        if (kDebugMode) debugPrint('[ripper] piece timeout $url: $reason');
        throw TimeoutException(reason);
      }
      resolver.failure(url, e, received);
      if (kDebugMode) debugPrint('[ripper] piece failed $url: $e');
      rethrow;
    } finally {
      firstByteTimer?.cancel();
      totalTimer?.cancel();
      stallTimer?.cancel();
      stopwatch.stop();
      _semaphore.release();
    }
  }

  /// Fetches one piece, racing a hedged copy on a second host when the
  /// primary is slow. The loser is cancelled.
  Future<RipperPieceResult> downloadPiece(
    ByteRange piece,
    CdnResolver resolver,
    CancelToken outer, {
    List<String>? preferredUrls,
    bool startup = false,
    required int pieceIndex,
  }) async {
    final preferred = preferredUrls ?? const <String>[];
    final rotatedPreferred = preferred.isEmpty
        ? const <String>[]
        : [
            ...preferred.skip(pieceIndex % preferred.length),
            ...preferred.take(pieceIndex % preferred.length),
          ];
    final rescue = resolver
        .rescueCandidates()
        .where((u) => !rotatedPreferred.contains(u))
        .toList();
    final candidates = <String>[];
    final width = rotatedPreferred.length > rescue.length
        ? rotatedPreferred.length
        : rescue.length;
    for (var i = 0; i < width; i++) {
      if (i < rotatedPreferred.length) candidates.add(rotatedPreferred[i]);
      if (i < rescue.length) candidates.add(rescue[i]);
    }
    for (final url in resolver.ordered(pieceIndex)) {
      if (!candidates.contains(url)) candidates.add(url);
    }

    final limit = candidates.length < 8 ? candidates.length : 8;
    final tried = <String>{};
    Object? lastError;
    final hedgeDelay = startup ? _startupHedgeDelay : _hedgeDelay;

    while (tried.length < limit) {
      if (outer.isCancelled) throw TimeoutException('cancelled');
      final untried = candidates.where((u) => !tried.contains(u)).toList();
      final open = untried.where(resolver.urls().contains).toList();
      final pair = (open.isNotEmpty ? open : untried).take(2).toList();
      if (pair.isEmpty) break;
      tried.addAll(pair);
      final tokens = List.generate(pair.length, (_) => CancelToken());
      void cancelOuter() {
        for (final t in tokens) {
          if (!t.isCancelled) t.cancel('outer cancelled');
        }
      }

      if (outer.isCancelled) cancelOuter();
      final outerSub = outer.whenCancel.then((_) => cancelOuter());
      try {
        final attempts = pair.indexed.map((entry) async {
          final i = entry.$1;
          final url = entry.$2;
          if (i > 0) {
            await Future.delayed(hedgeDelay);
            if (tokens[i].isCancelled || outer.isCancelled) {
              throw TimeoutException('hedge cancelled');
            }
          }
          final linked = CancelToken();
          void forward() {
            if (!linked.isCancelled) linked.cancel('loser cancelled');
          }

          unawaited(tokens[i].whenCancel.then((_) => forward()));
          try {
            return await _attempt(
              ByteRange(piece.start, piece.end),
              url,
              resolver,
              linked,
            );
          } finally {
            if (!linked.isCancelled) linked.cancel('attempt settled');
          }
        }).toList();
        final winner = await Future.any(attempts);
        for (final t in tokens) {
          if (!t.isCancelled) t.cancel('hedge loser');
        }
        return winner;
      } catch (e) {
        lastError = e;
        if (outer.isCancelled) throw TimeoutException('cancelled');
      } finally {
        outerSub.ignore();
      }
    }
    throw lastError ?? RipperHttpException('no available CDN');
  }

  /// Fetches [start, end] concurrently and returns the ordered bytes.
  Future<RipperPieceResult> downloadRange(
    int start,
    int end,
    CdnResolver resolver,
    CancelToken outer, {
    List<String>? preferredUrls,
    bool startup = false,
    int concurrency = 8,
    int minChunkBytes = 128 * 1024,
  }) async {
    _semaphore.setLimit(concurrency);
    final pieces = splitRange(
      start,
      end,
      concurrency,
      minChunkBytes: minChunkBytes,
    );
    final results = await Future.wait(
      pieces.indexed.map((entry) {
        return downloadPiece(
          entry.$2,
          resolver,
          outer,
          preferredUrls: preferredUrls,
          startup: startup,
          pieceIndex: entry.$1,
        );
      }),
    );
    final totals = results
        .map((r) => r.total)
        .whereType<int>()
        .toSet()
        .toList();
    if (totals.length > 1) {
      throw RipperHttpException('CDN returned inconsistent file lengths');
    }
    return RipperPieceResult(
      bytes: concatChunks(
        results.map((r) => r.bytes).toList(),
        end - start + 1,
      ),
      total: totals.isEmpty ? null : totals.first,
      url: results.first.url,
    );
  }

  /// Races a 1-byte probe across startup candidates to learn the total file
  /// length without committing to a host.
  Future<int?> probeTotalLength(CdnResolver resolver, CancelToken outer) async {
    final candidates = resolver.startupCandidates().take(3).toList();
    if (candidates.isEmpty) return null;
    final attempts = candidates.indexed.map((entry) async {
      final i = entry.$1;
      final url = entry.$2;
      if (i > 0) await Future.delayed(Duration(milliseconds: 120 * i));
      if (outer.isCancelled) throw TimeoutException('cancelled');
      final token = CancelToken();
      unawaited(
        outer.whenCancel.then((_) {
          if (!token.isCancelled) token.cancel('outer cancelled');
        }),
      );
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Range': 'bytes=0-0',
            'user-agent': BrowserUa.pc,
            'referer': HttpString.baseUrl,
          },
        ),
        cancelToken: token,
      );
      final contentRange = parseContentRange(
        response.headers.value('content-range'),
      );
      await response.data?.stream.drain<int>(0);
      if (!token.isCancelled) token.cancel('probe done');
      if ((response.statusCode ?? 0) == 206) return contentRange?.total;
      return null;
    }).toList();
    // Never let one failing probe discard the others' results.
    final results = await Future.wait(
      attempts.map((f) => f.then<int?>((v) => v, onError: (_) => null)),
    );
    for (final total in results) {
      if (total != null) return total;
    }
    return null;
  }
}
