import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CDN synthesis preserves signed path/query and resets peer ports', () {
    final urls = RipperCdnResolver.candidates([
      'https://peer.szbdyd.com:4483/upgcxcode/video.m4s?sign=a%2Bb&x=1',
    ], overseas: true);
    final synthetic = urls.firstWhere(
      (u) => u.host == RipperCdnResolver.overseasHosts.first,
    );
    expect(synthetic.port, 443);
    expect(synthetic.query, 'sign=a%2Bb&x=1');
    expect(synthetic.path, '/upgcxcode/video.m4s');
    expect(
      RipperCdnResolver.candidates([
        'https://example.com/v.m4s',
      ], overseas: true),
      isEmpty,
    );
  });

  test(
    'Akamai-only representations supply synthetic nodes in both regions',
    () {
      for (final overseas in [true, false]) {
        final urls = RipperCdnResolver.candidates([
          'https://video.akamaized.net/v.m4s?sign=original',
        ], overseas: overseas);
        expect(urls.length, greaterThan(1));
        expect(urls.every((u) => u.query == 'sign=original'), isTrue);
      }
    },
  );

  test('open, bounded, suffix and invalid downstream ranges', () {
    expect(RipperRangeProxy.parseRange(null, 100), (0, 99));
    expect(RipperRangeProxy.parseRange('bytes=20-', 100), (20, 99));
    expect(RipperRangeProxy.parseRange('bytes=20-999', 100), (20, 99));
    expect(RipperRangeProxy.parseRange('bytes=-10', 100), (90, 99));
    for (final value in [
      'bytes=100-',
      'bytes=20-10',
      'bytes=-0',
      'bytes=1-2,4-5',
      'bytes=-',
    ]) {
      expect(
        () => RipperRangeProxy.parseRange(value, 100),
        throwsFormatException,
      );
    }
  });

  test('empty-response bans distinguish nodes, addresses, and pairs', () {
    final bans = RipperBanList();
    final a = Uri.parse('https://a.bilivideo.com/video.m4s?sign=one');
    final b = a.replace(host: 'b.bilivideo.com');
    bans
      ..failure(a, status: 403)
      ..failure(a, status: 403);
    expect(bans.allows(a), isTrue);
    bans.success(b);
    expect(bans.allows(a), isFalse);
    expect(bans.allows(b), isTrue);
    bans.success(a.replace(query: 'sign=two'));
    expect(bans.allows(a), isFalse);
    expect(bans.allows(a.replace(query: 'sign=two')), isTrue);
    final partial = RipperBanList()
      ..failure(a, received: 10)
      ..failure(a, received: 10);
    expect(partial.allows(a), isTrue);
  });

  test(
    'resolver follows original JavaScript reference traces in both regions',
    () {
      final fixtures = jsonDecode(
        File('test/fixtures/ripper_resolver.json').readAsStringSync(),
      ) as List;
      for (final fixture in fixtures) {
        var now = DateTime.fromMillisecondsSinceEpoch(100000);
        final rep = fixture['representation'];
        final originals = <String>[
          rep['baseUrl'],
          ...List<String>.from(rep['backupUrl']),
        ];
        final overseas = fixture['mode'] == 'overseas';
        final urls = RipperCdnResolver.candidates(
          originals,
          overseas: overseas,
        );
        expect(urls.map((u) => u.toString()).toList(), fixture['urls']);
        final resolver = RipperCdnResolver(
          urls,
          originals: originals.map(Uri.parse).toList(),
          overseas: overseas,
          now: () => now,
        );
        for (final step in fixture['steps']) {
          final args = step['args'] as List;
          List<Uri>? result;
          switch (step['op']) {
            case 'startupCandidates':
              result = resolver.startupCandidates();
            case 'rangeCandidates':
              result = resolver.rangeCandidates();
            case 'rescueCandidates':
              result = resolver.rescueCandidates();
            case 'ordered':
              result = resolver.ordered(args[0]);
            case 'success':
              resolver.success(
                Uri.parse(args[0]),
                args[1],
                const Duration(seconds: 1),
              );
            case 'failure':
              resolver.failure(
                Uri.parse(args[0]),
                status: args[1]['status'],
                received: args[2],
              );
            case 'sample':
              resolver.sample(Uri.parse(args[0]), (args[1] as num).toDouble());
            case 'advance':
              now = now.add(Duration(milliseconds: args[0]));
            case 'speed':
              expect(
                resolver.speed(Uri.parse(args[0])),
                closeTo(step['expected'], 0.01),
              );
          }
          if (result != null) {
            expect(
              result.map((u) => u.toString()).toList(),
              step['expected'],
              reason: '${fixture['mode']} ${step['op']}',
            );
          }
        }
      }
    },
  );

  test('weighted assignments match upstream including sparse exploration', () {
    final fixtures = jsonDecode(
      File('test/fixtures/ripper_assignments.json').readAsStringSync(),
    ) as List;
    final assignments = RipperAssignments();
    for (final fixture in fixtures) {
      final urls = (fixture['urls'] as List)
          .cast<String>()
          .map(Uri.parse)
          .toList();
      final resolver = RipperCdnResolver(urls);
      for (var i = 0; i < urls.length; i++) {
        resolver.recordSuccess(
          urls[i],
          (fixture['speeds'][i] as num).toDouble(),
        );
      }
      for (final step in fixture['steps']) {
        expect(
          assignments
              .assign(urls, resolver, step['count'])
              .map((u) => u.toString())
              .toList(),
          step['expected'],
        );
      }
    }
  });

  test('custom nodes restrict both synthesized URLs and originals', () {
    final urls = RipperCdnResolver.candidates(
      [
        'https://video.akamaized.net/v.m4s?sign=a%2Bb',
      ],
      overseas: true,
      customHosts: [
        'https://UPOS-SZ-MIRRORALI.BILIVIDEO.COM:4483/path',
        'example.com',
      ],
    );
    expect(urls, hasLength(1));
    expect(urls.single.host, 'upos-sz-mirrorali.bilivideo.com');
    expect(urls.single.query, 'sign=a%2Bb');
    expect(urls.single.port, 443);
    expect(RipperCdnResolver.normalizeHost('bilivideo.com.evil.com'), isNull);
    expect(RipperCdnResolver.normalizeHost('127.0.0.1'), isNull);
  });

  test('speed survives signature refresh but expires and tiny tails do not renew it', () {
    var now = DateTime.fromMillisecondsSinceEpoch(100000);
    final url = Uri.parse('https://a.bilivideo.com/v.m4s?sign=old');
    final fresh = url.replace(query: 'sign=new');
    final resolver = RipperCdnResolver([url], now: () => now)
      ..success(url, 100000, const Duration(seconds: 1));
    expect(resolver.speed(fresh), 100000);
    now = now.add(const Duration(seconds: 89));
    resolver.success(fresh, 1024, const Duration(seconds: 1));
    expect(resolver.speed(fresh), 100000);
    now = now.add(const Duration(seconds: 2));
    expect(resolver.speed(fresh), 0);
  });

  late HttpServer cdn;
  late HttpClient client;
  late RipperRangeProxy proxy;
  late Uint8List source;
  late List<String> paths;
  late List<(String, int, int)> requests;
  late Set<int> interruptedEnds;
  late int active;
  late int peak;
  late List<Timer> timers;

  setUp(() async {
    source = Uint8List.fromList(List.generate(1100000, (i) => (i * 37) % 251));
    paths = [];
    requests = [];
    interruptedEnds = {};
    timers = [];
    active = peak = 0;
    cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((request) async {
        paths.add(request.uri.path);
        active++;
        peak = max(peak, active);
        final response = request.response;
        unawaited(
          response.done.then((_) => active--, onError: (Object _) => active--),
        );
        try {
          final range = RipperRangeProxy.parseRange(
            request.headers.value('range'),
            source.length,
          );
          final (start, end) = range;
          requests.add((request.uri.path, start, end));
          if (request.uri.path == '/forbidden') {
            response.statusCode = 403;
            await response.close();
            return;
          }
          if (request.uri.path == '/ignored') {
            response.statusCode = 200;
            await response.close();
            return;
          }
          response.statusCode = 206;
          final reportedTotal = request.uri.path == '/changed' && start > 0
              ? source.length + 100
              : source.length;
          final reportedStart = request.uri.path == '/wrong'
              ? start + 1
              : start;
          response.headers.set(
            'Content-Range',
            'bytes $reportedStart-$end/$reportedTotal',
          );
          var body = source.sublist(start, end + 1);
          if (request.uri.path == '/resume-primary' &&
              start >= 65536 &&
              body.length > 65536) {
            response.add(body.sublist(0, 65536));
            await response.flush();
            timers.add(
              Timer(const Duration(seconds: 3), () {
                try {
                  response.add(body.sublist(65536));
                  unawaited(response.close().catchError((Object _) {}));
                } catch (_) {}
              }),
            );
            return;
          }
          if (request.uri.path == '/resume' &&
              start >= 65536 &&
              body.length > 65536 &&
              interruptedEnds.add(end)) {
            response.add(body.sublist(0, 65536));
            await response.flush();
            // Verified headers, then an interrupted body. The next request must
            // start at the last received byte, even on another CDN.
            await response.close();
            return;
          }
          if (request.uri.path == '/short') {
            body = body.sublist(0, body.length ~/ 2);
          }
          if (request.uri.path == '/large') {
            body = Uint8List.fromList([...body, 0]);
          }
          void send() {
            try {
              response.add(body);
              unawaited(response.close().catchError((Object _) {}));
            } catch (_) {}
          }

          if (request.uri.path == '/primary' && start >= 65536) {
            timers.add(Timer(const Duration(seconds: 10), send));
          } else if ((request.uri.path == '/rescue' ||
                  request.uri.path == '/resume-backup') &&
              start < 65536) {
            timers.add(Timer(const Duration(milliseconds: 500), send));
          } else if (request.uri.path == '/jam' && end > start) {
            timers.add(Timer(const Duration(seconds: 10), send));
          } else if (request.uri.path == '/seek' &&
              start > 0 &&
              start < 900000) {
            timers.add(Timer(const Duration(milliseconds: 200), send));
          } else if (request.uri.path == '/slow') {
            timers.add(Timer(const Duration(seconds: 3), send));
          } else {
            // Different delays force out-of-order completion and real overlap.
            timers.add(Timer(Duration(milliseconds: start % 7 + 10), send));
          }
        } catch (_) {
          try {
            await response.close();
          } catch (_) {}
        }
      });
    client = HttpClient();
    proxy = RipperRangeProxy(concurrency: 4, userAgent: 'test');
    await proxy.start();
  });

  tearDown(() async {
    proxy.close();
    client.close(force: true);
    for (final timer in timers) {
      timer.cancel();
    }
    await cdn.close(force: true);
  });

  Uri endpoint(String path) => Uri.parse('http://127.0.0.1:${cdn.port}$path');
  String register(List<String> paths) =>
      proxy.registerCandidates(paths.map(endpoint).toList());
  Future<(HttpClientResponse, List<int>)> fetch(
    String url, {
    String? range,
    String method = 'GET',
  }) async {
    final req = await client.openUrl(method, Uri.parse(url));
    if (range != null) req.headers.set('range', range);
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (res, bytes);
  }

  test(
    'parallel chunks arrive in exact file order with shared connection limit',
    () async {
      final url = register(['/good']);
      final results = await Future.wait([
        fetch(url),
        fetch(url, range: 'bytes=3-800000'),
      ]);
      expect(results[0].$1.statusCode, 200);
      expect(results[0].$2, source);
      expect(results[1].$1.statusCode, 206);
      expect(results[1].$2, source.sublist(3, 800001));
      expect(peak, greaterThan(1));
      expect(peak, lessThanOrEqualTo(4));
    },
  );

  test('HEAD, suffix, open-ended seek and 416 responses', () async {
    final url = register(['/good']);
    final head = await fetch(url, method: 'HEAD');
    expect(head.$1.contentLength, source.length);
    expect(head.$2, isEmpty);
    expect(
      (await fetch(url, range: 'bytes=-19')).$2,
      source.sublist(source.length - 19),
    );
    expect(
      (await fetch(url, range: 'bytes=1099900-')).$2,
      source.sublist(1099900),
    );
    expect((await fetch(url, range: 'bytes=2000000-')).$1.statusCode, 416);
  });

  for (final bad in [
    '/forbidden',
    '/ignored',
    '/wrong',
    '/short',
    '/large',
    '/changed',
  ]) {
    test(
      'rejects $bad and retries another CDN without corrupting bytes',
      () async {
        final result = await fetch(register([bad, '/good']));
        expect(result.$1.statusCode, 200);
        expect(result.$2, source);
        expect(paths, contains(bad));
        expect(paths, contains('/good'));
      },
    );
  }

  test('slow first response is hedged before its first-byte timeout', () async {
    final watch = Stopwatch()..start();
    final result = await fetch(
      register(['/slow', '/good']),
      range: 'bytes=0-100',
    );
    expect(result.$2, source.sublist(0, 101));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test(
    'all invalid upstream responses produce 502, never fake media bytes',
    () async {
      final result = await fetch(register(['/wrong']));
      expect(result.$1.statusCode, 502);
      expect(result.$2, isEmpty);
    },
  );

  test('session close cancels active and queued ranges promptly', () async {
    final url = register(['/slow']);
    final pending = fetch(url)
        .then<Object>((value) => value, onError: (Object e) => e);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    proxy.close();
    await pending.timeout(const Duration(seconds: 1));
    final count = paths.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(paths.length, count);
  });

  test(
    'unknown paths cannot turn the listener into an arbitrary URL proxy',
    () async {
      final url = Uri.parse(register(['/good']));
      final result = await fetch(
        url.replace(path: '/https://example.com').toString(),
      );
      expect(result.$1.statusCode, 404);
      expect(paths, isEmpty);
    },
  );
  test(
    'a seek disconnect stops old work and new ranges remain usable',
    () async {
      final url = Uri.parse(register(['/seek']));
      final socket = await Socket.connect(url.host, url.port);
      socket.write('GET ${url.path} HTTP/1.1\r\nHost: ${url.host}\r\n\r\n');
      await socket.flush();
      await socket.first;
      socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final oldCount = paths.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(paths.length, oldCount);
      expect(oldCount, lessThan(18));
      final next = await fetch(url.toString(), range: 'bytes=900000-900999');
      expect(next.$2, source.sublist(900000, 901000));
    },
  );
  test(
    'eight-thread saturation still leaves a connection for rescue',
    () async {
      source = Uint8List(3 * 1024 * 1024);
      proxy.close();
      var inFlightPeak = 0;
      proxy = RipperRangeProxy(
        concurrency: 8,
        userAgent: 'test',
        onActiveRequestsChanged: (count) =>
            inFlightPeak = max(inFlightPeak, count),
      );
      await proxy.start();
      // Separate tracks each start with an unresponsive primary. Together they
      // fill all ordinary slots; no ordinary connection will finish in 3 s.
      final results = await Future.wait(
        List.generate(
          8,
          (_) =>
              fetch(register(['/primary', '/rescue']), range: 'bytes=0-262143'),
        ),
      ).timeout(const Duration(seconds: 3));
      for (final result in results) {
        expect(result.$1.statusCode, 206);
        expect(result.$2, source.sublist(0, 262144));
      }
      expect(inFlightPeak, lessThanOrEqualTo(8));
      expect(paths, contains('/rescue'));
    },
  );
  test('2 MiB media does not become dozens of tiny round trips', () async {
    source = Uint8List(2 * 1024 * 1024);
    proxy.close();
    proxy = RipperRangeProxy(concurrency: 8, userAgent: 'test');
    await proxy.start();
    final result = await fetch(register(['/good']));
    expect(result.$2, source);
    expect(paths.length, lessThanOrEqualTo(10));
  });

  test(
    'interrupted verified pieces resume without dropping or repeating bytes',
    () async {
      proxy.close();
      proxy = RipperRangeProxy(concurrency: 8, userAgent: 'test');
      await proxy.start();
      final result = await fetch(register(['/resume']));
      expect(result.$2, source);
      final pieces = requests.where((r) => r.$2 >= 65536).toList();
      expect(
        pieces.any(
          (a) => pieces.any((b) => a.$3 == b.$3 && b.$2 == a.$2 + 65536),
        ),
        isTrue,
      );
    },
  );

  test('hedge resumes the live primary prefix on a different node', () async {
    final watch = Stopwatch()..start();
    final result = await fetch(register(['/resume-primary', '/resume-backup']));
    expect(result.$2, source);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    final originals = requests.where(
      (r) => r.$1 == '/resume-primary' && r.$2 >= 65536,
    );
    expect(
      originals.any(
        (a) => requests.any(
          (b) =>
              b.$1 == '/resume-backup' && b.$3 == a.$3 && b.$2 == a.$2 + 65536,
        ),
      ),
      isTrue,
    );
  });
}
