# SpatialUnlock Player 首版验证记录

## 2026-10-24：高级空间音频设置产品化

- 新增高级面板、按实际设备 UID 独立保存设置、0–20 dB／0.1 dB 自定义余量、系统决定／通用／个性化 HRTF，以及实际生效状态。滑块编辑结束或数值提交后重建一次，恢复播放意图和位置；系统默认输出按实际 UID 恢复设置，两项初始均不覆盖系统。
- 正式 C 模块跟踪当前代次、Apple 组件类型、成功的 bus 0 连接和双声道 Float32 格式，确认 `SpatialMixer → vrq2 → ldnm → cfrk → vrq2` 的唯一完整路径。两个增益在首块输出前成对设置并读回校验，不使用创建顺序推断角色。HRTF 模式请求和实际档案状态分别查询。
- `Tests/advanced_audio_test.sh` 通过：连续数值、默认参数不变、不完整／多条链路、重初始化、旧代次保留与新代次隔离、并发原生参数更新、超过注册表容量的累计实例回收，以及设置失败恢复。恢复失败或运行中参数失配时，受影响链输出为零并请求用系统配置重建。Swift 检查覆盖偏好校验、强制 0 dB 与系统决定的区别、两 UID 保存、输入精度和取消编辑。
- 正式模块的 12 组真实 PCM 对照全部通过，空间混音器与 HAL 均逐位相同、最大差为 0：高峰值 5.1 的 0／5／10／15／20／7.3 dB，低电平 5.1，Atmos，APAC 16，EQ 加固定 45° 朝向，以及 AirPods／FIIO 各自保持系统决定的前后对照。采集复用现有素材，不复制音乐；结果见 `Artifacts/route-comparison/advanced-pcm-summary.json`。末次 C 模块修改后另以 FIIO 正式输出复核已保存的 AirPods 20 dB PCM，两处仍逐位一致。
- 实际 Diagnostics 应用完成 67 步转换、16 步重启恢复、10 步再次重启／重置，共 93 步。覆盖普通耳机与 AirPods、自定义值恢复、系统默认别名、播放／暂停定位、切歌、HRTF 选择、EQ 共存和重置仅影响当前设备。结果位于 `Artifacts/advanced-audio`，日常偏好未被测试数据替换。
- 真实 PoseBridge quaternion／euler 与 EQ、7.3 dB 余量同时应用，共 68 步通过，姿态渲染错误为 0。原有头追／协议、参数 EQ DSP／解析、播放顺序／会话纯测试通过；原有五组真实播放回归在 FIIO 上共 129 步通过，结果见 `Artifacts/advanced-audio/base-*-result.json`。
- 独立签名、独立应用标识符的界面副本检查了高级入口、HRTF 菜单、不透明背景、非法数值提示、数值提交前不改配置、提交后单次重建及播放进度／意图保持、滑块无障碍赋值。拖动的松手提交和设备改变取消由同一编辑状态机及单元检查覆盖。
- 最终 Release 已导出到根目录应用，deep／strict 签名和 Info.plist 校验通过，正常链接正式动态库。确认不含 PCM 探针、测试故障注入、诊断脚本或界面状态文件入口；发布文件哈希及验收汇总见 `Artifacts/advanced-audio/validation-summary.json`。

## 2026-10-24：HAL 差异定位

- 独立探针增加 Apple AudioUnit 逐级输出与参数观察；启用观察器前后的空间混音器和 HAL 样本均逐位相同，正式播放器未修改。
- 确认链路依次经过空间混音器、前置 `AUVariableEQV2`、`AULoudnessNormalizer`、`AUControlFreak`、后置 `AUVariableEQV2`、播放器音量混音器及 HAL。
- 两个 VariableEQ 的参数 7 `PreGain (dB)` 在 AirPods 路径为 −20／+20 dB，FIIO 为 0／0 dB。中间两级均启用压缩／真峰值限幅；因输入电平不同而产生不同动态处理。
- 双向交换两项 PreGain 后，高峰值 5.1 的全部七处输出及 HAL 均与另一设备原始配置逐位相同。Atmos、APAC 16 声道和低电平 5.1 补测同样得到 HAL 最大样本差 0。
- AULoudnessNormalizer 与 AUControlFreak 分别增加 144／34 帧，播放器 2% 音量在这两级之后。数值、完成的对照与复现命令见 [输出对照实验](ROUTE_COMPARISON.md)；`python3 Tests/hal_chain_analysis.py` 验证已保存的原始数据。

