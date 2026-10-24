# SpatialUnlock Player 首版验证记录

## 2026-10-24：播放模式与多播放列表

- 增加顺序播放、列表循环、单曲循环和随机播放；模式全局保存。随机每轮覆盖全部条目，避免轮次交界连续重复，上一项和回退后的下一项沿实际历史移动。
- 命名列表支持新建、重命名、删除、清空与浏览切换。浏览列表和播放列表分开记录，自动续播和切歌跟随播放列表；打开与异步拖入绑定发起时的列表。移除当前曲目选择后续仍保留的邻项，没有则选择前项，并保留暂停意图。
- `PlaybackSession` v2 保留全部列表、空列表、浏览与播放列表、当前曲目和进度；v1 自动迁移为“默认列表”，条目 ID、重复文件和位置保持。重新启动保持暂停，离线文件引用继续保留。
- `zsh Tests/playback_test.sh` 通过：循环边界、空／单项列表、20 轮可控随机顺序、轮次交界、历史回退／前进、增删、迁移、空列表恢复和无效引用修复。
- `python3 Tests/playback_integration_test.py` 四组真实 AVPlayer 场景全部通过，共 155 个操作／断言步骤，覆盖真实完播通知、四种模式、随机历史与重复文件、多列表归属、导入中切换列表、快速切换、批量移除当前曲目及失败后暂停。结果位于 `Tests/Artifacts/persistence-playback-*`、`persistence-shuffle-rounds-*`、`persistence-list-ownership-*` 和 `persistence-remove-and-failure-*`。
- `python3 Tests/persistence_test.py` 11 次独立进程、52 个步骤通过，覆盖 v1 迁移、原有保存与离线文件恢复、多列表和空列表、全局模式、删除当前／最后一份列表，以及恢复后暂停。
- 原有 smoke、regression、available-routes、apac24-off、disconnect-drop 五组播放／空间音频场景通过。纯头追协议和真实 Apple Audio Unit 离线测试通过；PoseBridge quaternion、euler、端口占用三组集成共 64 步通过，渲染错误为 0。本轮没有增加实体传感器或 AirPods 硬件验收。
- 隔离偏好下的真实窗口验证：新建与重命名连续打开时的标题、名称初值和保存状态正确；文件面板追加到浏览列表；双击切歌、返回正在播放列表、底部模式与菜单栏选择、紧凑窗口和视频全屏控件正常。异步拖入通过真实 NSItemProvider 链路检查，未补做 Finder 跨窗口鼠标拖放。
- Diagnostics 与 Release 构建通过，根目录正式版与 Release 产物一致，签名与 Info.plist 校验通过；确认正式版不含诊断脚本入口或 AudioQueue 诊断钩子。正式版实际启动后，日常使用的列表、当前曲目和暂停位置正常恢复。
- 额外将完整 regression 场景的音量强制设为 0 时，视频播放后暂停并精确定位到 6 秒连续两次超时，状态保持 seeking；使用原脚本的默认音量时全部通过。这一静音变体仍有待排查，不能计作通过；本轮保留了实际失败记录 `Tests/Artifacts/persistence-modes-base-regression-result.json`。

## 2026-10-23：外部 PoseBridge OSC 接入

- 接入方式按用户选择为外部 OSC 接收，没有嵌入 PoseBridge 动态库或管理传感器。默认仅监听 `127.0.0.1:9000`，支持 OSC 3 quaternion/euler 两种姿态消息及独立 info/status。
- 后台队列处理协议校验、来源锁定、源停留年龄与本地经过时间、去重、会话／实例／参考变化。旧元数据和旧姿态不能越过新参考边界；角度跨越 ±180° 时保持四元数符号连续。500 ms 过期或终态冻结；本地回正不发送设备命令。
- 原子姿态快照接入本进程 AUSpatialMixer 私有属性 3102。主动渲染前通知解决普通耳机没有原生头追回调的问题；关闭接管恢复最后的原生朝向。回调内不解析网络、分配内存、写日志或等待发布线程。
- `Tests/head_tracking_test.sh` 通过：协议边界、坐标转换、回正与时效；真实 Apple 空间混音器的离线 PCM、原生／外部更新竞争、并发快照、关闭恢复、重新初始化及 70 次实例回收。离线中置 1800 Hz 的左右电平差随 Z 轴 +45°／−45° 分别为 +9.07／−7.51 dB。
- `Tests/posebridge_integration_test.py` 使用现有真实 PoseBridge CLI 模拟器、普通 3.5 mm 耳机输出和正常链接的动态库：quaternion 30 步、euler 30 步、端口占用 4 步全部通过。最终两轮分别接收 515／518 个姿态，应用 513／516 次，渲染错误为 0。采样与渲染节奏不同，两个计数不要求相等。
- 同时重跑原有 `smoke` 22 步和 `regression` 59 步，均通过；覆盖 APAC 16／24 声道、Atmos、PCM、视频、模式切换、播放列表及异常输入等原有场景。结果保存于 `Tests/Artifacts/posebridge-integration/base-*-result.json`。
- Release 实际界面检查：接收开关、来源名称、三个角度、状态心跳、回正、模拟器停止后的保持提示与关闭恢复均可用。原有播放列表和暂停位置恢复正常。
- Release 构建通过，根目录导出应用签名／Info.plist 校验通过；保留正式头追功能，不含 AudioQueue 测试观察器或诊断脚本入口。构建检查改为匹配可执行文件路径，避免把工作目录名含 SpatialUnlockPlayer 的工具进程误判为播放器。
- 本轮没有连接实体 WIT 传感器，也没有测量 USB/BLE 或动作到声音的总延迟。当前 PoseBridge GUI 的目标地址与默认接收端一致，但传感器尚未连接且 OSC 输出未开启；佩戴映射由外部 PoseBridge 负责。

