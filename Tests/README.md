# 验证与回归

产品没有测试依赖。开发验证使用本机现有 Python、ffmpeg 和测试媒体；不复制用户的音乐文件。

## 高级空间音频设置

```sh
zsh Tests/advanced_audio_test.sh
zsh Tests/route_probe_build.sh
python3 Tests/advanced_pcm_test.py --reuse
python3 Tests/advanced_app_test.py
```

第一条验证真实 AudioUnit 生命周期、连接拓扑识别、0–20 dB 配置、回退及静音保护、旧代次隔离和并发原生参数写入，同时验证按 UID 保存、数值校验及拖动跨设备取消。控制与故障测试使用公开 Apple EQ 作为节点夹具；私有 DSP 的实际行为由第二／三条的真实 AVPlayer／HAL 采集验证。`--reuse` 仅复用已保存且通过数据完整性检查的捕获。

PCM 测试需要本机已有素材、AirPods 和 FIIO 输出，检查 0／5／10／15／20／7.3 dB、高低电平、Atmos、APAC 16、EQ 与固定 45° 朝向，以及两项系统决定时输出不变。`route_comparison.py --production` 使用正式拓扑配置模块；未指定时仍可使用早期研究控制作为参考。

应用测试使用 Diagnostics 构建及独立 Regression 偏好域，覆盖两台输出设备、切换／暂停定位、重启、系统默认输出别名、恢复系统设置和 EQ 共存。`--app`、`--fiio`、`--airpods` 可指定当前实际路径／UID。与真实 PoseBridge 同时验证可运行：

```sh
python3 Tests/posebridge_integration_test.py --output DEVICE_UID \
  --eq 'Tests/Fixtures/Sony MDR-MV1 ParametricEq.txt' --headroom 7.3
```

Diagnostics 的 `advancedHeadroomMode`、`advancedHeadroomDB`、`advancedHRTF`、`advancedReset` 对应正式界面操作。独立界面检查可设置 `SPATIALUNLOCKPLAYER_TEST_KEEP_OPEN=1` 和 `SPATIALUNLOCKPLAYER_TEST_LIVE_STATE`：后者只在 Diagnostics 主线程写入当前状态，Release 不包含该入口。

## 正式参数 EQ

```sh
zsh Tests/equalizer_test.sh
python3 Tests/equalizer_playback_test.py
python3 Tests/posebridge_integration_test.py --eq 'Tests/Fixtures/Sony MDR-MV1 ParametricEq.txt'
```

首条运行配置解析／事务性导入／持久化测试，并使用本机已有 NumPy 分析正式 C DSP 的脉冲响应。参考使用独立的模拟原型加双线性变换，不复用产品 biquad 递推；覆盖 44.1／48／96 kHz、PK／LSC／HSC／完整 Sony 曲线、两种 PCM 布局、声道隔离、重复渲染、reset、静音尾音、整体旁路、20 ms 淡化、快速更新和并发配置／实例生命周期。

第二条须先构建 Diagnostics 并具备已有测试媒体；使用前一条由正式 Swift 解析器生成的 Sony 参数，验证正常链接的正式 EQ 处理能到达本进程 HAL 输出，随后运行实际应用的 EQ 开关、定位、切歌、模式、设备恢复、导入失败和重启恢复场景。第三条用真实 PoseBridge 模拟器验证 EQ 与外部头追同时工作，关闭外部头追后 EQ 继续生效；结果单独写入 `Artifacts/posebridge-integration-eq`。

结果保存于 `Artifacts/equalizer`。应用集成测试共用独立 Regression 偏好域，与其他播放、持久化、PoseBridge 脚本须顺序运行；测试不改变日常列表和 EQ 设置。纯 DSP 检查和 Xcode 构建复用已有目录／共享模块缓存。

## EQ 接入点探针

```sh
python3 Tests/eq_probe_test.py
python3 Tests/eq_probe_test.py --analyze-only
```

这是独立的命令行 AVPlayer 实验，不构建／替换应用，不读写播放器偏好，不改变系统默认输出。默认指定普通 3.5 mm 耳机；可传 `--output DEVICE_UID`。`build/tests/eq-probe/eq-probe --devices` 可列出当前输出。播放音量为 2%，会短暂播放测试信号和本机已有音乐。

探针复用正式 `SpatialShim.c` 和 `HeadPose.c`，只在测试动态库中扩展渲染观察器，并观察本进程的 HAL 输出回调；不注入正在运行的播放器。依次测量旁路、−6.02 dB 增益、1800 Hz／Q=1／−12 dB 峰值 EQ，以及保持 EQ 时的 +45° 姿态。实时回调不写文件，结束后保存数值谱分析。滤波器仅支持本轮双声道 Float32，普通多声道 tap 的 `unsupported` 表示探针没有处理该格式，不表示 AVPlayer 不支持它。

