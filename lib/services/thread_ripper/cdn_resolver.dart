// Adapted from Bilibili-thread-ripper 0.9.1.4, MIT.
// See docs/thread-ripper.md and docs/licenses/bilibili-thread-ripper.txt.

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

  static List<Uri> candidates(Iterable<String> urls, {required bool overseas}) {
    final originals = urls.map(Uri.parse).where(supports).toSet().toList();
    final donors = originals.where((u) => !u.host.endsWith('.akamaized.net'));
    final hosts = overseas ? overseasHosts : mainlandHosts;
    return {
      ...originals.where(
        (u) => overseas
            ? !mainlandHosts.contains(u.host)
            : mainlandHosts.contains(u.host),
      ),
      for (final host in hosts)
        for (final donor in donors.isEmpty ? originals : donors.take(1))
          donor.replace(host: host, port: 443),
      // Keep the signed API addresses as a last resort in either region.
      ...originals,
    }.toList();
  }

  RipperCdnResolver(this.urls, {RipperBanList? bans})
    : bans = bans ?? RipperBanList();
  final RipperBanList bans;
  final List<Uri> urls;
  final _health = <Uri, _Health>{};
  int _cursor = 0;

  List<Uri> ordered() {
    final now = DateTime.now();
    final allowed = urls.where(bans.allows).toList();
    final candidates = allowed.isEmpty ? urls : allowed;
    final available = candidates.where((u) {
      final health = _health[u];
      return health == null || !health.blockedUntil.isAfter(now);
    }).toList();
    final pool = (available.isEmpty ? candidates.toList() : available)
      ..sort((a, b) => (_health[b]?.bps ?? 0).compareTo(_health[a]?.bps ?? 0));
    if (pool.isEmpty) return pool;
    // Explore nodes while keeping the fastest healthy nodes in each rotation.
    final offset = _cursor++ % pool.length;
    return [...pool.skip(offset), ...pool.take(offset)];
  }

  void success(Uri url, int bytes, Duration elapsed) {
    bans.success(url);
    final old = _health[url];
    final bps = bytes * 1000000 / (elapsed.inMicroseconds + 1);
    _health[url] = _Health(
      bps: old == null ? bps : old.bps * .65 + bps * .35,
    );
  }

  void failure(Uri url, {int status = 0, int received = 0}) {
    bans.failure(url, status: status, received: received);
    final old = _health.putIfAbsent(url, _Health.new);
    old.failures++;
    old.blockedUntil = DateTime.now().add(
      Duration(milliseconds: 3000 * (1 << old.failures.clamp(1, 4))),
    );
  }
}

class _Health {
  _Health({this.bps = 0});
  double bps;
  int failures = 0;
  DateTime blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
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