## 2026-10-24：AirPods Max / FIIO PCM 对照

- 新增独立实验探针，保留系统个性化设置，复用正式能力兼容层和朝向实现，EQ 关闭、播放器音量 2%、固定朝向。直接观察本进程空间混音器 PostRender 和 HAL PCM，不加入 tap，不修改产品源码或系统输出设置。
- 原始 AirPods 路径实际个性化 HRTF 为 1，FIIO 兼容路径为 0，两者 PCM 不相同；各自三次重复抓取可逐样本复现。
- 只在测试实例中使 HRTF 相同后，低电平 5.1（0°／45°）、Atmos、APAC 16 声道的空间混音器输出均逐样本完全相同。反向关闭 AirPods 实例的个性化，也与原始 FIIO 通用路径完全相同。
- 默认后级配置的 HAL 输出未达到逐样本相同：低电平稳定段残差约 −144.37 dB，Atmos 与 APAC 16 音乐完整窗口分别约 −24.29／−17.59 dB。后续定位见上节，原始数值保留作为调整前对照。
- 高峰值对照中两条路径的实际个性化状态均为 0，该组按通用 HRTF 分类。
- 全部结论、方法、数值与复现命令见 [输出对照实验](ROUTE_COMPARISON.md)，本机证据位于 `Artifacts/route-comparison`。这不替代正式应用完整原生设备回归，也不是传输线或模拟端录波。

## 2026-10-24：正式参数 EQ

- 新增 UTF-8 参数文本导入、全局单配置持久化、总开关、只读参数表和总响应曲线。Sony MDR-MV1 样例保留 −3.12 dB 前级、8 个 PK、1 个 LSC 和 1 个 HSC；频率和 Q 不做定点取整。失败导入不替换当前配置，文件移动／删除不影响恢复。
- 正式 C DSP 接入现有 AUSpatialMixer PostRender；配置和系数在非实时线程准备，渲染线程不等待锁、分配内存、调用 Swift 或写日志。双声道历史独立，约 20 ms 的双处理链输出交叉淡化；重复时间戳复用已处理输出，定位／reset／重建清理历史，静音输入正确输出并逐渐耗尽滤波尾音。
- `Tests/equalizer_test.sh` 通过。44.1／48／96 kHz 下，完整 Sony 与 PK／LSC／HSC 的脉冲 FFT 对照独立模拟原型／双线性变换，20 Hz–20 kHz 最大误差 **0.00000080 dB**，低于 0.1 dB 验收阈值。交错／非交错结果一致；声道隔离、显式 reset、缓存渲染、整组旁路、淡化、快速更新和并发发布／销毁均通过。结果见 `Artifacts/equalizer/dsp-result.json`。
- 正式 EQ + 真实 AVPlayer／HAL 验证 7 组：5.1 PCM 和立体声的空间化开／关，以及 APAC 16、APAC 24、Atmos 的空间化开启。Sony 三个测试频点的 HAL 输出变化与独立参考相差小于 0.1 dB；空间路径的渲染块全部为 **512 帧／48 kHz**，姿态更新有效且错误为 0。关闭空间化时没有空间混音器，EQ 不作用。结果见 `Artifacts/equalizer/*-production-sony.json`。
- 实际应用的 37 步转换、6 步重启恢复和 2 步关闭状态恢复通过：包含原始 Downloads Sony 文件导入、非法文件保留旧值、启停、暂停定位、连续切歌、空间模式切换、设备目录移除与恢复。使用 Regression 独立偏好域，正常链接，没有 DYLD 注入。详见 `Artifacts/equalizer/app-eq-*-result.json`。
- 原有播放顺序／会话纯测试、Apple 空间混音器离线头追与协议测试通过；实际播放模式／多列表回归 155 步和持久化 11 个进程／52 步通过。原有 smoke、regression、available-routes、apac24-off、disconnect-drop 在加载 Sony EQ 后共 134 步通过，包含视频和 APAC 关闭空间化原有格式错误。
- 真实 PoseBridge quaternion／euler／端口占用共 66 步通过，EQ 与头追同时生效；关闭外部头追后 EQ 保持，渲染错误为 0。结果位于 `Artifacts/posebridge-integration-eq`。本轮没有增加实体传感器或模拟输出录波验收。
- 隔离应用副本的原生界面检查通过：视频画面和播放控件、系统四等分缩到最小内容尺寸附近时的 EQ 入口、总响应曲线、十段参数完整显示、开关和状态文字反馈。面板使用不透明背景，视频颜色不会干扰读数；渲染计数不再触发每 200 ms 重绘，保留稳定的辅助功能元素。日常 EQ 偏好没有被测试配置替换。
- 最终 Diagnostics／Release 均构建成功，正式导出应用的 deep／strict 签名与 Info.plist 校验通过；确认可执行文件不含诊断脚本入口，动态库不含 HAL 探针／队列诊断钩子。界面状态刷新优化后，重新执行正式 DSP／解析测试及应用 45 步状态／重启测试，均通过。

