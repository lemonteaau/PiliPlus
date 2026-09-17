// Ported from MrTangLuyao/Bilibili-thread-ripper (MIT), src/cdn-resolver.js.
// Multi-CDN candidate pool + per-video ban list + health-aware routing.
library;

/// Mainland hosts that can directly serve the current media range.
const List<String> ripperMainlandHosts = [
  'upos-sz-mirrorali.bilivideo.com',
  'upos-sz-mirrorhw.bilivideo.com',
  'upos-sz-mirrorbos.bilivideo.com',
  'upos-sz-mirror08c.bilivideo.com',
  'upos-sz-mirrorbd.bilivideo.com',
  'upos-sz-mirror14b.bilivideo.com',
  'upos-sz-estgoss.bilivideo.com',
  'upos-sz-mirrorcos.bilivideo.com',
];

/// Overseas hosts preferred when the path back to the mainland is poor.
const List<String> ripperOverseasHosts = [
  'upos-sz-mirrorcosov.bilivideo.com',
  'upos-sz-mirroraliov.bilivideo.com',
  'cn-hk-eq-01-01.bilivideo.com',
  'cn-hk-eq-01-03.bilivideo.com',
];

bool isAkamaiUrl(String value) {
  try {
    return Uri.parse(value).host.toLowerCase().endsWith('.akamaized.net');
  } catch (_) {
    return false;
  }
}

String hostOf(String value) {
  try {
    return Uri.parse(value).host.toLowerCase();
  } catch (_) {
    return '';
  }
}

String? swapHost(String rawUrl, String targetHost) {
  if (isAkamaiUrl(rawUrl)) return null;
  final host = targetHost.toLowerCase();
  final pool = [...ripperOverseasHosts, ...ripperMainlandHosts];
  if (!pool.contains(host)) return null;
  try {
    return Uri.parse(rawUrl).replace(host: host).toString();
  } catch (_) {
    return null;
  }
}

/// Builds the download candidate pool from a DASH representation's play urls.
/// Mirrors `representationUrls`: keep usable originals, then synthesize the
/// rest of the pool by host-swapping a non-Akamai donor.
List<String> ripperCandidateUrls(
  Iterable<String> playUrls, {
  required bool overseas,
}) {
  final originals = playUrls
      .where((u) => u.startsWith('https://'))
      .toSet()
      .toList();
  String? donor;
  for (final url in originals) {
    if (!isAkamaiUrl(url)) {
      donor = url;
      break;
    }
  }
  final hosts = overseas ? ripperOverseasHosts : ripperMainlandHosts;
  final synthetic = <String>[];
  if (donor != null) {
    for (final host in hosts) {
      final swapped = swapHost(donor, host);
      if (swapped != null) synthetic.add(swapped);
    }
  }
  final allowedOriginals = originals.where((url) {
    final host = hostOf(url);
    final isMainland = ripperMainlandHosts.contains(host);
    return overseas ? !isMainland : isMainland;
  }).toList();
  return {...allowedOriginals, ...synthetic}.toList();
}

/// A node that twice returns zero bytes is skipped for the rest of the
/// current video. Reset when the video changes.
class CdnBanList {
  CdnBanList({this.limit = 2});

  final int limit;
  final Map<String, int> _strikes = {};
  final Set<String> _banned = {};

  /// Returns true when [url]'s host just got banned.
  bool record(String url, int receivedBytes, Object? error) {
    if (receivedBytes > 0) return false;
    final host = hostOf(url);
    if (host.isEmpty || _banned.contains(host)) return false;
    final count = (_strikes[host] ?? 0) + 1;
    _strikes[host] = count;
    if (count < limit) return false;
    _banned.add(host);
    return true;
  }

  bool allows(String url) => !_banned.contains(hostOf(url));

  List<String> get hosts => _banned.toList();

  void reset() {
    _strikes.clear();
    _banned.clear();
  }
}

class _HostHealth {
  _HostHealth({
    this.failures = 0,
    this.blockedUntilMs = 0,
    this.lastSuccessAtMs = 0,
    this.bps = 0,
  });

  int failures;
  int blockedUntilMs;
  int lastSuccessAtMs;
  double bps;
}

/// Health-aware router over one representation's candidate urls.
class CdnResolver {
  CdnResolver(List<String> urls, {this.banList})
    : _urls = urls.toSet().toList();

