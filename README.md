# SpatialUnlock Player

本地音视频播放器，使用 SwiftUI、AVKit 和 AVPlayer。普通双声道耳机可通过应用内的能力兼容层使用 Apple 原生空间音频播放路径。

**运行环境：Apple Silicon，macOS 27 或更新版本。当前验证版本为 macOS 27.0.1。** 首版为本机使用的 ad hoc 签名应用。

## 使用

双击本目录中的 `SpatialUnlock Player.app`。

- `⌘O` 打开一个或多个音视频文件，也可以把文件拖入窗口，或在 Finder 中选择用 SpatialUnlock Player 打开。
- 侧栏可新建、重命名、删除和切换命名播放列表。切换列表用于浏览和管理，双击条目或选中后按 Return 才切换播放；点击“正在播放：列表名”可返回当前播放列表。
- 打开或拖入文件会加入当时浏览的列表；已有当前曲目时只追加，没有当前曲目且向空列表加入文件时播放第一项。
- 双击列表条目或选中后按 Return 播放。右键可移除条目或在 Finder 中显示文件；列表菜单可清空列表。移除条目不会删除文件。
- 空格播放／暂停；`⌘←` / `⌘→` 切换上一项／下一项；`⌘⌥←` / `⌘⌥→` 后退／前进 10 秒。
- 底部播放模式菜单及菜单栏“播放”支持顺序播放、列表循环、单曲循环和随机播放，所有列表共用并记住模式。顺序播放在最后一项结束后停止；单曲循环只影响自动续播，手动仍可切歌。
- 随机播放每轮打乱全部条目；有多项时避免相邻两轮连续播放同一项。上一项回到实际播放历史，回退后的下一项先沿历史前进。同一个文件的多个条目分别参与随机播放。
- 上一项／下一项和自动续播始终跟随正在播放的列表。删除或清空该列表会停止播放；删除列表和条目均不会删除媒体文件。
- 视频支持全屏按钮、双击画面及 `⌃⌘F`；关闭窗口结束播放。
- 音量初始为 10%，会记住音量、空间音频模式与输出选择。
- 自动保存全部列表（包括空列表）、正在浏览和播放的列表、当前曲目和播放位置；重新打开后恢复并保持暂停。原有单列表会自动迁移为“默认列表”。列表变更立即保存，播放中每 5 秒保存一次位置，暂停和退出时也会保存。只保存文件引用，不复制音视频文件；暂时不可用的文件仍保留在列表中。随机顺序和播放历史仅在本次运行内保留，重新打开时从恢复的曲目建立新一轮。

### 输出和空间音频

输出菜单的“系统默认”跟随 macOS 当前输出；也可以单独指定本应用使用的设备。

| 模式 | 行为 |
|---|---|
| 自动（默认） | 原生兼容设备使用系统设置；明确识别出的普通双声道耳机启用兼容层；其他设备使用系统原生播放 |
| 强制耳机空间音频 | 普通双声道输出使用兼容层；原生兼容设备仍使用系统路径；超过两声道的输出保持原生播放 |
| 关闭 | 关闭兼容层，并禁止当前 AVPlayerItem 空间化 |

3.5 mm 耳机通过 `BuiltInHeadphoneOutputDevice` 识别；其他耳机参考音频流的 headphones terminal 类型。原生能力通过未被伪装的 CoreAudio 属性查询确认，不仅根据 Bluetooth／USB transport 推断。

切换输出或模式会重建播放链路并恢复进度与播放状态。输出设备离开设备列表或变为不可用时暂停，避免突然改用其他输出。

### PoseBridge 头部追踪

点击工具栏的“头部追踪”，开启“接收外部姿态”。默认监听 `127.0.0.1:9000`，支持 PoseBridge **OSC 3** 的四元数和欧拉角输出。播放器不连接或配置传感器；USB／蓝牙采集、安装方向和设备重连由外部 PoseBridge 管理。

- 将外部 PoseBridge 的 `--osc-target` 设为面板中的本机地址与端口。
- “来源名称”对应 PoseBridge 的 `--source-id`；留空会锁定第一个有效姿态来源。修改端口或来源前先关闭接收。
- 第一次有效姿态定义正前方。面向屏幕后点击“回正”，或按 `⌘⇧R`，重新建立听音参考；不会向设备发送归零或保存命令。
- 超过 500 ms 没有新姿态，或来源报告停止／失败，保持最后朝向。心跳与重复报文不会延长姿态有效期。来源重新连接或参考变化时保持声场连续，可再次回正。
- 关闭接收恢复系统朝向。关闭空间音频时继续接收、显示姿态，但不向渲染器应用；重新开启空间音频后恢复应用。
- 回环端口被其他程序占用时会提示错误，不会抢占其他接收器的端口。

无需传感器即可验证。例如在 PoseBridge 仓库运行：

```sh
./target/release/posebridge simulate --source-id headset --pattern yaw \
  --sample-rate-hz 100 --osc-rate-hz 100 --osc-target 127.0.0.1:9000
```

播放器须开启接收并播放开启空间音频的内容；可把来源名称设置为 `headset`。硬件采集请在外部 PoseBridge 中使用已验证的设备标识与佩戴映射。应用会保存接收开关、端口和来源，不保存上次的回正参考。

### 已知限制

