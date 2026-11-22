import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer cdn;
  late HttpClient client;
  late Uint8List source;
  late List<String> paths;
  late List<Timer> timers;
  late DateTime clockNow;
  late bool failTransientOnce;

  setUp(() async {
    source = Uint8List.fromList(List.generate(512 * 1024, (i) => (i * 31) % 251));
    paths = [];
    timers = [];
    clockNow = DateTime.utc(2026, 11, 22, 8, 48, 0);
    failTransientOnce = true;

    cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((request) async {
        paths.add(request.uri.path);
        final response = request.response;
        try {
          if (request.uri.path.startsWith('/403')) {
            response.statusCode = HttpStatus.forbidden;
            await response.close();
            return;
          }
          if (request.uri.path.startsWith('/410')) {
            response.statusCode = HttpStatus.gone;
            await response.close();
            return;
          }
          if (request.uri.path == '/hang') {
            timers.add(
              Timer(const Duration(seconds: 10), () {
                unawaited(response.close().catchError((Object _) {}));
              }),
            );
            return;
          }
          if (request.uri.path == '/transient-once' && failTransientOnce) {
            failTransientOnce = false;
            response.statusCode = HttpStatus.internalServerError;
            await response.close();
            return;
          }

          final (start, end) = RipperRangeProxy.parseRange(
            request.headers.value('range'),
            source.length,
          );
          if (request.uri.path == '/mirror-403-after-head' && start >= 65536) {
            response.statusCode = HttpStatus.forbidden;
            await response.close();
            return;
          }

          response
            ..statusCode = HttpStatus.partialContent
            ..headers.set(
              'Content-Range',
              'bytes $start-$end/${source.length}',
            );
          final body = source.sublist(start, end + 1);
          if (request.uri.path == '/good-slow-head' && start == 0) {
            timers.add(
              Timer(const Duration(milliseconds: 250), () {
                try {
                  response.add(body);
                  unawaited(response.close().catchError((Object _) {}));
                } catch (_) {}
              }),
            );
            return;
          }
          if (request.uri.path == '/expire-after-head' && start == 0) {
            // Advance clock past the embedded deadline before flushing/closing
            // so the loopback client cannot start piece 1 before the clock moves.
            clockNow = clockNow.add(const Duration(minutes: 15));
            response.add(body);
            await response.close();
            return;
          }
          response.add(body);
          await response.close();
        } catch (_) {
          try {
            await response.close();
          } catch (_) {}
        }
      });
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    for (final timer in timers) {
      timer.cancel();
    }
    await cdn.close(force: true);
  });

  Uri endpoint(String path, {int? deadlineSec}) => Uri.parse(
    'http://127.0.0.1:${cdn.port}$path'
    '${deadlineSec == null ? '' : '?deadline=$deadlineSec'}',
  );

  Future<(HttpClientResponse, List<int>)> fetch(
    String url, {
    String? range,
  }) async {
    final req = await client.getUrl(Uri.parse(url));
    if (range != null) req.headers.set('range', range);
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (res, bytes);
  }

  test(
    'registered valid deadline that later expires fails fast with HTTP 403 and zero upstream requests',
    () async {
      final proxy = RipperRangeProxy(
        concurrency: 4,
        userAgent: 'test',
        now: () => clockNow,
      );
      addTearDown(proxy.close);
      await proxy.start();

      final validDeadlineSec =
          clockNow.add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
          1000;
      final url = proxy.registerCandidates([
        endpoint('/good', deadlineSec: validDeadlineSec),
      ]);

      // Simulate long pause pushing clock past the registered deadline.
      clockNow = clockNow.add(const Duration(minutes: 11));

      final watch = Stopwatch()..start();
      final (res, bytes) = await fetch(url);
      expect(res.statusCode, HttpStatus.forbidden);
      expect(bytes, isEmpty);
      expect(paths, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    },
  );

  test(
    'deadline expiring mid-stream truncates stream and fast-fails reconnect with 403',
    () async {
      final proxy = RipperRangeProxy(
        concurrency: 4,
        userAgent: 'test',
        now: () => clockNow,
      );
      addTearDown(proxy.close);
      await proxy.start();

      final validDeadlineSec =
          clockNow.add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
          1000;
      final url = proxy.registerCandidates([
        endpoint('/expire-after-head', deadlineSec: validDeadlineSec),
      ]);

      // First request streams the 64 KiB head, then clock advances past deadline
      // before piece 1 starts -> truncated body after headers.
      try {
        final (_, bytes) = await fetch(url);
        expect(bytes.length, lessThan(source.length));
      } on HttpException {
        // Truncated stream after headers is expected when socket is destroyed.
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Reconnect attempt (simulating mpv FFmpeg HTTP reconnect) fails fast
      // with 403 and zero additional upstream hits.
      final upstreamCountBefore = paths.length;
      final watch = Stopwatch()..start();
      final (reconnectRes, reconnectBytes) = await fetch(
        url,
        range: 'bytes=65536-',
      );
      expect(reconnectRes.statusCode, HttpStatus.forbidden);
      expect(reconnectBytes, isEmpty);
      expect(paths.length, upstreamCountBefore);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    },
  );

  test(
    'clock-skew guard ignores <5m TTL deadline at registration and falls back to upstream',
    () async {
      final proxy = RipperRangeProxy(
        concurrency: 4,
        userAgent: 'test',
        now: () => clockNow,
      );
      addTearDown(proxy.close);
      await proxy.start();

      // Case 1: device clock skewed hours ahead -> deadline already in the past.
      final pastDeadlineSec =
          clockNow.subtract(const Duration(hours: 3)).millisecondsSinceEpoch ~/
          1000;
      final pastUrl = proxy.registerCandidates([
        endpoint('/good', deadlineSec: pastDeadlineSec),
      ]);
      final (pastRes, pastBytes) = await fetch(pastUrl);
      expect(pastRes.statusCode, HttpStatus.ok);
      expect(pastBytes, source);
      expect(paths, contains('/good'));

      // Case 2: fresh URL with <5m remaining TTL at registration -> not armed.
      final shortTtlSec =
          clockNow.add(const Duration(minutes: 4)).millisecondsSinceEpoch ~/
          1000;
      final shortUrl = proxy.registerCandidates([
        endpoint('/good', deadlineSec: shortTtlSec),
      ]);
      clockNow = clockNow.add(const Duration(minutes: 10));
      final (shortRes, shortBytes) = await fetch(shortUrl);
      expect(shortRes.statusCode, HttpStatus.ok);
      expect(shortBytes, source);

      // Case 3: skewed track that upstream actually rejects with 403 still
      // fast-fails via universal 403 detection without retry storms.
      final rejectedUrl = proxy.registerCandidates([
        endpoint('/403-skewed', deadlineSec: pastDeadlineSec),
      ]);
      final watch = Stopwatch()..start();
      final (rejectedRes, rejectedBytes) = await fetch(rejectedUrl);
      expect(rejectedRes.statusCode, HttpStatus.forbidden);
      expect(rejectedBytes, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(paths.where((p) => p == '/403-skewed').length, 1);
    },
  );

  test(
    'universal 403 across candidates fast-fails without multi-round retry sleeps',
    () async {
      final proxy = RipperRangeProxy(
        concurrency: 4,
        userAgent: 'test',
        now: () => clockNow,
      );
      addTearDown(proxy.close);
      await proxy.start();

      final orig = endpoint('/403-orig');
      final mirror = endpoint('/403-mirror');
      final url = proxy.registerCandidates([orig, mirror], originals: [orig]);

      final watch = Stopwatch()..start();
      final (res, bytes) = await fetch(url);
      expect(res.statusCode, HttpStatus.forbidden);
      expect(bytes, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(paths.length, lessThanOrEqualTo(2));
    },
  );

  test('universal 410 Gone also fast-fails with HTTP 403', () async {
    final proxy = RipperRangeProxy(
      concurrency: 4,
      userAgent: 'test',
      now: () => clockNow,
    );
    addTearDown(proxy.close);
    await proxy.start();

    final url = proxy.registerCandidates([
      endpoint('/410-a'),
      endpoint('/410-b'),
    ]);

    final watch = Stopwatch()..start();
    final (res, bytes) = await fetch(url);
    expect(res.statusCode, HttpStatus.forbidden);
    expect(bytes, isEmpty);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(paths.length, lessThanOrEqualTo(2));
  });

  test(
    'mirror-only 403 preserves fallback to working original',
    () async {
      final proxy = RipperRangeProxy(
        concurrency: 4,
        userAgent: 'test',
        now: () => clockNow,
      );
      addTearDown(proxy.close);
      await proxy.start();

      final mirror1 = endpoint('/mirror-403-after-head');
      final mirror2 = endpoint('/403-mirror');
      final orig = endpoint('/good-slow-head');
      final url = proxy.registerCandidates(
        [mirror1, mirror2, orig],
        originals: [orig],
      );

      final (res, bytes) = await fetch(url);
      expect(res.statusCode, HttpStatus.ok);
      expect(bytes, source);
      expect(paths, contains('/mirror-403-after-head'));
      expect(paths, contains('/good-slow-head'));
    },
  );

  test(
    'when >8 candidates exist and 8+ mirrors return 403, untried original past index 8 still recovers',
    () async {
      final proxy = RipperRangeProxy(
        concurrency: 4,
        userAgent: 'test',
        now: () => clockNow,
      );
      addTearDown(proxy.close);
      await proxy.start();

      final headMirror = endpoint('/mirror-403-after-head');
      final badMirrors = [
        for (var i = 1; i <= 8; i++) endpoint('/403-m$i'),
      ];
      final orig = endpoint('/good-slow-head');
      final url = proxy.registerCandidates(
        [headMirror, ...badMirrors, orig],
        originals: [orig],
      );

      final (res, bytes) = await fetch(url);
      expect(res.statusCode, HttpStatus.ok);
      expect(bytes, source);
      expect(paths, contains('/mirror-403-after-head'));
      expect(paths, contains('/good-slow-head'));
      expect(
        paths.where((p) => p.startsWith('/403-m')).length,
        greaterThanOrEqualTo(7),
      );
    },
  );

  test(
    'hanging upstream returns 502 strictly below mpv 5s network-timeout',
    () async {
      final proxy = RipperRangeProxy(
        concurrency: 4,
        userAgent: 'test',
        now: () => clockNow,
      );
      addTearDown(proxy.close);
      await proxy.start();

      final url = proxy.registerCandidates([endpoint('/hang')]);
      final watch = Stopwatch()..start();
      final (res, bytes) = await fetch(url);
      expect(res.statusCode, HttpStatus.badGateway);
      expect(bytes, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 4800)));
    },
  );

  test(
    'transient failure after >60s idle gap resets client and recovers cleanly',
    () async {
      final proxy = RipperRangeProxy(
        concurrency: 4,
        userAgent: 'test',
        now: () => clockNow,
      );
      addTearDown(proxy.close);
      await proxy.start();

      final track0 = proxy.registerCandidates([endpoint('/good')]);
      final (firstRes, firstBytes) = await fetch(track0, range: 'bytes=0-1023');
      expect(firstRes.statusCode, HttpStatus.partialContent);
      expect(firstBytes, source.sublist(0, 1024));

      // Simulate long pause / Android freeze (>60s idle gap).
      clockNow = clockNow.add(const Duration(minutes: 5));

      final track1 = proxy.registerCandidates([endpoint('/transient-once')]);
      final (secondRes, secondBytes) = await fetch(
        track1,
        range: 'bytes=0-1023',
      );
      expect(secondRes.statusCode, HttpStatus.partialContent);
      expect(secondBytes, source.sublist(0, 1024));
    },
  );

  test(
    'client disconnect and proxy.close abort in-flight requests cleanly',
    () async {
      final started = Completer<void>();
      final drained = Completer<void>();
      var sawActive = false;
      final proxy = RipperRangeProxy(
        concurrency: 4,
        userAgent: 'test',
        now: () => clockNow,
        onActiveRequestsChanged: (active) {
          if (active > 0) {
            sawActive = true;
            if (!started.isCompleted) started.complete();
          } else if (sawActive && !drained.isCompleted) {
            drained.complete();
          }
        },
      );
      addTearDown(proxy.close);
      await proxy.start();

      final url = Uri.parse(proxy.registerCandidates([endpoint('/hang')]));
      final sock = await Socket.connect(url.host, url.port);
      sock.write('GET ${url.path} HTTP/1.1\r\nHost: ${url.host}\r\n\r\n');
      await sock.flush();
      await started.future.timeout(const Duration(seconds: 1));
      sock.destroy();
      await drained.future.timeout(const Duration(seconds: 1));

      // Pending request cancelled by proxy.close() must settle promptly.
      final pending = fetch(
        url.toString(),
      ).then<Object>((value) => value, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      proxy.close();
      await pending.timeout(const Duration(seconds: 1));
    },
  );
}
