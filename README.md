# SpatialPlayer

本地音视频播放器，使用 SwiftUI、AVKit 和 AVPlayer。普通双声道耳机可通过应用内的能力兼容层使用 Apple 原生空间音频播放路径。

**运行环境：Apple Silicon，macOS 27 或更新版本。当前验证版本为 macOS 27.0.1。** 首版为本机使用的 ad hoc 签名应用。

## 使用

双击本目录中的 `SpatialPlayer.app`。

- `⌘O` 打开一个或多个音视频文件，也可以把文件拖入窗口，或在 Finder 中选择用 SpatialPlayer 打开。
- 播放中加入文件只追加到列表；空列表加入文件后播放第一项。
- 双击列表条目或选中后按 Return 播放。右键可移除条目或在 Finder 中显示文件；列表菜单可清空列表。移除条目不会删除文件。
- 空格播放／暂停；`⌘←` / `⌘→` 切换上一项／下一项；`⌘⌥←` / `⌘⌥→` 后退／前进 10 秒。
- 视频支持全屏按钮、双击画面及 `⌃⌘F`。最后一项结束后停止；关闭窗口结束播放。
- 音量初始为 10%，会记住音量、空间音频模式与输出选择。
- 自动保存播放列表、当前曲目和播放位置；重新打开后恢复并保持暂停。增删与清空立即保存，播放中每 5 秒保存一次位置，暂停和退出时也会保存。只保存文件引用，不复制音视频文件；暂时不可用的文件仍保留在列表中。

### 输出和空间音频

输出菜单的“系统默认”跟随 macOS 当前输出；也可以单独指定本应用使用的设备。

| 模式 | 行为 |
|---|---|
| 自动（默认） | 原生兼容设备使用系统设置；明确识别出的普通双声道耳机启用兼容层；其他设备使用系统原生播放 |
| 强制耳机空间音频 | 普通双声道输出使用兼容层；原生兼容设备仍使用系统路径；超过两声道的输出保持原生播放 |
| 关闭 | 关闭兼容层，并禁止当前 AVPlayerItem 空间化 |

3.5 mm 耳机通过 `BuiltInHeadphoneOutputDevice` 识别；其他耳机参考音频流的 headphones terminal 类型。原生能力通过未被伪装的 CoreAudio 属性查询确认，不仅根据 Bluetooth／USB transport 推断。

切换输出或模式会重建播放链路并恢复进度与播放状态。输出设备离开设备列表或变为不可用时暂停，避免突然改用其他输出。

### 已知限制

- 使用系统 AVFoundation 支持的本地格式。没有 FFmpeg 回退、转码、网络播放、媒体库、均衡器或字幕管理。
- 本机测试的 16／24 声道 APAC 在明确关闭空间化时，原生 AVPlayer 返回 `fmt?` 格式错误。遇到此类 APAC 文件，应用会保留位置并提示切回自动／强制模式；不会暗中忽略“关闭”。
- `spen` / `spmd` 是私有实现细节，系统更新后需要重新验证。界面的模式表示应用播放策略，不等于控制中心已把设备识别成 AirPods。
- 普通耳机不因此获得头部跟踪或 AirPods 个性化配置。本应用没有安装虚拟驱动，也没有独立 PCM 中转或后台空间渲染器。
- 测试和当前可用硬件见 [验证记录](Tests/VALIDATION.md)。

## 构建

需要 Xcode 27 的命令行工具。先关闭正在运行的 SpatialPlayer，然后执行：

```sh
zsh build.sh
```

产物为项目根目录的 `SpatialPlayer.app`。脚本使用系统 `clang` / `swiftc`，复用系统模块缓存，不拉取第三方包、不创建 SwiftPM 依赖缓存，只保留一套应用产物。

`libSpatialShim.dylib` 放在应用的 `Contents/Frameworks` 中，通过 `@rpath` 正常链接，在启动期加载。双击启动不需要环境变量。签名顺序为动态库、应用；不开启 App Sandbox / Hardened Runtime，未进行商店发布或公证。

## 实现

- `PlayerModel` 管理单个 AVPlayer、播放列表、加载、定位及切换。generation 与 seek serial 拒绝旧异步回调；音频输出始终由 `audioOutputDeviceUniqueID` 指定。
- `AudioDeviceCatalog` 枚举输出，并监听设备列表、默认输出、存活状态和流配置。保存的是 UID，不是易变的 AudioObjectID。
- `SpatialShimSetConfiguration(deviceID, enabled)` 用单个原子状态设置目标，仅拦截该设备的 `AudioObjectHasProperty`、`AudioObjectGetPropertyDataSize`、`AudioObjectGetPropertyData`。原始能力查询从动态库内调用原始 API，避免把自己的伪装误认为硬件能力。
- 音频解码和空间渲染由 AVPlayer / MediaToolbox / AudioToolbox 完成，兼容层不处理音频样本。

## 诊断构建

```sh
zsh build.sh --diagnostics
```

诊断版增加只读 AudioQueue 属性记录及本地回归脚本入口，不修改队列参数或音频样本。详细用法见 [测试说明](Tests/README.md)。交付前重新运行不带参数的 `build.sh`，移除测试入口与队列诊断钩子。