- 使用系统 AVFoundation 支持的本地格式。没有 FFmpeg 回退、转码、网络播放、媒体库、均衡器或字幕管理。
- 本机测试的 16／24 声道 APAC 在明确关闭空间化时，原生 AVPlayer 返回 `fmt?` 格式错误。遇到此类 APAC 文件，应用会保留位置并提示切回自动／强制模式；不会暗中忽略“关闭”。
- `spen` / `spmd` 是私有实现细节，系统更新后需要重新验证。界面的模式表示应用播放策略，不等于控制中心已把设备识别成 AirPods。
- 普通耳机可使用 PoseBridge 提供的姿态，但不会因此获得 AirPods 的内置传感器或个性化配置。本应用没有安装虚拟驱动，也没有独立 PCM 中转或后台空间渲染器。
- PoseBridge 接入依赖本机验证的 AUSpatialMixer 私有四元数属性 `3102`。系统更新后需重新验证；面板会显示渲染器是否接受姿态。外部传感器的实际佩戴方向仍需确认。
- 测试和当前可用硬件见 [验证记录](Tests/VALIDATION.md)。

## 构建

需要 Xcode 27 和 XcodeGen 2.44.1 或更新版本。工程配置以 `project.yml` 为准，生成的 `.xcodeproj` 不提交到 Git；调整 target、构建设置或 scheme 时修改 YAML，再重新生成。

在 Xcode 中开发：

```sh
xcodegen generate
open SpatialUnlockPlayer.xcodeproj
```

`SpatialUnlockPlayer` scheme 默认以 Debug 配置运行，Archive 使用 Release；`SpatialUnlockPlayer-Diagnostics` scheme 使用 Diagnostics 配置。应用依赖独立的 `SpatialShim` 动态库 target，Xcode 负责链接、嵌入与签名。XcodeGen 配置字段见[官方说明](https://github.com/yonaskolb/XcodeGen/blob/2.44.1/Docs/ProjectSpec.md)。

要生成项目根目录下可双击的应用，先关闭正在运行的 SpatialUnlock Player，再执行：

```sh
zsh build.sh
```

`build.sh` 自动生成工程、调用 `xcodebuild` 构建 Release，然后将应用导出到项目根目录的 `SpatialUnlock Player.app`，可执行文件为 `SpatialUnlockPlayer`。`zsh build.sh --debug` 可导出 Debug 版本。

各配置的 Xcode 构建产物位于 `build/Products`，根目录只保留当前导出版本。构建使用 Xcode 默认的 DerivedData 位置和系统共享模块缓存；仓库内不创建 DerivedData 或模块缓存目录，也没有第三方包依赖。

应用标识符沿用 `local.sakuzy.SpatialPlayer`，以继续使用更名前保存的播放列表和设置。

`libSpatialShim.dylib` 放在应用的 `Contents/Frameworks` 中，通过 `@rpath` 正常链接，在启动期加载。双击启动不需要环境变量。Xcode 使用 ad hoc 签名；不开启 App Sandbox / Hardened Runtime，未进行商店发布或公证。

### 应用图标

图标使用白底蓝色扁平开锁图形，资源位于 `Resources/Assets.xcassets/AppIcon.appiconset`，由 Xcode 编译打包。矢量绘制源在 `Scripts/generate_app_icon.swift`；修改后可复用系统模块缓存重新生成全部 macOS 图标尺寸：

```sh
xcrun swift -module-cache-path "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex" Scripts/generate_app_icon.swift
```

## 实现

- `PlayerModel` 管理单个 AVPlayer、多份命名列表、加载、定位及切换；浏览列表与播放列表分别记录。`PlaybackOrder` 独立决定自动续播、手动切歌和随机历史；`PlaybackSession` v2 保存列表集合并兼容迁移 v1。generation 与 seek serial 拒绝旧异步回调；音频输出始终由 `audioOutputDeviceUniqueID` 指定。
- `AudioDeviceCatalog` 枚举输出，并监听设备列表、默认输出、存活状态和流配置。保存的是 UID，不是易变的 AudioObjectID。
- `SpatialShimSetConfiguration(deviceID, enabled)` 用单个原子状态设置目标，仅拦截该设备的 `AudioObjectHasProperty`、`AudioObjectGetPropertyDataSize`、`AudioObjectGetPropertyData`。原始能力查询从动态库内调用原始 API，避免把自己的伪装误认为硬件能力。
- 音频解码和空间渲染由 AVPlayer / MediaToolbox / AudioToolbox 完成，兼容层不处理音频样本。
- PoseBridge OSC 在独立串行队列上解码、校验时效及处理来源／会话变化；按 `posebridge.yxz.v1` 还原物理旋转，再生成世界到头部的四元数。回正、会话对齐不修改源数据或设备配置。
- `HeadPose.c` 仅跟踪本进程的 Apple AUSpatialMixer，替换其朝向设置，并在渲染前通知中读取原子姿态快照。因此普通耳机不依赖 AirPods 的系统头追回调。音频线程不解析网络、不分配内存或写日志；混音器销毁时注销通知。

## 诊断构建

```sh
zsh build.sh --diagnostics
```

Diagnostics 配置为 Swift 与 C 两个 target 同时启用 `SPATIAL_DIAGNOSTICS`，增加只读 AudioQueue 属性记录及本地回归脚本入口，不修改队列参数或音频样本。PoseBridge 的姿态接入属于正式功能，两种构建均包含。详细用法见 [测试说明](Tests/README.md)。交付前重新运行不带参数的 `build.sh`，导出不含测试入口与队列诊断钩子的 Release 版本。