用 `--only pcm51-on-notify` 等名称选择场景，`--skip-build` 复用小型探针二进制。生成或复用短 PCM，不复制 APAC／Atmos；音乐路径从已有 `Artifacts/smoke.json` 和 `regression.json` 读取，缺少这些本机素材时跳过对应场景。所有生成物位于 `build/tests/eq-probe` 与 `Artifacts/eq-probe`。

`summary.json` 区分处理验证、已知格式失败和仅观察格式的场景，不能把整个场景数称为 EQ 全部通过。多声道音乐跨时间片的响度不同，不使用它们的前后时段电平差证明滤波频响；精确频响和 HAL 传递验证使用稳定测试信号。详细结论及混合总线 tap 的头追限制见 [验证记录](VALIDATION.md)。

## AirPods 与普通耳机 PCM 对照

`zsh Tests/route_probe_build.sh` 构建独立抓取工具；`build/tests/route-probe/route-probe --devices` 列出当前输出。使用 `python3 Tests/route_comparison.py capture LABEL DEVICE_UID native|shim` 分别抓取原生和兼容路径，再用 `compare LABEL_A LABEL_B` 比较空间混音器 PCM；加 `--stage hal-output` 比较本进程 HAL 输出。Python 分析需要 NumPy 和 SciPy。

实验保留系统个性化设置，禁用测试进程的 EQ，固定朝向，播放器音量为 2%。`--hrtf 0/1/2` 只改变测试混音器实例的模式；必须同时检查报告中的 `personalizedActive`。采集会播放低音量测试声音，不录制输入，PCM 仅在播放停止后写盘。详细步骤与已完成对照的结果见 [输出对照实验](ROUTE_COMPARISON.md)。

`--trace-units` 增加中间 Apple AudioUnit 的只读观察；`--headroom-db 0|20` 仅在测试进程中控制动态处理前后的两项 PreGain，用于因果对照，并自动启用逐级观察。已有本机数据可用 `python3 Tests/hal_chain_analysis.py` 重新验证：观察器不改变输出，交换两项参数可以逐位交换 HAL 结果。

## PoseBridge OSC 与渲染

在仓库根目录运行纯协议与实际 Apple Audio Unit 检查：

```sh
zsh Tests/head_tracking_test.sh
```

协议测试覆盖 OSC 3 长度／类型／UTF-8／数值检查、YXZ 到物理旋转转换、回正、源年龄、重复包、状态心跳、旧实例／会话／参考拒绝及重连连续性。C 测试使用真正的 AUSpatialMixer 离线渲染，无需耳机或 PoseBridge 进程；验证无系统头追回调时主动应用姿态、双声道 PCM 差异、原生朝向恢复、并发快照和初始化／销毁生命周期。

构建 Diagnostics 后，可使用现有 PoseBridge CLI 做端到端测试：

```sh
python3 Tests/posebridge_integration_test.py \
  --posebridge /path/to/PoseBridge/target/release/posebridge
```

默认使用 `build/Products/Diagnostics/SpatialUnlock Player.app` 和普通 3.5 mm 耳机输出；可通过 `--app` 和 `--output DEVICE_UID` 指定。测试播放低音量自生成 5.1 信号，分别运行真实 PoseBridge 的 quaternion/euler 模拟器，验证接收、无效 UDP 数据、回正、空间模式切换、关闭恢复、同端口重启、终态冻结与端口占用错误。运行时不使用 `DYLD_INSERT_LIBRARIES`；采集与结果保存在 `Artifacts/posebridge-integration`，不修改日常偏好。

未用这套自动测试代替实体传感器安装方向、USB/BLE 传输延迟或人的转头听感验收。

应用与动态库 target 由根目录的 `project.yml` 管理。`build.sh --diagnostics` 会生成 Xcode 工程，以 Diagnostics 配置构建并导出根目录应用；Xcode 中也可选择 `SpatialUnlockPlayer-Diagnostics` scheme。手动在 Xcode 构建时，产物位于 `build/Products/Diagnostics`；下面命令和持久化脚本使用 `build.sh` 导出的根目录应用。

## 原子配置与正常链接

先构建应用，再编译 C 检查程序。把下面最后的编号替换为当前测试输出的 AudioObjectID；不要复用旧编号。

```sh
/usr/bin/clang -O1 Tests/shim_test.c \
  -L "SpatialUnlock Player.app/Contents/Frameworks" -lSpatialShim -framework CoreAudio \
  "-Wl,-rpath,@executable_path/../SpatialUnlock Player.app/Contents/Frameworks" \
  -o build/shim-test
env -u DYLD_INSERT_LIBRARIES ./build/shim-test DEVICE_ID
```