验证日期：2026-10-23。环境：Apple Silicon、macOS 27.0.1、Xcode 27。交付应用为普通 release 构建，已移除测试入口和 AudioQueue 诊断钩子。

以下初版验证完成于更名前，当时应用名称为 SpatialPlayer。

## 启动、链接与签名

- 从 Finder 双击 `SpatialPlayer.app` 启动，随后通过 Finder“打开方式 → SpatialPlayer”打开视频。
- 应用通过 `@rpath/libSpatialShim.dylib` 正常链接；测试运行的 `DYLD_INSERT_LIBRARIES` 为空。release 版再次打开用户的 APAC 文件并正常播放。
- C 检查程序通过：正常链接的 interpose、原始能力查询绕过、目标设备限定、UInt32 大小及边界保护、启用／停用。
- `codesign --verify --deep --strict` 通过。动态库与应用均为 ad hoc 签名，无 Hardened Runtime；未安装驱动或服务。
- `nm` 确认 release 动态库仅保留三个 CoreAudio 查询拦截，没有 `diagnosticQueueSet`。

## 自动回归

结果保存在本机 `Tests/Artifacts/*-result.json`。以下 5 个场景的 `passed` 均为 `true`，共执行 129 个步骤；步骤数包含操作、等待和断言，不等同于 129 个独立测试用例。

| 场景 | 步骤 | 主要覆盖 |
|---|---:|---|
| smoke | 22 | APAC 16 声道、暂停后定位 30 秒、关闭空间化报错、恢复自动、定位 120 秒 |
| regression | 59 | APAC 24 声道、Atmos、5.1 PCM、视频、快速模式切换、输出不可用、错误文件、增删、连续播放、末项停止 |
| available-routes | 16 | 暂停在 45 秒，从 3.5 mm 切换到内置扬声器，再切回；进度和暂停状态保持 |
| apac24-off | 11 | APAC 24 声道关闭空间化报错，恢复自动后继续播放 |
| disconnect-drop | 21 | NSItemProvider 多文件导入、设备目录移除模拟、断开后暂停、恢复后保持暂停、快速选择不同 APAC 文件 |

设备移除测试只改变诊断构建的设备目录快照，不操作系统的设备配置。真实插拔及跨窗口鼠标拖入尚未单独完成；导入测试调用的是实际 `NSItemProvider` 加载路径。

## 空间音频链路

当前可用耳机输出为内置 3.5 mm 接口，UID 为 `BuiltInHeadphoneOutputDevice`。AudioObjectID 在运行时解析，不固定在源码或用户设置中。

诊断构建只记录系统成功接受的 AudioQueue 属性，不改变属性或音频样本：

| 文件／模式 | `q_sp` | 内部声道布局 |
|---|---:|---|
| 5.1 PCM，自动 | 1 | 6 声道，`0x00790006` |
| 5.1 PCM，关闭 | 0 | 6 声道，`0x00790006` |
| Dolby Atmos，自动 | 1 | 16 声道 9.1.6，`0x00c10010` |
| Dolby Atmos，关闭 | 0 | 6 声道，`0x007b0006` |
| APAC 16 声道，自动 | 1 | 16 声道 9.1.6，`0x00c10010` |
| APAC 24 声道，自动 | 1 | 24 声道 22.2，`0x00cc0018` |

这些是渲染链路的内部参数，不能解释为耳机最终输出了 16／24 个物理声道。Atmos 文件的基础音频格式记录为 Dolby Digital Plus、6 声道，与内部对象渲染布局分别记录；这不足以完整标注 Atmos。后续按用户要求移除了音频和视频界面的编码、声道数及采样率标注，保留内部诊断记录。

本轮没有新增 USB 最终 PCM 抓包，也没有 3.5 mm 模拟端录波；因此链路参数验证不能替代最终音频效果的硬件测量。前期 FIIO USB 捕获验证的是原型方案，不计作本应用的新硬件回归。

