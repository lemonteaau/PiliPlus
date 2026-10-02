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
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (12, 1));
    now += 2500;
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (8, 2));
    now += 2500;
    auto.buffer(4, true, cacheFull: full);
    expect((auto.threads, asked), (8, 2));
  });
}
