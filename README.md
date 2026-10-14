<div align="center">
    <img width="160" height="160" src="assets/images/logo/logo.png">
    <h1>PiliPlus 海外加速版</h1>
    <p>内置 <a href="https://github.com/MrTangLuyao/Bilibili-thread-ripper">B站线程撕裂者（BTR）</a>多线程下载的哔哩哔哩第三方客户端，解决海外看 B 站卡顿、加载慢。</p>
    <p>基于 <a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a>，自动跟进上游更新。</p>
</div>

## 相比原版多了什么

- **看视频更快**：视频会拆成多块，从多个服务器同时下载。在海外看冷门视频或高画质视频时，加载更快、卡顿更少。这个功能移植自 [B站线程撕裂者（Bilibili-thread-ripper）](https://github.com/MrTangLuyao/Bilibili-thread-ripper)，原理见 [docs/thread-ripper.md](docs/thread-ripper.md)。
- **装好就能用**：加速默认开启，默认使用海外节点，不用做任何设置。
- **番剧、电影也加速**：番剧、电影、纪录片等剧集同样走多线程下载；有数字版权保护或只能试看的剧集除外。直播不加速。

其余功能和原版 PiliPlus 一样，功能介绍和常见问题请看[原项目](https://github.com/bggRGjQaUbCoE/PiliPlus)。

### 相关设置

选项都在「设置 → 音视频设置」里，名字以「线程撕裂者」开头，改动在下次加载视频时生效：

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| 线程撕裂者 | 开 | 总开关，关闭后和原版一样直接下载 |
| 剧集加速 | 开 | 是否加速番剧、电影、纪录片等剧集 |
| 海外节点 | 开 | 适合在海外观看；人在大陆可以关闭，改用大陆节点 |
| 自动并发数（推荐） | 开 | 开播先用 16 线程，再根据卡顿和缓冲在 8–64 线程间自动调整 |
| 并发数 | 8 | 关闭自动并发数后使用，可选 4–128 |
| 自定义节点 | 空 | 填写后只使用这些节点 |

## 下载

到 [Releases](../../releases/latest) 下载：

| 设备 | 下载哪个文件 |
| --- | --- |
| 安卓手机、平板 | `app-arm64-v8a-release.apk`（绝大多数设备选这个） |
| 老旧安卓设备 | `app-armeabi-v7a-release.apk` |
| 安卓模拟器等 x86 设备 | `app-x86_64-release.apk` |
| iPhone、iPad | `PiliPlus-custom-ios-unsigned.ipa`（需要借助工具安装，见下文） |
| Windows 电脑 | `PiliPlus-custom-windows-x64-setup.exe`（安装版）<br>`PiliPlus-custom-windows-x64-portable.zip`（免安装版，解压就能用） |
| Mac 电脑 | `PiliPlus-custom-macos.dmg` |
| Linux 电脑 | `PiliPlus-custom-linux-amd64` 开头的文件，按发行版选 `.deb`、`.rpm`、`.AppImage` 或 `.tar.gz` |

## 安装

### 安卓

下载 apk 后直接安装。它和原版 PiliPlus 是两个独立的应用，可以同时装在一台设备上，数据互不相通。

如果设备上装的是 `2.1.6-fork.1248` 或更早的版本，新版换了签名，不能直接覆盖安装，需要先卸载旧版。卸载会清空数据，请先在旧版的「设置 → 关于」里导出登录信息和设置，装好新版后再导入；具体步骤写在每个 Release 的说明开头。

### iPhone / iPad

因为没有上架 App Store，iOS 版需要借助「自签工具」安装。下面几个任选一个：

- **[SideStore](https://sidestore.io)**（推荐）：装好以后，可以直接在手机上安装 ipa，还能在手机上自己续签。
- **[AltStore](https://altstore.io)**：用法和 SideStore 类似，但续签时需要电脑上的 AltServer 在同一个 Wi-Fi 里运行。

大致步骤（以 SideStore 为例）：

1. 按 SideStore 官网的教程把 SideStore 装到手机上（第一次需要用电脑，只要做一次）。
2. 用手机 Safari 下载 `PiliPlus-custom-ios-unsigned.ipa`。
3. 打开 SideStore →「My Apps」→ 点左上角的「+」，选刚下载的 ipa，等它装完。
4. 第一次打开时如果提示「不受信任的开发者」，到「设置 → 通用 → VPN 与设备管理」里信任你的 Apple ID。如果提示要打开「开发者模式」，按提示到「设置 → 隐私与安全性」里打开并重启手机。

更详细的教程可以咨询 AI 或去 B 站搜索「iOS 侧载」相关视频。

### Mac

打开 dmg，把 PiliPlus 拖进「应用程序」。第一次打开时会提示无法验证开发者，到「系统设置 → 隐私与安全性」，在页面下方点「仍要打开」。

## 更新

这里每天自动合并原版 PiliPlus 的更新，有变化就重新打包发布。版本号形如 `2.1.6.2-fork.5644`，前面是原版的版本号，后面的数字和应用「设置 → 关于」里 `+` 后面的数字相同，越大越新。

原版发布新版本后，应用里会弹出更新提示：安卓点「更新」会自动下载并安装，其他平台点「下载」后自行安装。也可以随时到 [Releases 页面](../../releases/latest) 下载最新版。

偶尔某个电脑平台打包失败，那一版会缺少它的安装包，用上一版或等下一版就行。安卓和 iOS 版不受影响。

## 反馈

加速相关的问题（卡顿、加载慢、某个视频放不了）请到这里的 [Issues](../../issues) 反馈。其他功能的问题大多和原版一致，可以先到[原项目](https://github.com/bggRGjQaUbCoE/PiliPlus)查找。

## 致谢与许可

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)：本项目的基础，采用 [GPL-3.0](LICENSE)，本项目与其相同。
- [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)：多线程下载的来源，基于 MIT 许可，见 [docs/licenses/bilibili-thread-ripper.txt](docs/licenses/bilibili-thread-ripper.txt)。
