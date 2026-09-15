import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/update_version.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

abstract final class Update {
  static bool _downloading = false;

  static Future<void> downloadApk(Map<String, dynamic> asset) async {
    if (_downloading) return;
    _downloading = true;
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    File? partial;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      await dir.create(recursive: true);
      partial = File('${dir.path}/update.apk.part');
      SmartDialog.showLoading(msg: '正在下载更新…');
      await dio.download(asset['browser_download_url'], partial.path);
      final expectedSize = asset['size'];
      if (expectedSize is! int || await partial.length() != expectedSize) {
        throw const FormatException('安装包下载不完整');
      }
      final apk = await partial.rename('${dir.path}/update.apk');
      await const MethodChannel(
        'piliplus/update',
      ).invokeMethod('install', apk.path);
    } finally {
      dio.close();
      try {
        if (partial != null && partial.existsSync()) await partial.delete();
      } finally {
        SmartDialog.dismiss(status: SmartStatus.loading);
        _downloading = false;
      }
    }
  }

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
      final latestVersion = UpdateVersion.releaseVersion(releaseName);
      final currentVersion = UpdateVersion.releaseVersion(
        BuildConfig.versionName,
      );
      if (latestVersion == null || currentVersion == null) {
        if (!isAuto) SmartDialog.showToast('无法识别版本号');
        return;
      }
      final bool isLatest = !UpdateVersion.isNewerVersion(
        latestVersion,
        currentVersion,
      );
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
                      Text(releaseName, style: const TextStyle(fontSize: 20)),
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
                  downloadBtn(Platform.isAndroid ? '下载并安装' : 'Github'),
              ],
            );
          },
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('failed to check update: $e');
    }
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
              if (Platform.isAndroid) {
                await downloadApk(i);
              } else {
                PageUtils.launchURL(i['browser_download_url']);
              }
              return;
            }
          }
        }
        throw UnsupportedError('platform not found: $plat');
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
      if (Platform.isAndroid) {
        SmartDialog.showToast('更新失败：$e');
      } else {
        PageUtils.launchURL('${Constants.sourceCodeUrl}/releases/latest');
      }
    }
  }
}
