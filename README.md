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

上游每次更新后会自动合并并重新构建，版本号形如 `2.1.5-fork.1182`。

## 许可

与上游相同，采用 [GPL-3.0](LICENSE)。线程撕裂者部分基于 MIT 许可，见 [docs/licenses/bilibili-thread-ripper.txt](docs/licenses/bilibili-thread-ripper.txt)。
