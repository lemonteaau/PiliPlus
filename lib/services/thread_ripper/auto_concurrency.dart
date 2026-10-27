// Bilibili-thread-ripper 2026.10.7.1 createAutoConcurrency, MIT.
import 'dart:math';

/// One controller per player; learned limits survive a change of video.
class RipperAutoConcurrency {
  RipperAutoConcurrency({int Function()? now})
    : _now = now ?? (() => _clock.elapsedMilliseconds);
  static final _clock = Stopwatch()..start();
  final int Function() _now;
  static const ladder = [8, 12, 16, 24, 32, 48, 64];
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
  // mpv's cache state, read at most twice a second: each read is a synchronous
  // call on the UI isolate, and position updates come with every frame.
  ({int at, bool full})? _cache;
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
    // Native: only a stall steps past a trial still waiting for its verdict.
    // Pressure stacked steps every 2.5 s, so each trial was replaced unjudged.
    if (!strong && _trial != null) return false;
    var next = _level + 1;
    while (next < ladder.length && _rests.containsKey(next)) {
      if (_rests[next]!.hard || !strong) return false;
      next++;
    }
    if (next >= ladder.length) return false;
    // A stall before the last step's verdict: both are judged together,
    // against the level before them. Stalls every few seconds otherwise left
    // only the top step to judge, and its verdict went back a single level.
    final pending = _trial;
    _setLevel(
      next,
      pending == null
          ? _Trial(
              _level,
              next,
              at,
              _throughput(at),
              quick: !strong,
              startup: _startup,
            )
          : _Trial(pending.from, next, at, pending.baseline),
    );
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
    _judge(trial, at);
  }

  void _judge(_Trial trial, int at) {
    _trial = null;
    if (trial.stalled || _saturation(at) < .6 || trial.baseline <= 0) return;
    // Native: each thread is a connection of its own. Where the link is the
    // limit, more of them only slow the piece mpv needs next, so a quick
    // trial's level stays for a clear gain, not for noise around the same
    // throughput.
    if (_throughput(at) >= trial.baseline * (trial.quick ? 1.1 : 1)) return;
    _rests[trial.level] = (until: at + 90000, hard: false);
    _setLevel(trial.from, null);
    // The step brought nothing, so neither did ending the start with it.
    if (trial.quick) _startup = trial.startup;
  }

  void activity() => _activityAt = _now();

  void demand(int active, int limit, int queued) =>
      _busy(active >= limit && queued > 0);

  /// Native: mpv waits on bytes that are still downloading. The proxy asks for
  /// no more pieces than it has connections, so [demand]'s queue behind busy
  /// connections hardly ever forms there, and a trial was never judged.
  /// The writer wakes for every chunk; gaps under a bucket do not split a span.
  ///
  /// mpv's cache, far smaller than upstream's 45 s buffer, often fills within
  /// a trial's ten seconds, and an idle download proves nothing; so while mpv
  /// waits on the network, five seconds at the new level decide a quick trial.
  void starved(bool value) {
    _busy(value, merge: 250);
    final at = _now();
    if (_trial case final trial?
        when trial.quick && at - trial.at >= 5000 && _saturation(at) >= .6) {
      _judge(trial, at);
    }
  }

  void _busy(bool saturated, {int merge = 0}) {
    if (_saturated == saturated) return;
    final at = _now();
    if (_saturated) _spans.add((from: _saturatedSince, to: at));
    _saturated = saturated;
    _saturatedSince = at;
    if (saturated && _spans.isNotEmpty && at - _spans.last.to < merge) {
      _saturatedSince = _spans.removeLast().from;
    }
    _saturation(at);
  }

  bool stall() {
    _trial?.stalled = true;
    return _stepUp(true);
  }

  /// [cacheFull]: mpv's cache holds all it may, a limit that can sit below 15 s.
  bool buffer(double ahead, bool playing, {bool Function()? cacheFull}) {
    final at = _now();
    bool isFull() {
      if (cacheFull == null) return false;
      if (_cache case final cache? when at - cache.at < 500) return cache.full;
      return (_cache = (at: at, full: cacheFull())).full;
    }

    _ahead.add((at: at, seconds: ahead));
    _ahead.removeWhere((s) => at - s.at > 1250);
    final start = _startup;
    if (start != null && at >= start.until) {
      _startup = null;
    } else if (start != null &&
        at - _changedAt >= 2500 &&
        (ahead >= 15 || isFull())) {
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
    // A full cache is not the download falling behind, though its size can
    // hold it under 6 s.
    if (isFull()) return false;
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
    _cache = null;
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
  _Trial(
    this.from,
    this.level,
    this.at,
    this.baseline, {
    this.quick = false,
    this.startup,
  });
  final int from;
  final int level;
  final int at;
  final double baseline;
  // Native: a step on buffer pressure or slow first bytes, which on a link
  // that is the limit come from waiting behind the piece mpv needs next, not
  // from too few connections. Judged after five saturated seconds and kept
  // only for a clear gain. A stall's step keeps upstream's verdict: where
  // single connections are the limit, gains show over several levels rather
  // than within five seconds.
  final bool quick;
  // The start this step ended, resumed if the step goes back.
  final ({int base, int until})? startup;
  bool stalled = false;
}
