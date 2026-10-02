<div align="center">
    <img width="160" height="160" src="assets/images/logo/logo.png">
    <h1>PiliPlus（个人分支）</h1>
    <p>基于 <a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a> 的哔哩哔哩第三方客户端，自动跟进上游更新。</p>
</div>

## 和上游的区别

- **线程撕裂者下载加速**：视频和音频拆成多块，从多个 CDN 节点同时下载，海外看冷门或高码率视频更流畅。移植自 [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)，说明见 [docs/thread-ripper.md](docs/thread-ripper.md)。
- 在「设置 → 音视频设置」里可以关闭，或改节点地区、并发数。

其余功能和上游一致，使用说明请看[上游项目](https://github.com/bggRGjQaUbCoE/PiliPlus)。

## 下载

到 [Releases](../../releases) 下载：

- Android：一般手机选 `app-arm64-v8a-release.apk`
- iOS：`PiliPlus-custom-ios-unsigned.ipa`，未签名，需要自己签名安装
- Windows：安装版 `PiliPlus-custom-windows-x64-setup.exe`，免安装版 `PiliPlus-custom-windows-x64-portable.zip`
- macOS：`PiliPlus-custom-macos.dmg`，未签名，第一次打开要在「系统设置 → 隐私与安全性」里允许
- Linux：`PiliPlus-custom-linux-amd64` 开头的 `.deb`、`.rpm`、`.AppImage` 或 `.tar.gz`

桌面版和上游使用同一个应用身份，会覆盖已经安装的上游桌面版，并沿用它的登录和设置。某个桌面平台构建失败时，那次发布会缺少它的安装包，Android 和 iOS 照常发布。

上游每次更新后会自动合并并重新构建，版本号形如 `2.1.5-fork.1182`。

## 许可

与上游相同，采用 [GPL-3.0](LICENSE)。线程撕裂者部分基于 MIT 许可，见 [docs/licenses/bilibili-thread-ripper.txt](docs/licenses/bilibili-thread-ripper.txt)。
