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
    }.toList();
  }

  RipperCdnResolver(
    this.urls, {
    RipperBanList? bans,
    this.overseas = true,
    List<Uri>? originals,
  }) : bans = bans ?? RipperBanList(),
       originals = originals ?? urls;
  final RipperBanList bans;
  final List<Uri> urls;
  final List<Uri> originals;
  final bool overseas;
  final _health = <Uri, _Health>{};
  int _cursor = 0;
  int _rangeCount = 0;
  int _rangeCursor = 0;

  List<Uri> _unbanned(List<Uri> list) {
    final allowed = list.where(bans.allows).toList();
    return allowed.isEmpty ? list.toList() : allowed;
  }

  bool _available(Uri url) =>
      !(_health[url]?.blockedUntil.isAfter(DateTime.now()) ?? false);

  List<Uri> ordered([int pieceIndex = 0]) {
    final candidates = _unbanned(urls);
    final available = candidates.where(_available).toList();
    final pool = available.isEmpty ? candidates : available;
    if (pool.isEmpty) return pool;
    final offset = (_cursor + pieceIndex) % pool.length;
    _cursor = (_cursor + 1) % pool.length;
    return [...pool.skip(offset), ...pool.take(offset)];
  }

  List<Uri> rescueCandidates() =>
      _unbanned(urls).where(_available).toList()..sort((a, b) {
        final ah = _health[a];
        final bh = _health[b];
        final successful =
            (bh?.succeeded == true ? 1 : 0) - (ah?.succeeded == true ? 1 : 0);
        return successful != 0
            ? successful
            : (bh?.bps ?? 0).compareTo(ah?.bps ?? 0);
      });

  List<Uri> rangeCandidates() {
    final pool = rescueCandidates();
    if (pool.isEmpty) return _unbanned(urls);
    final width = _rangeCount == 0
        ? pool.length
        : (pool.length < 3 ? pool.length : 3);
    late List<Uri> selected;
    if (_rangeCount < (overseas ? 4 : 1)) {
      selected = pool.take(width).toList();
      _rangeCursor = width % pool.length;
    } else {
      final offset = _rangeCursor % pool.length;
      selected = [
        ...pool.skip(offset),
        ...pool.take(offset),
      ].take(width).toList();
      _rangeCursor = (_rangeCursor + width) % pool.length;
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
    final offset = preferred.isEmpty ? 0 : (index + round) % preferred.length;
    final rotated = [...preferred.skip(offset), ...preferred.take(offset)];
    final rescue = rescueCandidates()
        .where((u) => !rotated.contains(u))
        .toList();
    final result = <Uri>{};
    for (var i = 0; i < rotated.length || i < rescue.length; i++) {
      if (i < rotated.length) result.add(rotated[i]);
      if (i < rescue.length) result.add(rescue[i]);
    }
    result.addAll(ordered(index));
    return result.toList();
  }

  void success(Uri url, int bytes, Duration elapsed) {
    bans.success(url);
    final old = _health[url];
    final bps = bytes * 1000000 / (elapsed.inMicroseconds + 1);
    _health[url] = _Health(
      bps: old == null || old.bps == 0 ? bps : old.bps * .65 + bps * .35,
    )..succeeded = true;
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
  bool succeeded = false;
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
