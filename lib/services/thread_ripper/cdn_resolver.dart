// Adapted from Bilibili-thread-ripper 0.9.4.2, MIT.
// See docs/thread-ripper.md and docs/licenses/bilibili-thread-ripper.txt.
import 'dart:math';

class RipperCdnResolver {
  static const mainlandHosts = [
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirrorhw.bilivideo.com',
    'upos-sz-mirrorbos.bilivideo.com',
    'upos-sz-mirror08c.bilivideo.com',
    'upos-sz-mirrorbd.bilivideo.com',
    'upos-sz-mirror14b.bilivideo.com',
    'upos-sz-estgoss.bilivideo.com',
    'upos-sz-mirrorcos.bilivideo.com',
  ];
  static const overseasHosts = [
    'upos-sz-mirrorcosov.bilivideo.com',
    'upos-sz-mirroraliov.bilivideo.com',
    'cn-hk-eq-01-01.bilivideo.com',
    'cn-hk-eq-01-03.bilivideo.com',
  ];
  static final _hosts = RegExp(
    r'(^|\.)(bilivideo\.(com|cn|net)|akamaized\.net|szbdyd\.com|hdslb\.com|xycdn\.com|mountaintoys\.cn|nexusedgeio\.com|ahdohpiechei\.com)$',
  );
  static bool supports(Uri uri) =>
      uri.scheme == 'https' &&
      _hosts.hasMatch(uri.host) &&
      RegExp(r'\.(m4s|mp4|flv)$', caseSensitive: false).hasMatch(uri.path);

  static String? normalizeHost(String value) {
    final text = value.trim().toLowerCase();
    if (text.isEmpty || text.length > 253) return null;
    final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    final host = uri?.host ?? '';
    return RegExp(
              r'^[a-z\d](?:[a-z\d-]*[a-z\d])?(?:\.[a-z\d](?:[a-z\d-]*[a-z\d])?)+$',
            ).hasMatch(host) &&
            _hosts.hasMatch(host)
        ? host
        : null;
  }

  static List<Uri> candidates(
    Iterable<String> urls, {
    required bool overseas,
    List<String> customHosts = const [],
  }) {
    final originals = urls.map(Uri.parse).where(supports).toSet().toList();
    final donors = originals.where((u) => !u.host.endsWith('.akamaized.net'));
    final custom = customHosts
        .map(normalizeHost)
        .whereType<String>()
        .toSet()
        .take(32)
        .toList();
    final hosts = custom.isNotEmpty
        ? custom
        : overseas
        ? overseasHosts
        : mainlandHosts;
    return {
      ...originals.where(
        (u) => custom.isNotEmpty
            ? custom.contains(u.host)
            : overseas
            ? !mainlandHosts.contains(u.host)
            : mainlandHosts.contains(u.host),
      ),
      for (final host in hosts)
        for (final donor in donors.isEmpty ? originals : donors.take(1))
          donor.replace(host: host, port: 443),
    }.toList();
  }

  RipperCdnResolver(
    this.urls, {
    RipperBanList? bans,
    this.overseas = true,
    List<Uri>? originals,
    DateTime Function()? now,
  }) : bans = bans ?? RipperBanList(),
       now = now ?? DateTime.now,
       originals = originals ?? urls;
  final DateTime Function() now;
  final RipperBanList bans;
  final List<Uri> urls;
  final List<Uri> originals;
  final bool overseas;
  final _health = <Uri, _Health>{};
  final _routes = <String, _Measurement>{};
  static String _route(Uri url) => '${url.authority}${url.path}';
  double speed(Uri url) {
    final measurement = _routes[_route(url)];
    return measurement?.measuredAt != null &&
            now().difference(measurement!.measuredAt!) <
                const Duration(seconds: 90)
        ? measurement.bps
        : 0;
  }

  int _cursor = 0;
  int _rangeCount = 0;
  int _rangeCursor = 0;

  List<Uri> _unbanned(List<Uri> list) {
    final allowed = list.where(bans.allows).toList();
    return allowed.isEmpty ? list.toList() : allowed;
  }

