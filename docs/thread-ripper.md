# 线程撕裂者下载层

从 Bilibili-thread-ripper **0.9.1.4**（上游提交
`517db0dc0ed54d3f95d1fa842cb6b3a5c14584f6`）重新实现原生下载适配：
https://github.com/MrTangLuyao/Bilibili-thread-ripper

参考 `src/range-core.js`、`src/cdn-resolver.js`、`src/idm-downloader.js`。
MIT 版权声明见 [许可证](licenses/bilibili-thread-ripper.txt)。

保留 PiliPlus 的 media_kit/mpv 播放器、解码、弹幕、字幕、画质、音轨、倍速、
后台播放与进度控制。浏览器 userscript 的页面注入和 MSE 接管不适用于原生应用；
这里通过只监听 127.0.0.1、带随机会话路径的 HTTP Range 代理接入同样的下载方式。
不运行旧版本替换播放器的代码。

- 默认开启，默认海外节点、8 个并发连接。播放设置可关闭、改地区或改并发数；下次加载生效。
- DASH 音视频共享连接预算，64 KiB 分块并发下载、按文件顺序输出。每个响应窗口最多
  `并发数 × 64 KiB`，不将整个视频装进内存，也不持久缓存签名地址。
- 900 ms 后对慢块启动备用副本，先通过校验者胜出并取消另一副本。首响应超时 5.5 秒，
  流停滞超时 4 秒，单次尝试最长 15 秒，最多三轮节点重试。
- 严格校验 HTTP 206、Content-Range、分块实际长度和跨节点资源总长度；拒绝 200、
  错区间、截断、超长响应。错误不会作为媒体数据交给播放器。
- 使用上游的大陆/海外节点名单、签名路径保留、Akamai-only 地址合成、失败节点退避及每视频封禁（区分节点、地址与节点/地址组合）。
  原始 API 地址保留为最终候选。原生适配不依赖浏览器的 SIDX/MSE 分段调度，mpv
  直接决定读取区间，下载层用有界窗口实现背压。
- 拖动断开 HTTP 请求会取消该请求的下载；更换播放源或关闭播放器会取消整个代理会话。
- 本地文件、直播、非 DASH 视频继续走原生直连。启动代理失败时使用原始播放地址；
  下载耗尽重试时返回 HTTP 错误，由播放器现有错误/重试处理接管。
- 原有卡顿定时器、画面冻结检测、自动修改 CDN 设置、重载和撤销提示均已删除。
  手动 CDN 选择和置顶仍保留，线程撕裂者启用时独立选择 DASH 下载节点。

回归测试：`flutter test test/thread_ripper_test.dart test/video_utils_test.dart`。
测试使用本地 HTTP 服务模拟正常、慢、拒绝、错误 Range、截断、资源大小变化和取消。
