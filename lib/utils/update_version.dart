/// Compare user-facing versions independently of fork build numbers.
abstract final class UpdateVersion {
  static List<int>? releaseVersion(String name) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(name);
    return match == null
        ? null
        : [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  }

  static bool isNewerVersion(List<int> latest, List<int> current) {
    for (var i = 0; i < 3; i++) {
      if (latest[i] != current[i]) return latest[i] > current[i];
    }
    return false;
  }
}