  bool _available(Uri url) =>
      !(_health[url]?.blockedUntil.isAfter(now()) ?? false);

  List<Uri> ordered([int pieceIndex = 0]) {
    final candidates = _unbanned(urls);
    final available = candidates.where(_available).toList();
    final pool = available.isEmpty ? candidates : available;
    if (pool.isEmpty) return pool;
    final offset = (_cursor + pieceIndex) % pool.length;
    _cursor = (_cursor + 1) % pool.length;
    return [...pool.skip(offset), ...pool.take(offset)];
  }

  List<Uri> rescueCandidates() => _unbanned(urls).where(_available).toList()
    ..sort((a, b) {
      final ah = _routes[_route(a)];
      final bh = _routes[_route(b)];
      final successful =
          (bh?.succeeded == true ? 1 : 0) - (ah?.succeeded == true ? 1 : 0);
      if (successful != 0) return successful;
      final bySpeed = (bh?.bps ?? 0).compareTo(ah?.bps ?? 0);
      return bySpeed != 0
          ? bySpeed
          : urls.indexOf(a).compareTo(urls.indexOf(b));
    });

  List<Uri> rangeCandidates() {
    final pool = rescueCandidates();
    if (pool.isEmpty) return _unbanned(urls);
    final width = _rangeCount == 0 ? pool.length : min(pool.length, 6);
    late List<Uri> selected;
    if (_rangeCount < (overseas ? 4 : 1)) {
      selected = pool.take(width).toList();
      _rangeCursor = width % pool.length;
    } else {
      final measured = pool.where((u) => speed(u) > 0).toList();
      final rest = pool.where((u) => speed(u) == 0).toList();
      final places = min(rest.length, max(1, width - measured.length));
      final explore = List.generate(
        places,
        (i) => rest[(_rangeCursor + i) % rest.length],
      );
      _rangeCursor = (_rangeCursor + places) % pool.length;
      selected = [...measured.take(width - explore.length), ...explore];
      for (final url in pool) {
        if (selected.length >= min(3, pool.length)) break;
        if (!selected.contains(url)) selected.add(url);
      }
    }
    _rangeCount++;
    return selected;
  }

  List<Uri> startupCandidates() =>
      _unbanned({...originals, ...urls}.toList())
          .where(_available)
          .take(8)
          .toList();

  List<Uri> pieceCandidates(List<Uri> preferred, int index, int round) {
    final offset = preferred.isEmpty ? 0 : round % preferred.length;
    final rotated = [...preferred.skip(offset), ...preferred.take(offset)];
    final rescue = rescueCandidates()
        .where((u) => !rotated.contains(u))
        .toList();
    final rest = [...rotated.skip(1), ...rescue];
    // Dart's sort is not stable; preserve upstream JS tie order explicitly.
    final positions = {for (var i = 0; i < rest.length; i++) rest[i]: i};
    rest.sort((a, b) {
      final bySpeed = speed(b).compareTo(speed(a));
      return bySpeed != 0 ? bySpeed : positions[a]!.compareTo(positions[b]!);
    });
    final result = <Uri>{if (rotated.isNotEmpty) rotated.first, ...rest}
      ..addAll(ordered(index));
    return result.toList();
  }

  void success(Uri url, int bytes, Duration elapsed) {
    recordSuccess(
      url,
      bytes >= 48 * 1024 ? bytes * 1000000 / max(1, elapsed.inMicroseconds) : 0,
    );
  }

  void recordSuccess(Uri url, double bps) {
    bans.success(url);
    _health[url] = _Health();
    _routes.putIfAbsent(_route(url), _Measurement.new).succeeded = true;
    sample(url, bps);
  }

  void sample(Uri url, double bps) {
    if (bps <= 0) return;
    final route = _routes.putIfAbsent(_route(url), _Measurement.new);
    route.bps = route.bps == 0 ? bps : route.bps * .65 + bps * .35;
    route.measuredAt = now();
  }

  void failure(Uri url, {int status = 0, int received = 0}) {
    bans.failure(url, status: status, received: received);
    final old = _health.putIfAbsent(url, _Health.new);
    old.failures++;
    old.blockedUntil = now().add(
      Duration(milliseconds: 3000 * (1 << old.failures.clamp(1, 4))),
    );
  }
}