检查正常链接下的 interpose、原始能力查询绕过、UInt32 数据大小、越界写保护以及停用后恢复原始查询。

## 应用内回归

`Artifacts/*.json` 保存本机使用的场景和实际结果；生成媒体和运行记录不属于产品资源。

```sh
zsh build.sh --diagnostics
env -u DYLD_INSERT_LIBRARIES \
  SPATIALUNLOCKPLAYER_TEST_SCRIPT="$PWD/Tests/Artifacts/smoke.json" \
  SPATIALUNLOCKPLAYER_TEST_RESULT="$PWD/Tests/Artifacts/smoke-result.json" \
  "./SpatialUnlock Player.app/Contents/MacOS/SpatialUnlockPlayer"
```

测试脚本使用独立 UserDefaults 域，完成后退出。结果文件的 `passed` 字段才是通过依据；应用退出码不是测试判定。

- `smoke.json`：16 声道 APAC、定位、关闭不兼容的错误恢复、自动空间化。
- `regression.json`：24 声道 APAC、Atmos、5.1 PCM、视频、快速模式切换、输出不可用、错误文件、增删和连续播放。
- `available-routes.json`：在暂停状态切到内置扬声器，再回到 3.5 mm，验证位置与状态保持。
- `apac24-off.json`：24 声道 APAC 关闭空间化的错误提示与恢复。
- `disconnect-drop.json`：真实 NSItemProvider 导入链路、设备目录移除模拟、重新连接后保持暂停，以及快速切换文件。设备移除模拟只改变测试构建里的目录快照，不改变系统设备。
- `native-route.json`：原生兼容耳机回归。运行前必须将脚本的目标替换为当前真实设备 UID，并确认设备仍可用；不能假定“系统默认”始终是 AirPods。

在当前系统上，多声道 APAC 的关闭空间化失败是原生 AVPlayer 的格式限制；测试验证应用明确报告错误并能恢复，而非要求静默回退。

## 播放列表持久化

纯 Swift 顺序决策与会话测试无需播放设备：

```sh
zsh Tests/playback_test.sh
```

覆盖顺序／列表循环／单曲循环的边界、空列表与单项列表、随机每轮完整性与轮次交界、历史回退与前进、增删条目、v1 迁移、v2 保存及无效引用修复。使用可控的打乱函数，编译复用系统模块缓存。

在诊断构建完成后运行：

```sh
python3 Tests/persistence_test.py
python3 Tests/playback_integration_test.py
```

持久化脚本使用已有视频、短 PCM 测试素材及本机 APAC 文件，通过多个独立进程验证旧单列表迁移、列表顺序、重复文件、当前曲目、暂停位置、移除、文件暂时不可用，以及多列表、空列表、名称和全局播放模式恢复。清空后仍保留列表身份和名称；删除最后一份列表会留下空的“默认列表”。

播放集成脚本使用实际 AVPlayer 验证自然结束后的四种模式、随机历史、浏览其他列表时自动续播、NSItemProvider 导入期间切换列表、快速切换后的旧回调拒绝、删除列表及失败后暂停。复用小型视频和短音频，不复制用户音乐。两个脚本均使用独立的 `local.sakuzy.SpatialUnlockPlayer.Regression` 偏好域，须顺序运行，不改动日常使用的列表和设置。

首次启动清空测试偏好，后续测试用 `SPATIALUNLOCKPLAYER_TEST_RESTORE_SESSION=1` 保留上一进程保存的状态。每次启动的脚本、结果与日志保存在 `Artifacts/persistence-*`。

Diagnostics 保留原有 `mode` 空间音频操作，新增 `playbackMode`（`sequential`／`repeatAll`／`repeatOne`／`shuffle`）、`createPlaylist`、`renamePlaylist`、`deletePlaylist` 和按索引选浏览列表的 `browsePlaylist`。`finish` 定位到结尾附近并等待真实完播通知；`awaitState` 等待指定快照字段匹配。`playlistCount` 表示浏览列表的条目数，`playingPlaylistCount` 表示正在播放列表的条目数，`listCount` 表示列表数量。

## 界面检查

使用真实窗口验证打开面板、Finder 打开事件、多文件加入、列表双击／移除、视频画面、全屏、进度条、音量、模式与输出菜单。源码中的测试入口不替代这些 UI 检查。

USB DAC 可用时，可以复用前期 USB 抓包流程验证最终 PCM。模拟 3.5 mm 输出的本轮验收依据为软件播放链路和诊断，不宣称完成了模拟端硬件录波。
