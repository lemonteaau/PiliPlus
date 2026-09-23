import 'dart:io' show Directory, File, Platform;

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

abstract final class Update {
  static const _androidApkInstaller = MethodChannel(
    'com.example.piliplus/apk_installer',
  );

  // 检查更新
  static Future<void> checkUpdate([bool isAuto = true]) async {
    if (kDebugMode) return;
    SmartDialog.dismiss();
    try {
      final res = await Request().get(
        Api.latestApp,
        options: Options(
          headers: {'user-agent': BrowserUa.mob},
          extra: {'account': const NoAccount()},
        ),
      );
      if (res.data is Map || res.data.isEmpty) {
        if (!isAuto) {
          SmartDialog.showToast('检查更新失败，GitHub接口未返回数据，请检查网络');
        }
        return;
      }
      final data = res.data[0];
      final String releaseName =
          data['name'] is String && (data['name'] as String).isNotEmpty
          ? data['name']
          : '${data['tag_name']}';
      final int? latestBuildCode = int.tryParse(releaseName.split('+').last);
      final bool legacyIsLatest = latestBuildCode == null
          ? BuildConfig.buildTime >=
                DateTime.parse(data['created_at']).millisecondsSinceEpoch ~/
                    1000
          : BuildConfig.versionCode >= latestBuildCode;
      final String? currentUpstreamVersion = _leadingVersion(
        BuildConfig.versionName,
      );
      final String? latestUpstreamVersion = _releaseUpstreamVersion(
        data,
        releaseName,
      );
      final String? releaseCommit = data['target_commitish'] is String
          ? data['target_commitish'] as String
          : null;
      final bool hasCommitInfo =
          releaseCommit != null &&
          releaseCommit.isNotEmpty &&
          BuildConfig.commitHash != 'N/A';
      final bool isLatest;
      if (currentUpstreamVersion != null && latestUpstreamVersion != null) {
        final bool hasOfficialUpdate =
            currentUpstreamVersion != latestUpstreamVersion;
        isLatest = isAuto
            ? !hasOfficialUpdate
            : !hasOfficialUpdate &&
                  (!hasCommitInfo || releaseCommit == BuildConfig.commitHash);
      } else {
        isLatest = legacyIsLatest;
      }
      if (isLatest) {
        if (!isAuto) {
          SmartDialog.showToast('已是最新版本');
        }
      } else {
        SmartDialog.show(
          animationType: SmartAnimationType.centerFade_otherSlide,
          builder: (context) {
            final colorScheme = ColorScheme.of(context);
            Widget downloadBtn(String text, {String? ext}) => TextButton(
              onPressed: () => onDownload(data, ext: ext),
              child: Text(text),
            );
            return AlertDialog(
              title: const Text('🎉 发现新版本 '),
              content: SizedBox(
                height: 280,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        releaseName,
                        style: const TextStyle(fontSize: 20),
                      ),
                      const SizedBox(height: 8),
                      Text('${data['body']}'),
                      TextButton(
                        onPressed: () => PageUtils.launchURL(
                          '${Constants.sourceCodeUrl}/commits/main',
                        ),
                        child: Text(
                          "点此查看完整更新(即commit)内容",
                          style: TextStyle(color: colorScheme.primary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                if (isAuto)
                  TextButton(
                    onPressed: () {
                      SmartDialog.dismiss();
                      GStorage.setting.put(SettingBoxKey.autoUpdate, false);
                    },
                    child: Text(
                      '不再提醒',
                      style: TextStyle(color: colorScheme.outline),
                    ),
                  ),
                TextButton(
                  onPressed: SmartDialog.dismiss,
                  child: Text(
                    '取消',
                    style: TextStyle(color: colorScheme.outline),
                  ),
                ),
                if (Platform.isWindows) ...[
                  downloadBtn('zip', ext: 'zip'),
                  downloadBtn('exe', ext: 'exe'),
                ] else if (Platform.isLinux) ...[
                  downloadBtn('rpm', ext: 'rpm'),
                  downloadBtn('deb', ext: 'deb'),
                  downloadBtn('targz', ext: 'tar.gz'),
                ] else
                  downloadBtn('Github'),
              ],
            );
          },
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('failed to check update: $e');
    }
  }

  static String? _leadingVersion(String value) =>
      RegExp(r'^(\d+\.\d+\.\d+)').firstMatch(value.trim())?.group(1);

  static String? _releaseUpstreamVersion(Map data, String releaseName) {
    final String tag = data['tag_name'] is String
        ? data['tag_name'] as String
        : '';
    final forkTagMatch = RegExp(
      r'^v?(\d+\.\d+\.\d+)-fork\.\d+$',
    ).firstMatch(tag);
    if (forkTagMatch != null) return forkTagMatch.group(1);

    final String body = data['body'] is String ? data['body'] as String : '';
    final upstreamNoteMatch = RegExp(
      r'based on upstream release\s+v?(\d+\.\d+\.\d+)',
      caseSensitive: false,
    ).firstMatch(body);
    if (upstreamNoteMatch != null) return upstreamNoteMatch.group(1);

    return _leadingVersion(releaseName);
  }

  // 下载适用于当前系统的安装包
  static Future<void> onDownload(Map data, {String? ext}) async {
    SmartDialog.dismiss();
    try {
      Future<void> download(String plat) async {
        if (data['assets'].isNotEmpty) {
          for (Map<String, dynamic> i in data['assets']) {
            final String name = i['name'];
            if (name.contains(plat) &&
                (ext == null || ext.isEmpty ? true : name.endsWith(ext))) {
              final url = i['browser_download_url'] as String;
              if (Platform.isAndroid && name.toLowerCase().endsWith('.apk')) {
                await _downloadAndInstallAndroidApk(url);
              } else {
                await PageUtils.launchURL(url);
              }
              return;
            }
          }
          throw UnsupportedError('platform not found: $plat');
        }
      }

      if (Platform.isAndroid) {
        // 获取设备信息
        AndroidDeviceInfo androidInfo = await DeviceInfoPlugin().androidInfo;
        // [arm64-v8a]
        await download(androidInfo.supportedAbis.first);
      } else {
        await download(Platform.operatingSystem);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('download error: $e');
      PageUtils.launchURL('${Constants.sourceCodeUrl}/releases/latest');
    }
  }

  static Future<void> _downloadAndInstallAndroidApk(String url) async {
    File? apkFile;
    try {
      final tempDirectory = await getTemporaryDirectory();
      final updateDirectory = Directory(
        p.join(tempDirectory.path, 'apk_updates'),
      );
      if (await updateDirectory.exists()) {
        await updateDirectory.delete(recursive: true);
      }
      await updateDirectory.create(recursive: true);
      apkFile = File(p.join(updateDirectory.path, 'update.apk'));

      SmartDialog.showLoading(msg: '正在下载更新');
      await Request.dio.download(url, apkFile.path, deleteOnError: true);
      if (await apkFile.length() < 4) {
        throw const FormatException('下载的 APK 文件无效');
      }

      SmartDialog.dismiss();
      await _androidApkInstaller.invokeMethod<void>('installApk', {
        'path': apkFile.path,
      });
    } catch (e) {
      SmartDialog.dismiss();
      if (apkFile != null && await apkFile.exists()) {
        await apkFile.delete();
      }
      if (kDebugMode) debugPrint('APK update failed: $e');
      SmartDialog.showToast('APK 下载或安装失败');
    }
  }
}
