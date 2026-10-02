// Bilibili-thread-ripper 2026.9.29.2 createAutoConcurrency, MIT.
import 'dart:math';

/// One controller per player; learned limits survive a change of video.
class RipperAutoConcurrency {
  RipperAutoConcurrency({int Function()? now})
    : _now = now ?? (() => _clock.elapsedMilliseconds);
  static final _clock = Stopwatch()..start();
  final int Function() _now;
  static const ladder = [8, 12, 16, 24, 32];
  void Function()? onChanged;
  int _level = 0;
  int _changedAt = 0;
  int _activityAt = -1000000;
  int _pressureSince = 0;
  bool _saturated = false;
  int _saturatedSince = 0;
  final _rests = <int, ({int until, bool hard})>{};
  final _buckets = <({int at, int bytes})>[];
  final _spans = <({int from, int to})>[];
  final _ahead = <({int at, double seconds})>[];
  _Trial? _trial;
  // A start above the player's own level, which it returns to once ahead.
  ({int base, int until})? _startup;
  int get threads => ladder[_level];

  double _throughput(int at) {
    _buckets.removeWhere((b) => at - b.at > 5000);
    if (_buckets.isEmpty) return 0;
    return _buckets.fold(0, (sum, b) => sum + b.bytes) *
        1000 /
        max(1000, _buckets.last.at - _buckets.first.at + 250);
  }

  double _saturation(int at) {
    final from = at - 5000;
    _spans.removeWhere((span) => span.to <= from);
    var busy = _spans.fold(
      0,
      (sum, span) => sum + max(0, span.to - max(span.from, from)),
    );
    if (_saturated) busy += max(0, at - max(_saturatedSince, from));
    return min(1, busy / 5000);
  }

  void _setLevel(int level, _Trial? trial) {
    _level = level;
    _changedAt = _now();
    _pressureSince = 0;
    _trial = trial;
    onChanged?.call();
  }

  bool _stepUp(bool strong) {
    final at = _now();
    _rests.removeWhere((_, rest) => rest.until <= at);
    if (at - _changedAt < 2500 || _rests[_level]?.hard == true) return false;
    var next = _level + 1;
    while (next < ladder.length && _rests.containsKey(next)) {
      if (_rests[next]!.hard || !strong) return false;
      next++;
    }
    if (next >= ladder.length) return false;
    _setLevel(next, _Trial(_level, next, at, _throughput(at)));
    _startup = null;
    return true;
  }

  // Up to 16 threads, never onto or past a level the server refused.
  int _startupLevel(int at) {
    _rests.removeWhere((_, rest) => rest.until <= at);
    if (_rests[_level]?.hard == true) return _level;
    var level = _level;
    while (level < 2 && _rests[level + 1]?.hard != true) {
      level++;
    }
    return level;
  }

  void delivered(int bytes) {
    final at = _now();
    if (_buckets.isNotEmpty && at - _buckets.last.at < 250) {
      final last = _buckets.removeLast();
      _buckets.add((at: last.at, bytes: last.bytes + bytes));
    } else {
      _buckets.add((at: at, bytes: bytes));
    }
    _buckets.removeWhere((b) => at - b.at > 5000);
    final trial = _trial;
    if (trial == null || at - trial.at < 10000) return;
    _trial = null;
    if (trial.stalled || _saturation(at) < .6 || trial.baseline <= 0) return;
    if (_throughput(at) < trial.baseline) {
      _rests[trial.level] = (until: at + 90000, hard: false);
      _setLevel(trial.from, null);
    }
  }

  void activity() => _activityAt = _now();

  void demand(int active, int limit, int queued) {
    final saturated = active >= limit && queued > 0;
    if (_saturated == saturated) return;
    final at = _now();
    if (_saturated) _spans.add((from: _saturatedSince, to: at));
    _saturated = saturated;
    _saturatedSince = at;
    _saturation(at);
  }

  bool stall() {
    _trial?.stalled = true;
    return _stepUp(true);
  }

  /// [cacheFull]: mpv's cache holds all it may, a limit that can sit below 15 s.
  bool buffer(double ahead, bool playing, {bool Function()? cacheFull}) {
    final at = _now();
    _ahead.add((at: at, seconds: ahead));
    _ahead.removeWhere((s) => at - s.at > 1250);
    final start = _startup;
    if (start != null && at >= start.until) {
      _startup = null;
    } else if (start != null &&
        at - _changedAt >= 2500 &&
        (ahead >= 15 || (cacheFull?.call() ?? false))) {
      if (_level > start.base) _setLevel(_level - 1, null);
      if (_level <= start.base) _startup = null;
    }
    final earlier = _ahead.where((s) => at - s.at >= 1000).firstOrNull;
    final pressed =
        playing &&
        at - _activityAt < 1500 &&
        ahead < 6 &&
        earlier != null &&
        ahead <= earlier.seconds + .05;
    if (!pressed) {
      _pressureSince = 0;
      return false;
    }
    if (_pressureSince == 0) {
      _pressureSince = at;
      return false;
    }
    if (at - _pressureSince < 1000) return false;
    _pressureSince = 0;
    return _stepUp(false);
  }

  bool slow() => _saturation(_now()) >= .6 && _stepUp(false);

  void pushback() {
    _rests[_level] = (until: _now() + 180000, hard: true);
    if (_level > 0) _setLevel(_level - 1, null);
  }

  void newSession() {
    final at = _now();
    _ahead.clear();
    _pressureSince = 0;
    _trial = null;
    _buckets.clear();
    _spans.clear();
    if (_saturated) _saturatedSince = at;
    final base = _startup?.base ?? _level;
    final target = _startupLevel(at);
    if (target > _level) _setLevel(target, null);
    _startup = _level > base ? (base: base, until: at + 30000) : null;
  }
}

class _Trial {
  _Trial(this.from, this.level, this.at, this.baseline);
  final int from;
  final int level;
  final int at;
  final double baseline;
  bool stalled = false;
}