class _Health {
  int failures = 0;
  DateTime blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
}

class _Measurement {
  double bps = 0;
  bool succeeded = false;
  DateTime? measuredAt;
}

/// Upstream smooth weighted round-robin, with per-track exploration slots.
class RipperAssignments {
  int _turn = 0;
  final _trials = Expando<_Trials>();

  List<Uri> assign(List<Uri> urls, RipperCdnResolver resolver, int count) {
    if (urls.isEmpty || count <= 0) return [];
    if (urls.length == 1) return List.filled(count, urls.first);
    final turn = _turn;
    _turn = (_turn + 1) % 4096;
    final top = urls.map(resolver.speed).reduce(max);
    if (top == 0) {
      return List.generate(count, (i) => urls[(i + turn) % urls.length]);
    }
    urls = urls
        .where((u) => resolver.speed(u) == 0 || resolver.speed(u) >= top / 12)
        .toList();
    final unknown = urls.where((u) => resolver.speed(u) == 0).toList();
    var trials = min(unknown.length * 2, count ~/ 4);
    final state = _trials[resolver] ??= _Trials();
    if (trials == 0 && unknown.isNotEmpty && count >= 2) {
      if (++state.waited >= 4) trials = 1;
    }
    if (trials > 0) state.waited = 0;
    urls = urls.where((u) => resolver.speed(u) > 0).toList();
    final weights = urls.map((u) => max(resolver.speed(u), top * .05)).toList();
    final total = weights.reduce((a, b) => a + b);
    final credit = List.filled(urls.length, 0.0);
    final order = List.generate(urls.length, (i) => (i + turn) % urls.length);
    final result = <Uri>[];
    for (var i = 0; i < count - trials; i++) {
      var best = order.first;
      for (final index in order) {
        credit[index] += weights[index];
        if (credit[index] > credit[best]) best = index;
      }
      credit[best] -= total;
      result.add(urls[best]);
    }
    for (var i = 0; i < trials; i++) {
      result.add(unknown[(i + state.cursor) % unknown.length]);
    }
    state.cursor = (state.cursor + trials) % 4096;
    return result;
  }
}

class _Trials {
  int waited = 0;
  int cursor = 0;
}

/// Upstream's per-video empty-response policy distinguishes a refused signed
/// address from a broken node using successful deliveries on both sides.
class RipperBanList {
  final _emptyReplies = <(String, String, bool), int>{};
  final _goodNodes = <String>{};
  final _goodAddresses = <String>{};
  Set<String> _banned = {};

  static String _address(Uri url) => '${url.path}?${url.query}';

  void failure(Uri url, {int status = 0, int received = 0}) {
    if (received > 0) return;
    final key = (url.host, _address(url), status >= 400 && status < 500);
    _emptyReplies.update(key, (value) => value + 1, ifAbsent: () => 1);
    _judge();
  }

  void success(Uri url) {
    _goodNodes.add(url.host);
    _goodAddresses.add(_address(url));
    _judge();
  }

  void _judge() {
    final strikes = <String, int>{};
    for (final entry in _emptyReplies.entries) {
      final (node, address, refused) = entry.key;
      final String key;
      if (!refused) {
        key = 'node:$node';
      } else if (_goodNodes.contains(node)) {
        key = _goodAddresses.contains(address)
            ? 'pair:$node $address'
            : 'address:$address';
      } else if (_goodAddresses.contains(address)) {
        key = 'node:$node';
      } else {
        continue;
      }
      strikes.update(
        key,
        (value) => value + entry.value,
        ifAbsent: () => entry.value,
      );
    }
    _banned = strikes.entries
        .where((e) => e.value >= 2)
        .map((e) => e.key)
        .toSet();
  }

  bool allows(Uri url) =>
      !_banned.contains('node:${url.host}') &&
      !_banned.contains('address:${_address(url)}') &&
      !_banned.contains('pair:${url.host} ${_address(url)}');
}
