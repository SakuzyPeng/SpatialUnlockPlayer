# 个性化 HRTF 与系统默认输出

2026-10-24，macOS 27.0.1（26A434），Apple Silicon，AirPods Max／FIIO KA11。

**已加入进程内强制加载：显式选择“个性化”时，播放器补上 Apple 个人 HRIR 加载器检查的设备能力，使其能使用系统已有档案。AirPods 完全离线、系统默认为 FIIO 时，实际个性化为 1，空间 PCM 与正常个性化参考逐样本一致。系统决定、通用及未应用路径保持原行为；缺少可用档案时仍如实回退通用。**

修复前，公开的个性化请求受到系统默认输出的限制：同一 FIIO 实际播放路径，仅切换默认 AirPods → FIIO → AirPods，实际个性化为 1 → 0 → 1。下面先记录这个基线，再记录强制加载的验证。

## 现象与直接证据

用户在 FIIO 耳机空间渲染路径选择“个性化”，界面显示“已请求个性化 · 当前使用通用 HRTF”。运行中播放器的系统日志明确记录：

> Personalized HRIR type 1 is disabled. Reverting back to generic HRIR.

同一混音器的模式写入日志为 `personalized HRTF mode = 1`。这与应用区分请求模式（属性 3113）和实际状态（属性 3116）的实现一致。

独立于播放器及兼容层创建 Apple AUSpatialMixer，设置耳机输出、`UseOutputType` 算法；分别在初始化前、初始化后请求个性化，实际渲染、运行事件循环并重试。系统默认 FIIO 时，各次写入成功、请求模式读回为 1，但实际状态持续为 0；恢复默认 AirPods 后，各种设置时序都得到实际状态 1。两种默认输出下，AirPods 均在线。因此现象不能归因于单纯未连接、初始化时机或界面状态刷新。

## 固定 FIIO 的受控对照

再以独立 AVPlayer 复用正式兼容层和高级配置模块，始终显式指定 FIIO 输出，使用同一高峰值 5.1 文件、相同个性化请求。播放器音量设为 0，仍确认空间渲染回调运行，未输出测试声音。每次创建新的播放链，只改变系统默认输出。

| Mac 系统默认输出 | AVPlayer 实际目标 | 请求模式／错误码 | 实际个性化 | 空间渲染回调 |
|---|---|---|---:|---:|
| AirPods Max | FIIO KA11 | 1／0 | 1 | 272 |
| FIIO KA11 | FIIO KA11 | 1／0 | 0 | 274 |
| AirPods Max，再次验证 | FIIO KA11 | 1／0 | 1 | 272 |

三次播放均就绪，只有一个耳机空间混音器，无播放或 HRTF 设置错误。结束后恢复测试前的系统默认输出。未改写个性化档案、播放器偏好或产品源码。

本机证据保存在被 Git 忽略的 `Artifacts/hrtf-availability/`：

- `same-fiio-different-system-default.json`：上述三次 AVPlayer 对照。
- `connected-default-fiio.log`：AirPods 在线、默认 FIIO 时的独立混音器结果。
- `connected-default-restored.log`：恢复默认 AirPods 后的独立混音器结果。

## 进程内强制加载及回退验证

追踪独立测试进程中的 CoreAudio 查询，确认 `IR::PersonalizedIRData::Implementation::CheckSupport` 先检查系统默认设备是否具有 `hrfa` 属性，再读取其 UInt32 值。普通输出缺少该属性，单独覆盖读取函数不足以改变结果。

实现复用现有的 `AudioObjectHasProperty`、`AudioObjectGetPropertyDataSize`、`AudioObjectGetPropertyData` 拦截，仅在有效播放设备、允许耳机空间渲染且用户显式选择个性化时，为进程内的全局主元素 `hrfa` 查询提供能力值 1。该开关为单个原子值，在播放链创建前发布；音频回调未增加分配、文件访问或等待锁，也未重复拦截系统函数。原生设备查询绕过仍有效，属性 3116 的实际反馈未被覆盖。

系统档案仍由 Apple 的数据加载器提供，没有写全局偏好或提取、复制个人档案。以下均使用同一高峰值 5.1、同一朝向和处理余量；播放器音量为 0，只比较音量之前的空间混音器 PCM。

| 完成的对照 | 实际个性化 | 空间 PCM |
|---|---:|---|
| 正常参考：默认 AirPods、实际 FIIO、请求个性化 | 1 | 参考 |
| 基线：默认 FIIO、仅公开 On 请求 | 0 | 与个人参考不同 |
| 进程内强制：默认 FIIO、请求个性化 | 1 | 与个人参考逐样本一致 |
| AirPods 完全离线，冷启动强制测试进程 | 1 | 314,560 帧与个人参考逐样本一致 |
| 正式模块，AirPods 离线，个性化 | 1 | 314,560 帧与个人参考逐样本一致 |
| 正式模块，通用／系统决定 | 0 | 各 314,560 帧与原始通用参考逐样本一致 |
| 测试替身向加载器提供空档案列表，个性化请求 | 0 | 与原始通用参考逐样本一致，无渲染错误 |

正式 Diagnostics 应用另完成 42 步无声流程：同一进程中个性化 → 通用 → 系统决定 → 个性化、关闭／开启空间音频、EQ 共存、7.3 dB 余量、切歌、暂停定位和恢复系统设置均通过。纯 C 控制测试增加能力开关、原生查询绕过、UInt32 缓冲区边界及失效状态的检查。

PCM 指标位于 `Artifacts/hrtf-availability/pcm/force-summary.json`，应用流程位于 `app-transitions-result.json`。应用流程可通过 `python3 Tests/hrtf_personalization_test.py --output DEVICE_UID --require-no-native` 复测。

## 当前操作方式

1. 在 SpatialUnlock Player 中选择 FIIO，或让“系统默认”实际指向 FIIO。
2. 在该设备的高级设置中选择“个性化”。
3. 播放后确认状态显示“当前使用个性化 HRTF”。Mac 需已有可用个人档案，AirPods 无需在线或作为默认输出。

未包含本次修复的旧构建，可临时保留系统默认 AirPods、在应用内明确选择 FIIO；这是原始公开请求路径的替代操作方式。

这个结果说明个人档案仍然存在并能被使用，同时明确了“全局已有档案”与“当前渲染实例能使用该档案”的区别。此前空间混音器／HAL 相同的实验均读取了实际 HRTF 状态，结论仍然成立；不能把请求模式为 1 当作实际个性化已启用。此处只报告本机验证出的条件，不推断所有 macOS 版本或其他设备均有相同行为。
