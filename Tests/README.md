# 验证与回归

产品没有测试依赖。开发验证使用本机现有 Python、ffmpeg 和测试媒体；不复制用户的音乐文件。

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

在诊断构建完成后运行：

```sh
python3 Tests/persistence_test.py
```

该脚本使用已有视频、短 PCM 测试素材及本机 APAC 文件，连续启动 6 次应用，验证列表顺序、重复文件、当前曲目、暂停位置、移除、文件暂时不可用，以及清空后不再恢复。通过独立的 `local.sakuzy.SpatialUnlockPlayer.Regression` 偏好域运行，不改动日常使用的列表和设置。

首次启动清空测试偏好，后续测试用 `SPATIALUNLOCKPLAYER_TEST_RESTORE_SESSION=1` 保留上一进程保存的状态。每次启动的脚本、结果与日志保存在 `Artifacts/persistence-*`。

## 界面检查

使用真实窗口验证打开面板、Finder 打开事件、多文件加入、列表双击／移除、视频画面、全屏、进度条、音量、模式与输出菜单。源码中的测试入口不替代这些 UI 检查。

USB DAC 可用时，可以复用前期 USB 抓包流程验证最终 PCM。模拟 3.5 mm 输出的本轮验收依据为软件播放链路和诊断，不宣称完成了模拟端硬件录波。