  final List<String> _urls;
  final CdnBanList? banList;
  final Map<String, _HostHealth> _health = {};
  int _cursor = 0;
  int _rangeCursor = 0;
  int _mediaRangeCount = 0;

  List<String> get all => List.unmodifiable(_urls);

  List<String> _unbanned(List<String> list) {
    final bans = banList;
    if (bans == null) return list;
    final allowed = list.where(bans.allows).toList();
    // Never leave the video with zero download addresses.
    return allowed.isNotEmpty ? allowed : list;
  }

  List<String> urls() => _unbanned(_urls);

  bool _blocked(String url, int nowMs) =>
      (_health[url]?.blockedUntilMs ?? 0) > nowMs;

  /// Round-robin ordered candidates for one piece.
  List<String> ordered([int pieceIndex = 0, Set<String>? exclude]) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final candidates = urls()
        .where((u) => exclude?.contains(u) != true)
        .toList();
    final available = candidates.where((u) => !_blocked(u, nowMs)).toList();
    final pool = available.isNotEmpty ? available : candidates;
    if (pool.isEmpty) return const [];
    final offset = (_cursor + pieceIndex) % pool.length;
    final rotated = [...pool.skip(offset), ...pool.take(offset)];
    _cursor = (_cursor + 1) % pool.length;
    return rotated;
  }

  /// Fast-lane candidates for the next media range: previously successful and
  /// high-throughput hosts first, rotating afterwards.
  List<String> rangeCandidates({required bool overseas}) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final pool = urls().where((u) => !_blocked(u, nowMs)).toList()
      ..sort((a, b) {
        final ah = _health[a];
        final bh = _health[b];
        final aOk = (ah?.lastSuccessAtMs ?? 0) > 0 ? 1 : 0;
        final bOk = (bh?.lastSuccessAtMs ?? 0) > 0 ? 1 : 0;
        if (aOk != bOk) return bOk - aOk;
        return (bh?.bps ?? 0).compareTo(ah?.bps ?? 0);
      });
    final effective = pool.isNotEmpty ? pool : urls();
    if (effective.isEmpty) return const [];
    final firstRange = _mediaRangeCount == 0;
    final width = firstRange
        ? effective.length
        : effective.length < 3
        ? effective.length
        : 3;
    List<String> selected;
    final warmup = overseas ? 4 : 1;
    if (_mediaRangeCount < warmup) {
      selected = effective.take(width).toList();
      _rangeCursor = width % effective.length;
    } else {
      final offset = _rangeCursor % effective.length;
      final rotated = [
        ...effective.skip(offset),
        ...effective.take(offset),
      ];
      selected = rotated.take(width).toList();
      _rangeCursor = (_rangeCursor + width) % effective.length;
    }
    _mediaRangeCount++;
    return selected;
  }

  List<String> startupCandidates() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final candidates = urls().where((u) => !_blocked(u, nowMs)).toList();
    return candidates.take(8).toList();
  }

  List<String> rescueCandidates() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final pool = urls().where((u) => !_blocked(u, nowMs)).toList()
      ..sort((a, b) {
        final ah = _health[a];
        final bh = _health[b];
        final aOk = (ah?.lastSuccessAtMs ?? 0) > 0 ? 1 : 0;
        final bOk = (bh?.lastSuccessAtMs ?? 0) > 0 ? 1 : 0;
        if (aOk != bOk) return bOk - aOk;
        return (bh?.bps ?? 0).compareTo(ah?.bps ?? 0);
      });
    return pool;
  }

  void success(String url, double bps) {
    final old = _health[url];
    _health[url] = _HostHealth(
      lastSuccessAtMs: DateTime.now().millisecondsSinceEpoch,
      bps: old == null || old.bps <= 0 ? bps : old.bps * 0.65 + bps * 0.35,
    );
  }

  void failure(String url, Object? error, [int receivedBytes = 0]) {
    banList?.record(url, receivedBytes, error);
    final old = _health[url];
    final failures = (old?.failures ?? 0) + 1;
    final shift = failures.clamp(0, 4).toInt();
    final backoffMs = 3000 * (1 << shift);
    _health[url] = _HostHealth(
      failures: failures,
      blockedUntilMs:
          DateTime.now().millisecondsSinceEpoch +
          (backoffMs < 60000 ? backoffMs : 60000),
      lastSuccessAtMs: old?.lastSuccessAtMs ?? 0,
      bps: old?.bps ?? 0,
    );
  }
}
