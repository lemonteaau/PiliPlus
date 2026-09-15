import 'package:PiliPlus/utils/update_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fork rebuilds and upstream commit suffixes do not change version', () {
    for (final name in ['2.1.4.lemontea+9999', 'v2.1.4-abcdef', '2.1.4']) {
      expect(UpdateVersion.releaseVersion(name), [2, 1, 4]);
      expect(
        UpdateVersion.isNewerVersion(UpdateVersion.releaseVersion(name)!, [
          2,
          1,
          4,
        ]),
        isFalse,
      );
    }
  });
  test('compares version components numerically and rejects downgrades', () {
    expect(UpdateVersion.isNewerVersion([2, 1, 10], [2, 1, 9]), isTrue);
    expect(UpdateVersion.isNewerVersion([3, 0, 0], [2, 99, 99]), isTrue);
    expect(UpdateVersion.isNewerVersion([2, 0, 99], [2, 1, 0]), isFalse);
    expect(UpdateVersion.releaseVersion('SNAPSHOT'), isNull);
  });
}