## 2026-10-24：EQ 插入点实测

环境为 Apple Silicon、macOS 27.0.1、内置 3.5 mm 耳机输出，实际设备格式为 48 kHz。使用独立 AVPlayer 进程，复现 `PlayerModel` 的空间化许可、设备 UID 和音量设置，正常链接正式兼容层／头追源码编译出的测试动态库。没有修改 `Sources`、正式应用或日常偏好，没有创建独立 Xcode 缓存。本节验证软件音频链路，不是 DAC／模拟端录波或完整产品 EQ 验收。

### 原链路 PostRender

`HeadPose.c` 注册渲染观察器的位置可以扩展为 EQ 入口。真实 AVPlayer 播放 APAC 16 声道、APAC 24 声道、Atmos、5.1 PCM 和立体声时，空间混音器的输出均为双声道、32-bit float、non-interleaved。所有这五组空间化开启用例的已修改缓冲区，与 `AudioUnitRender` 返回后的缓冲区逐块哈希一致；没有渲染／姿态错误。

最终一轮稳定 5.1 测试信号测量如下；三音信号为 900／1800／2700 Hz，DSP 两耳参数相同：

| 检查 | 结果 |
|---|---|
| 混音器 PostRender 整体增益 | 两耳 −6.02060 dB |
| 独立 HAL 输出回调中的整体增益变化 | 左 −6.01906、右 −6.01912 dB |
| 1800 Hz、Q=1、−12 dB 峰值 EQ 在 HAL 输出的中心频率变化 | 左 −12.01179、右 −12.01025 dB |
| 修改样本传到 AudioUnitRender 返回值 | 535／535 块一致 |
| 空间混音器与 HAL 处理块 | 均为 512 帧，48 kHz 下每块约 10.67 ms |
| 姿态从单位四元数变为 Z+45°，1800 Hz 左右电平差 | 从 +0.92897 变为 +9.48704 dB |
| Z+45° 时 EQ 前后左右电平差 | 均为 +9.48704 dB |

这证明 EQ 实际传入了本进程交给 HAL 的输出，且保留了本例的头追电平变化。PostRender 位于本例 `AVPlayer.volume` 之前；HAL 还有播放器的 2% 音量缩放。没有测量动作到声音的总延迟。

