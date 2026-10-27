import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final scenarios = jsonDecode(
    File('test/fixtures/ripper_auto.json').readAsStringSync(),
  ) as List;
  for (final scenario in scenarios) {
    test('automatic concurrency matches upstream: ${scenario['name']}', () {
      var now = 5000;
      final auto = RipperAutoConcurrency(now: () => now);
      for (final step in scenario['steps'] as List) {
        now = step['at'];
        final args = step['args'] as List;
        switch (step['op']) {
          case 'demand':
            auto.demand(args[0], args[1], args[2]);
          case 'activity':
            auto.activity();
          case 'delivered':
            auto.delivered((args[0] as num).toInt());
          case 'stall':
            auto.stall();
          case 'pushback':
            auto.pushback();
          case 'newSession':
            auto.newSession();
          case 'buffer':
            auto.buffer((args[0] as num).toDouble(), args[1]);
        }
        expect(auto.threads, step['threads'], reason: '${step['op']} at $now');
      }
    });
  }

  test('a full mpv cache below 15 s also ends the start', () {
    var now = 5000;
    var asked = 0;
    final auto = RipperAutoConcurrency(now: () => now);
    bool full() {
      asked++;
      return true;
    }

    auto.newSession();
    expect(auto.threads, 16);
    now += 2000;
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (16, 0));
    now += 600;
    auto.buffer(4, true, cacheFull: () => false);
    expect(auto.threads, 16);
    // Read at most twice a second.
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (16, 0));
    now += 500;
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (12, 1));
    now += 2500;
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (8, 2));
    now += 2500;
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (8, 2));
  });

  test('a full mpv cache below 6 s is not buffer pressure', () {
    var now = 5000;
    var asked = 0;
    final auto = RipperAutoConcurrency(now: () => now);
    // Bytes keep arriving while the buffer stays at 4 s, where the cache's
    // size holds it at a high bitrate. Position updates come at 10 Hz.
    void play(int ms, bool full) {
      for (var i = 0; i < ms; i += 100) {
        now += 100;
        auto
          ..activity()
          ..buffer(
            4,
            true,
            cacheFull: () {
              asked++;
              return full;
            },
          );
      }
    }

    play(4000, true);
    expect(auto.threads, 8);
    // Read once per second of pressure, not on every position update.
    expect(asked, 2);
    play(2000, false);
    expect(auto.threads, 12);
  });

  group('while mpv waits on the network', () {
    late int now;
    late RipperAutoConcurrency auto;
    setUp(() {
      now = 5000;
      auto = RipperAutoConcurrency(now: () => now);
    });

    // The proxy's writer wakes for each chunk of the piece mpv needs next,
    // passes it on and waits again.
    void flow(int bytesPerSecond, int ms) {
      for (var i = 0; i < ms; i += 250) {
        auto.starved(true);
        now += 245;
        auto
          ..activity()
          ..delivered(bytesPerSecond ~/ 4)
          ..starved(false);
        now += 5;
      }
    }

    // A low buffer that stopped growing while bytes keep arriving.
    void press() {
      final before = auto.threads;
      for (var i = 0; i < 20 && auto.threads == before; i++) {
        flow(1000000, 250);
        auto.buffer(4, true);
      }
    }

    test('a step on pressure without a clear gain goes back in 5 s', () {
      flow(1000000, 5000);
      press();
      expect(auto.threads, 12);
      // The link is the limit: twelve connections deliver what eight did.
      flow(1050000, 4500);
      expect(auto.threads, 12);
      flow(1050000, 1000);
      expect(auto.threads, 8);
      // Pressure does not retry the resting level.
      press();
      expect(auto.threads, 8);
    });

    test('a step on pressure that delivers more stays', () {
      flow(1000000, 5000);
      press();
      flow(1500000, 6000);
      expect(auto.threads, 12);
    });

    test('pressure waits for the verdict on the step before it', () {
      flow(1000000, 5000);
      press();
      for (var i = 0; i < 16; i++) {
        flow(1000000, 250);
        auto.buffer(4, true);
      }
      expect(auto.threads, 12);
    });

    test("a stall's step keeps upstream's verdict", () {
      flow(1000000, 5000);
      expect(auto.stall(), isTrue);
      // Where single connections are the limit, gains show over several
      // levels: five seconds of the same throughput do not send it back.
      flow(1000000, 6000);
      expect(auto.threads, 12);
      flow(1000000, 5000);
      expect(auto.threads, 12);
    });

    test('a stall during a trial is judged with it, from the level before', () {
      flow(1000000, 5000);
      press();
      flow(1000000, 2500);
      expect(auto.stall(), isTrue);
      expect(auto.threads, 16);
      flow(950000, 10250);
      expect(auto.threads, 8);
    });

    test('undoing the step that ended the start resumes the start', () {
      auto.newSession();
      expect(auto.threads, 16);
      flow(1000000, 2000);
      press();
      expect(auto.threads, 24);
      flow(1000000, 5250);
      expect(auto.threads, 16);
      // Back to the level before the start once mpv's cache is full.
      now += 2500;
      auto.buffer(5, true, cacheFull: () => true);
      expect(auto.threads, 12);
      now += 2500;
      auto.buffer(5, true, cacheFull: () => true);
      expect(auto.threads, 8);
    });
  });
}