## 实际窗口检查

- Finder 双击启动、Finder“打开方式”、原生打开面板、多选文件追加均通过。
- 已有列表加入文件保持当前播放项；空列表打开 APAC 自动播放。
- 视频画面、暂停、进度滑块、全屏进入／退出正常。测试视频的帧计时与播放器进度相符；未做独立音画同步测量。
- 双击短音频开始播放，自动进入下一项，最后一项结束后停止。
- 右键移除条目、菜单清空列表正常；被移除条目的原始文件仍存在。
- release 版 APAC 在暂停 30 秒时切换自动／强制模式、显式外置耳机／系统默认输出，位置和暂停状态保持。
- 初版验证时，音量、模式和输出 UID 在退出后重新打开时保留，播放列表不保留。之后已按用户要求增加列表持久化，补测见下文。
- 播放 APAC 时关闭窗口，应用进程退出，无残留 SpatialPlayer 进程。重新打开后不自动恢复播放。
- 验收后恢复为系统默认输出、自动模式、10% 音量。

## 播放列表持久化补测

2026-10-23 增加持久化：在应用偏好中保存列表的文件引用、顺序、条目 ID、标题、当前曲目和播放位置；不缓存媒体内容。启动时恢复并保持暂停，播放中每 5 秒保存位置，列表变更、定位、暂停、播放结束和退出时保存。

`python3 Tests/persistence_test.py` 已通过 6 次独立进程启动、共 30 个操作／断言步骤：

- APAC 暂停在 30 秒后退出，下一进程恢复相同曲目和位置且不自动播放。
- 相同文件的两个独立列表条目保留各自 ID，列表顺序不变。
- 移除首项后再次启动，删除生效，当前 APAC 曲目和位置仍保留。
- 将专门生成的测试 PCM 文件暂时移走后，条目仍保留；选择它会报告错误，下一次启动仍保留，且能切换到正常视频。
- 视频暂停在 6 秒后恢复正确；清空后再次启动为空列表。

测试使用独立偏好域，未改动用户媒体文件；诊断场景和结果见 `Tests/Artifacts/persistence-*`。

## 更名补测

2026-10-23 更名为 SpatialUnlock Player，项目目录改为 `SpatialUnlockPlayer`。在新目录构建诊断版后，`python3 Tests/persistence_test.py` 的 6 次进程启动、30 个步骤全部通过；随后重新构建正式版，签名验证与 Info.plist 检查通过。应用包为 `SpatialUnlock Player.app`，可执行文件为 `SpatialUnlockPlayer`，只保留一套应用产物。日常使用的 bundle ID 沿用 `local.sakuzy.SpatialPlayer`，继续读取已有播放列表和设置。

## XcodeGen 迁移补测

2026-10-23 使用 XcodeGen 2.44.1、Xcode 27，从 `project.yml` 生成应用和动态库两个 target。Debug、Release、Diagnostics 三种配置均通过构建、签名验证与 Info.plist 检查；构建中间文件使用 Xcode 默认 DerivedData，模块缓存使用系统共享目录。

- Diagnostics 构建重新通过上述 5 组播放回归，共 129 个步骤，结果见 `Tests/Artifacts/xcodegen-*-result.json`；播放列表持久化的 6 次进程启动、30 个步骤也全部通过。
- C 检查程序分别链接诊断版和正式版的 `libSpatialShim.dylib`，正常链接、原始能力查询绕过、UInt32 数据大小、边界保护及停用恢复均通过，运行时没有设置 `DYLD_INSERT_LIBRARIES`。
- 确认 Diagnostics 包含测试入口和 `diagnosticQueueSet`，Release 均不包含。根目录导出的可执行文件与 Release 构建产物一致，动态库依赖为 `@rpath/libSpatialShim.dylib`。

## 已知限制与未完成的硬件验证

- 两个用户 APAC 文件在明确关闭空间化时，AVPlayer 返回 AVFoundation `-11800`、底层 OSStatus `1718449215`（`fmt?`）。这一现象也在原始最小播放器中复现。应用显示可恢复错误并保留进度；切回自动／强制模式可继续，未静默忽略关闭设置。
- AirPods 原生设备回归的 `native-route-result.json` 未通过：脚本假设系统默认输出仍为原生兼容耳机，但当时实际输出已是 3.5 mm。随后 CoreAudio 输出列表中没有可用的 AirPods 输出，不能将此场景记作原生硬件通过。
- 本轮没有可用的 FIIO 输出，FIIO 与 AirPods 的完整应用回归需在相应输出可用时补做。未改变用户的系统默认输出、蓝牙配置或安装任何 HAL 驱动。
- `spen`／`spmd` 属于系统私有实现细节，后续 macOS 版本需要重新验证。