空间化关闭时，立体声、5.1 PCM 和 Atmos 仍能播放，但不创建该空间混音器，此 EQ 插入点也随之不存在。APAC 16／24 声道关闭空间化仍返回原有 `fmt?`（1718449215），没有修复或回避这一原生限制。

### AVPlayer 公开 tap 对照

普通轨道 `MTAudioProcessingTap.PostEffects` 在本轮分别拿到 5.1 PCM 的 6 声道、APAC 的 16／24 声道和 Atmos 样本的 12 声道，之后仍有空间混音器输出双声道。因此普通轨道的 PostEffects 不是这里的最终双耳输出。探针只观察这些多声道格式，没有给它们运行双声道 EQ；这些计数也不足以证明对象元数据或渲染完全不变。关闭空间化的普通立体声轨道 tap 已独立验证 EQ 传入 HAL。

macOS 27 的 `AVAudioMixInputParametersTrackMixID` 配合 `MTAudioProcessingTapCreateWithPreferredFormat`，请求双声道 PCM 并使用 PostEffects，则确实能拿到空间渲染之后、播放器音量之后的数据。在同帧数测量窗口中，tap 输入电平等于空间混音器输出乘以 0.02；该对应关系覆盖多个时段和两耳。APAC 16／24、Atmos、5.1 的空间化开启用例，以及普通立体声／5.1 的空间化关闭用例均测到双声道；稳定信号的 EQ／增益变化也到达 HAL。

但混合总线 tap 改变了调度：最终 5.1 对照中，空间混音器和 tap 每次处理 **4096 帧**（48 kHz 下约 **85.33 ms**），HAL 仍为 512 帧。现有头追在每次空间混音器 PreRender 更新，因此不能将这条路线视为与原路径具有相同头追时序；帧块时长不等于已经测得的总延迟。

首次 5.1 混合总线探测还出现过一次异常：空间混音器观察器只收到 32 次回调，后续输出电平降至约 1e-9。复测没有重现，原因尚未定位，可能来自实验接法或运行时状态，不能归因为已确认的系统缺陷。最初报告被复测覆盖，本条保留的是当次终端观察记录；当前 JSON 是复测结果。对这条路线的结论仅为当前运行下的功能验证，尚未完成稳定性和头追延迟验收。

### 产物与结论边界

- 源码：`eq_probe.h`、`eq_probe_shim.c`、`eq_probe.m`、`eq_probe_build.sh`、`eq_probe_test.py`；构建仅产生约 116 KiB 的探针二进制／动态库。
- 本机结果：`Tests/Artifacts/eq-probe/*-notify.json`、`*-tap-*.json` 与 `summary.json`。合计 23 个场景：9 个基本处理／覆盖验证，6 个混合总线当前运行验证，2 个预期原生 APAC 格式失败，6 个普通多声道 tap 格式／路由观察。不是 23 个 EQ 功能全部通过。
- 测量快照在播放结束后冻结，报告写入不在实时回调内。精确频响使用稳定信号，音乐只用于格式、原样衰减、返回缓冲区和姿态检查。
- 当前含头追的空间播放优先采用原有空间混音器 PostRender 位置。若要求普通播放也有 EQ，需要补充非空间化路径；新的混合总线 tap 可作为备选，但须先评估上述批次变化和异常。
- 本轮未覆盖其他采样率、USB／蓝牙／AirPods、设备热切换、EQ 参数平滑、静音尾音与跳转重置。探针不是可直接交付的产品 DSP 实现；正式播放器仍未加入 EQ。

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

## 已知限制

- 两个用户 APAC 文件在明确关闭空间化时，AVPlayer 返回 AVFoundation `-11800`、底层 OSStatus `1718449215`（`fmt?`）。这一现象也在原始最小播放器中复现。应用显示可恢复错误并保留进度；切回自动／强制模式可继续，未静默忽略关闭设置。
- `spen`／`spmd` 属于系统私有实现细节，后续 macOS 版本需要重新验证。
