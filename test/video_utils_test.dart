import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mirrorUrl =
      'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/2/video.m4s?foo=bar';
  const mcdnUrl =
      'https://1.2.3.4:8443/upgcxcode/1/2/video.m4s?os=mcdn&sign=abc%2Bdef';

  setUp(() => VideoUtils.disableAudioCDN = true);
  tearDown(() => VideoUtils.disableAudioCDN = false);

  test('uses the original mirror URL for the backup CDN', () {
    expect(
      VideoUtils.getCdnUrl(
        [mcdnUrl, mirrorUrl],
        defaultCDNService: CDNService.backupUrl,
      ),
      mirrorUrl,
    );
  });

  test('switches a supported mirror URL to the selected CDN', () {
    expect(
      VideoUtils.getCdnUrl(
        [mirrorUrl],
        defaultCDNService: CDNService.ali,
      ),
      'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/video.m4s?foo=bar',
    );
  });

  test('replaces P2P host and port without changing its signed query', () {
    expect(
      VideoUtils.getCdnUrl(
        [mcdnUrl],
        defaultCDNService: CDNService.ali,
      ),
      'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/video.m4s?os=mcdn&sign=abc%2Bdef',
    );
  });

  test('upgrades an HTTP P2P fallback before replacing its host and port', () {
    expect(
      VideoUtils.getCdnUrl(
        [mcdnUrl.replaceFirst('https://', 'http://')],
        defaultCDNService: CDNService.ali,
      ),
      'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/video.m4s?os=mcdn&sign=abc%2Bdef',
    );
  });

  test(
    'audio CDN bypass keeps normal mirrors and safely handles P2P fallbacks',
    () {
      expect(
        VideoUtils.getCdnUrl(
          [mcdnUrl, mirrorUrl],
          defaultCDNService: CDNService.cos,
          isAudio: true,
        ),
        mirrorUrl,
      );
      expect(
        VideoUtils.getCdnUrl(
          [mcdnUrl],
          defaultCDNService: CDNService.cos,
          isAudio: true,
        ),
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/video.m4s?os=mcdn&sign=abc%2Bdef',
      );
    },
  );
}
