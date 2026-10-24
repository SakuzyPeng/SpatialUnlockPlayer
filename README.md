# SpatialUnlock Player

**简体中文** · [English](README.en.md)

一个 macOS 本地音视频播放器，让**普通双声道耳机**（3.5 mm、USB DAC、蓝牙）也走 Apple 原生的空间音频渲染路径——与 AirPods 使用同一个系统渲染器，不经过虚拟声卡，也不换用第三方 HRTF。

> 它不是虚拟音频驱动，也不是系统级开关：只对本应用播放的内容生效。只播放 AVFoundation 支持的本地文件，没有 FFmpeg 回退、转码、网络播放、媒体库或字幕管理。

**运行环境：Apple Silicon，macOS 27 或更新版本。当前验证版本为 macOS 27.0.1。**

本文只讲它解决什么问题、怎么上手和构建。**每个操作和设置的具体行为见[用户手册](docs/MANUAL.md)**（[English](docs/MANUAL.en.md)）。

## 目录

- [它解决什么问题](#它解决什么问题)
- [能用它做什么](#能用它做什么)
- [获取应用](#获取应用)
- [上手五步](#上手五步)
- [空间音频模式怎么选](#空间音频模式怎么选)
- [让普通耳机与 AirPods 的渲染一致](#让普通耳机与-airpods-的渲染一致)
- [输出设备](#输出设备)
- [常见问题](#常见问题)
- [已知限制](#已知限制)
- [从源码构建](#从源码构建)
- [文档](#文档)
- [相关项目](#相关项目)
- [许可证](#许可证)

## 它解决什么问题

macOS 只给它认作原生兼容的耳机（如 AirPods）打开耳机空间渲染路径，普通耳机默认不走这条路径。本应用在自己的进程内，只对选定的输出设备回答“支持空间音频”的 CoreAudio 能力查询，然后照常交给 AVPlayer 播放；解码和空间渲染仍完全由系统完成。

这条路径和 AirPods 到底差多少，在本机用 AirPods Max 与 FIIO KA11（均为 USB 连接）做了逐样本对照，观察点从空间混音器一直到 USB 传输：

- **空间渲染结果相同**：HRTF 和头部朝向相同时，两条路径的空间混音器输出逐位相同。低电平与高峰值 5.1、Atmos、APAC 16 声道均已验证。
- **差异出在后级**：空间混音器之后还有响度压缩与真峰值限幅。AirPods 路径在这两级前后各设置 −20／+20 dB，普通耳机路径是 0／0 dB；压缩和限幅是非线性的，两种设置对同一信号的作用不同。
- **可以对齐**：把这对增益也设为 −20／+20 dB，本进程交给 HAL 的 PCM 与 AirPods 逐位相同。双向交换参数都得到相同结果，确认了因果关系。
- **HAL 之后仍有差异**：同步抓取 USB 传输后发现，即使 HAL 逐位相同，两设备的 USB PCM 仍不同。AirPods 在 HAL 之后约衰减 12 dB，样本容器和量化也不同；关闭空间音频时同样存在，与兼容层和余量设置无关。

```mermaid
flowchart LR
    P[AVPlayer 解码] --> S[Apple 空间混音器<br/>HRTF + 头部朝向]
    S --> G1[前置增益]
    G1 --> D[响度压缩<br/>真峰值限幅]
    D --> G2[后置增益]
    G2 --> V[播放器音量]
    V --> H[本进程 HAL 输出]
    H --> U[系统／驱动后级<br/>USB 载荷]
```

| | AirPods（原生） | 普通耳机（默认） | 普通耳机 + 余量 20 dB |
|---|---:|---:|---:|
| 前置／后置增益 | −20／+20 dB | 0／0 dB | −20／+20 dB |
| 空间混音器 PCM（同 HRTF、同朝向） | 基准 | 逐位相同 | 逐位相同 |
| HAL PCM | 基准 | 不同 | 逐位相同 |
| USB PCM | 基准 | 不同 | 不同：AirPods 一侧约 −12 dB，量化不同 |

结论覆盖本机、这个系统版本、这些设备和素材。一致的是空间混音器和本进程 HAL 两层；USB 载荷不同，耳机内部 DSP、DAC 和声学输出没有测量，因此不能外推为最终听到的声音相同。方法与数值见[进程内对照](Tests/ROUTE_COMPARISON.md)和[USB PCM 对照](Tests/USB_AUDIO_COMPARISON.md)。

## 能用它做什么

- **普通耳机听空间音频**：多声道 PCM、Atmos、APAC 等系统支持的内容，经 Apple 空间渲染器输出为双耳信号。
- **按设备调空间渲染**：处理余量（0–20 dB）和 HRTF（通用／个性化）按输出设备分别保存，面板显示实际生效状态，而不只是请求。
- **外部头部追踪**：接收 [PoseBridge](https://github.com/SakuzyPeng/PoseBridge) OSC 姿态，普通耳机也能随头转动声场，不依赖 AirPods 的系统头追。
- **参数 EQ**：导入 AutoEQ / Equalizer APO 参数文本，在空间化和头追之后处理最终双声道输出。
- **多播放列表**：命名列表、顺序／列表循环／单曲循环／随机；关掉再打开会回到上次的曲目和位置，保持暂停。
- **视频播放**：AVKit 画面，支持全屏。

## 获取应用

源码仓库不包含编译后的应用，可通过以下方式获取：

- **发布版本**：打开 [Releases](https://github.com/SakuzyPeng/SpatialUnlockPlayer/releases)，在对应版本的 **Assets** 下载 `SpatialUnlockPlayer-0.2.1-macos-arm64.zip` 和同名 `.sha256` 校验文件。尚无发布版本时，可使用 CI 构建。
- **CI 构建**：打开 [Actions → CI](https://github.com/SakuzyPeng/SpatialUnlockPlayer/actions/workflows/ci.yml)，选择 `main` 上绿色通过的运行，在页面底部 **Artifacts** 点击名称以 `SpatialUnlockPlayer-` 开头、包含版本号的应用包下载。需要登录 GitHub，产物保留 7 天。
- **自己构建**：按[从源码构建](#从源码构建)，一条命令导出可双击的应用。

从 CI 下载时，先解开 GitHub 提供的外层 Artifact ZIP，得到 `SpatialUnlockPlayer-0.2.1-macos-arm64.zip` 和它的 `.sha256` 文件。将应用 ZIP 与校验文件放在同一目录，校验后解压：

```sh
shasum -a 256 -c SpatialUnlockPlayer-0.2.1-macos-arm64.zip.sha256
ditto -x -k SpatialUnlockPlayer-0.2.1-macos-arm64.zip .
```

解压得到 `SpatialUnlock Player.app`，可移到“应用程序”目录后打开。

应用使用 ad hoc 签名，未经 Apple 公证，下载的版本可能被 Gatekeeper 拦截。确认来源是本仓库后，可按 macOS 提示在“系统设置 → 隐私与安全性”中允许打开。

## 上手五步

1. 双击 `SpatialUnlock Player.app` 启动。
2. `⌘O` 打开文件，或把文件拖进窗口。双击列表条目（或选中后按 Return）开始播放。
3. 在输出菜单选择你的耳机，或保留“系统默认”。
4. 空间音频模式保持“自动”。底部状态应显示“普通耳机兼容模式”；如果显示“系统原生播放”，改为“强制耳机空间音频”。
5. 想进一步接近 AirPods 的结果，点模式旁的滑块图标打开高级设置，见[下一节](#让普通耳机与-airpods-的渲染一致)。

空格播放／暂停，`⌘←` / `⌘→` 切换上一项／下一项，`⌘⌥←` / `⌘⌥→` 后退／前进 10 秒。更多操作见[用户手册](docs/MANUAL.md#打开与播放)。

## 空间音频模式怎么选

切换输出或模式会重建播放链路，并恢复进度与播放／暂停状态。

| 模式 | 行为 |
|---|---|
| **自动**（默认） | 原生兼容设备使用系统设置；明确识别出的普通双声道耳机启用兼容层；其他设备使用系统原生播放 |
| **强制耳机空间音频** | 普通双声道输出使用兼容层；原生兼容设备仍使用系统路径；超过两声道的输出保持原生播放 |
| **关闭** | 关闭兼容层，并禁止当前内容空间化 |

**不确定选哪个？** 保持“自动”。如果用的是 USB DAC 或蓝牙耳机，而状态显示“系统原生播放”，说明设备没有把自己报告为耳机，改用“强制耳机空间音频”。设备识别规则见[用户手册](docs/MANUAL.md#输出和空间音频)。

## 让普通耳机与 AirPods 的渲染一致

高级设置的两个选项，正好对应对照实验中的两个变量：

| 选项 | 作用 | 对齐 AirPods |
|---|---|---|
| **处理余量** | 设置响度压缩与限幅前后的那对增益；主音量独立控制 | 自定义 **20 dB** |
| **HRTF 模式** | 请求通用或系统已有的个性化 HRTF，不修改全局设置 | 与 AirPods 实际使用的一致：系统里建过个性化空间音频档案就选**个性化**，否则选通用 |

两项初始都为“系统决定”，即不覆盖系统行为。设置按实际输出设备分别保存，“恢复此设备的系统设置”可一键还原。个性化档案未实际启用时，面板会明确显示仍在使用通用 HRTF。详见[用户手册](docs/MANUAL.md#空间音频高级设置)。

选择“个性化”会在本播放器进程内启用档案加载所需的能力兼容处理。Mac 已有可用个人档案时，无需保持 AirPods 在线或作为系统默认输出；本机已验证 AirPods 离线、默认 FIIO 时与正常个人 HRTF 参考逐样本一致。见[个性化可用性与强制加载对照](Tests/HRTF_AVAILABILITY.md)。

对齐的范围止于本进程交给 HAL 的输出。AirPods 在 HAL 之后约 −12 dB 的数字衰减不在本应用控制范围内，应用也不做补偿；不建议据此手动加减 12 dB，主机传输幅度不能单独决定耳机内部处理、音量和最终声压。见[USB PCM 对照](Tests/USB_AUDIO_COMPARISON.md#结论边界与产品含义)。

## 输出设备

| 输出 | 自动模式下 |
|---|---|
| 内置 3.5 mm 耳机口 | 识别为耳机，启用兼容层 |
| USB DAC、蓝牙普通耳机 | 音频流报告为耳机时启用兼容层；否则使用系统原生播放，可改用强制模式 |
| AirPods 等原生兼容设备 | 系统原生路径，不做任何伪装；高级设置同样可用 |
| 内置扬声器、多声道接口 | 系统原生播放 |

原生能力通过未被伪装的 CoreAudio 查询确认，不只根据 Bluetooth／USB 推断。输出设备离开或不可用时暂停，不会突然改用其他输出。本机已验证内置 3.5 mm、FIIO KA11（USB）和 AirPods Max，记录见[验证记录](Tests/VALIDATION.md)。

## 常见问题

**控制中心为什么没把我的耳机显示成 AirPods／空间音频？**
兼容层只在本应用进程内生效，不改变系统对设备的识别。界面上的模式表示应用的播放策略。

**EQ 面板显示“当前播放路径未应用 EQ”？**
首版 EQ 只在空间渲染路径上生效。关闭空间化或当前内容没有经过空间渲染器时不作用，配置与开关仍保留。

**头部追踪没有反应？**
确认已开启“接收外部姿态”、PoseBridge 的 `--osc-target` 与面板端口一致（默认 `127.0.0.1:9000`）、来源名称与 `--source-id` 匹配，并且正在播放开启空间音频的内容。超过 500 ms 没有新姿态会保持最后朝向。没有传感器时可用 `posebridge simulate` 排查，见[用户手册](docs/MANUAL.md#posebridge-头部追踪)。

**关闭空间音频后 APAC 文件报格式错误？**
本机 16／24 声道 APAC 在明确关闭空间化时，原生 AVPlayer 返回 `fmt?`。应用会保留位置并提示切回自动／强制模式，不会暗中忽略“关闭”。

**设置和播放列表会保存吗？**
会。列表、当前曲目和位置、音量、模式、输出选择、每个设备的高级设置、EQ 与头追设置都会保存；只保存文件引用，不复制媒体文件。见[用户手册](docs/MANUAL.md#保存与恢复)。

## 已知限制

- 依赖私有实现细节：能力兼容层使用 `spen` / `spmd`，头追使用 AUSpatialMixer 私有四元数属性 `3102`。系统更新后需要重新验证；面板会显示渲染器是否接受姿态。
- 只播放系统 AVFoundation 支持的本地格式。
- 多声道 APAC 无法在关闭空间化时播放，见[常见问题](#常见问题)。
- 首版 EQ 只作用于空间渲染路径。
- 没有安装虚拟驱动，也没有独立 PCM 中转或后台空间渲染器；个性化 HRTF 档案由系统提供。
- 外部传感器的实际佩戴方向由 PoseBridge 负责，需自行确认。
- 对照结论只覆盖已测的系统版本、设备和素材，见[它解决什么问题](#它解决什么问题)。

## 从源码构建

需要 Xcode 27 和 XcodeGen 2.44.1 或更新版本（`brew install xcodegen`）。没有第三方包依赖。

先关闭正在运行的 SpatialUnlock Player，再执行：

```sh
zsh build.sh
```

脚本生成 Xcode 工程、构建 Release，并导出项目根目录的 `SpatialUnlock Player.app`，导出时自动检查签名、权限和诊断入口。`zsh build.sh --debug` 导出 Debug 版本，`zsh build.sh --diagnostics` 导出带回归测试入口的诊断版本。

在 Xcode 中开发：

```sh
xcodegen generate
open SpatialUnlockPlayer.xcodeproj
```

工程配置以 `project.yml` 为准，生成的 `.xcodeproj` 不提交到 Git；调整 target、构建设置或 scheme 时修改 YAML，再重新生成。签名、动态库嵌入、配置差异和图标生成见[架构](docs/ARCHITECTURE.md#构建产物)。

`zsh Scripts/ci.sh` 在本机运行与 CI 相同的检查和打包（另需 `Tests/requirements-ci.txt` 中的 Python 依赖），见[持续集成](Tests/README.md#持续集成)。

## 文档

- [用户手册](docs/MANUAL.md)（[English](docs/MANUAL.en.md)）：播放列表、播放模式、保存恢复、输出识别、高级设置、参数 EQ、PoseBridge 头部追踪
- [架构](docs/ARCHITECTURE.md)：模块、渲染链、构建产物、诊断构建
- [进程内对照](Tests/ROUTE_COMPARISON.md)：AirPods 与普通耳机的空间混音器／HAL 逐样本对照和后级增益定位
- [USB PCM 对照](Tests/USB_AUDIO_COMPARISON.md)：HAL 之后的 USB 传输载荷、格式与约 12 dB 幅度差
- [验证记录](Tests/VALIDATION.md)：各功能的验收范围与结果
- [测试说明](Tests/README.md)：回归脚本、探针与复现命令
- [持续集成](Tests/README.md#持续集成)：GitHub Actions 检查范围、ad hoc 应用包和日志

## 相关项目

| 项目 | 关系 |
|---|---|
| [PoseBridge](https://github.com/SakuzyPeng/PoseBridge) | 头部追踪传感器的采集与 OSC 输出，本应用作为接收端 |
| [MacinDecode Spatial Player](https://github.com/SakuzyPeng/MacinDecode-Spatial-Player) | 自带 AC-4／APAC 解码器和 SAF 双耳渲染、支持 Windows 的播放器；SpatialUnlock Player 则完全使用系统解码和 Apple 渲染器 |

## 许可证

本项目采用 [MIT 许可证](LICENSE)。Sony MDR-MV1 参数 EQ 测试数据来自 [AutoEq](https://github.com/jaakkopasanen/AutoEq)，版权、许可和来源说明见[第三方声明](THIRD_PARTY_NOTICES.md)与[测试数据说明](Tests/Fixtures/README.md)。
