import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'automatic concurrency matches upstream trials, pressure and rate limits',
    () {
      var now = 5000;
      final auto = RipperAutoConcurrency(now: () => now);
      final steps = jsonDecode(
        File('test/fixtures/ripper_auto.json').readAsStringSync(),
      ) as List;
      for (final step in steps) {
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
    },
  );
}
