<div align="center">
    <img width="160" height="160" src="assets/images/logo/logo.png">
    <h1>PiliPlus（个人分支）</h1>
    <p>基于 <a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a> 的哔哩哔哩第三方客户端，自动跟进上游更新。</p>
</div>

## 与原版的区别

- **看视频更快**：视频会拆成多块，从多个服务器同时下载。在海外看冷门视频或高画质视频时，加载更快、卡顿更少。这个功能移植自 [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)，原理见 [docs/thread-ripper.md](docs/thread-ripper.md)。
- 默认已经开启，不用设置。相关选项在「设置 → 音视频设置」里，名字都以「线程撕裂者」开头：人在海外可以打开「线程撕裂者：海外节点」。

其余功能和原版 PiliPlus 一样，功能介绍和常见问题请看[原项目](https://github.com/bggRGjQaUbCoE/PiliPlus)。

## 下载

到 [Releases](../../releases) 下载：

| 设备 | 下载哪个文件 |
| --- | --- |
| 安卓手机、平板 | `app-arm64-v8a-release.apk`（绝大多数设备选这个） |
| 老旧安卓设备 |  `app-armeabi-v7a-release.apk` |
| iPhone、iPad | `PiliPlus-custom-ios-unsigned.ipa`（需要借助工具安装，见下文） |
| Windows 电脑 | `PiliPlus-custom-windows-x64-setup.exe`（安装版）<br>`PiliPlus-custom-windows-x64-portable.zip`（免安装版，解压就能用） |
| Mac 电脑 | `PiliPlus-custom-macos.dmg` |
| Linux 电脑 | `PiliPlus-custom-linux-amd64` 开头的文件，按发行版选 `.deb`、`.rpm` 或 `.AppImage` |


## 安装

### iPhone / iPad

因为没有上架 App Store，iOS 版需要借助「自签工具」安装。下面几个任选一个：

- **[SideStore](https://sidestore.io)**（推荐）：装好以后，可以直接在手机上安装 ipa，还能在手机上自己续签。
- **[AltStore](https://altstore.io)**：用法和 SideStore 类似，但续签时需要电脑上的 AltServer 在同一个 Wi-Fi 里运行。

大致步骤（以 SideStore 为例）：

1. 按 SideStore 官网的教程把 SideStore 装到手机上（第一次需要用电脑，只要做一次）。
2. 用手机 Safari 下载 `PiliPlus-custom-ios-unsigned.ipa`。
3. 打开 SideStore →「My Apps」→ 点左上角的「+」，选刚下载的 ipa，等它装完。
4. 第一次打开时如果提示「不受信任的开发者」，到「设置 → 通用 → VPN 与设备管理」里信任你的 Apple ID。如果提示要打开「开发者模式」，按提示到「设置 → 隐私与安全性」里打开并重启手机。

更详细的教程可以咨询AI或去B站搜索“iOS侧载”相关视频。

### Mac

打开 dmg，把 PiliPlus 拖进「应用程序」。第一次打开时会提示无法验证开发者，到「系统设置 → 隐私与安全性」，在页面下方点「仍要打开」。


## 更新

原版 PiliPlus 每次更新后，这里会自动合并并重新打包，版本号形如 `2.1.6-fork.1245`，前面是原版的版本号，后面是这里的构建次数。想更新时回到 [Releases 页面](../../releases/latest) 下载最新版即可。

偶尔某个电脑平台打包失败，那一版会缺少它的安装包，用上一版或等下一版就行。安卓和 iOS 版不受影响。

## 许可

与原项目相同，采用 [GPL-3.0](LICENSE)。线程撕裂者部分基于 MIT 许可，见 [docs/licenses/bilibili-thread-ripper.txt](docs/licenses/bilibili-thread-ripper.txt)。
