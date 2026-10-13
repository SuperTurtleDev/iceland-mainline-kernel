# b2134c24：SSC sensor Claim/Release 可重复控制相机恢复与失败

Boot `b2134c24-9391-4d8e-8c24-05b2fd6355a1`，持续重复启动视频流，每轮收到一帧即关闭。
除明确标出的后续 boot `f910…` 对照外，以下时间均为 b213 的单调秒。
I2C 返回成功与采集脚本收到首帧分别记录，不能混用。

## 已确认结论

- 当前失败状态下，独立持有 SSC 传感器 claim 可恢复相机；释放后又再次失败。
  `ClaimLight` 两轮均阳性，后续 `ClaimAccelerometer` 也阳性，因此证据已从 ALS
  收窄为 SSC sensor claim 的共同资源或 ADSP/SSC 生命周期；尚未定位具体硬件资源。
- 0us CPU latency QoS 生效时仍发生首错，CPU 深 idle/RPMh flush 不是必要条件。
- 故障在同一 boot 内至少三次恢复，不属于此 boot 内永久不可恢复的状态。
- 两次物理显示唤醒后，第一笔 I2C 尝试已经成功；随后约 6s 的无帧超时及脚本间隔
  使首帧时间晚于总线恢复，不能把约 8s 的首帧延迟解释成硬件恢复延迟。
- 单独 DPMS on 未恢复；后续 GDM restart 后恢复。GDM 生命周期与故障相关，尚未
  确定其具体哪个资源操作构成原因。
- 一次受控 DPMS off 关闭 L12B/L3D 后仍能连续成功采集，故不能把显示断电或这两轨
  的关闭单独认定为充分触发条件。

## 独立 SSC sensor Claim/Release 对照

基线为持续 I2C NACK。现场脚本 `/tmp/sensor-claim-test.py` 对 Light 使用同一条
持久 Gio 系统 D-Bus 连接，连续执行两轮 `ClaimLight`、保持 15s、`ReleaseLight`、
观察 5s。期间未操作 GDM、DPMS、背光或相机供电配置。

| 单调秒 | 操作 | 随后观察 |
| ---: | --- | --- |
| 5390.005070 | 第一轮发起 `ClaimLight` | 5390.185091 方法返回 |
| 5390.185091 起保持 15s | 保持 ALS claim | 成功 33 帧，另 1 轮无帧超时 |
| 5405.185703 / 5405.193734 | 第一轮 `ReleaseLight` 开始 / 返回 | 随后 5s 内先成功 5 帧，再失败 4 轮 |
| 5410.194503 / 5410.374167 | 第二轮 `ClaimLight` 开始 / 返回 | 保持期间成功 32 帧，另 1 轮无帧超时 |
| 5425.374848 / 5425.378957 | 第二轮 `ReleaseLight` 开始 / 返回 | 随后 5s 内先成功 5 帧，再失败 4 轮 |

时间与计数已用 `/tmp/iceland-b213-als/5387-5433.trace` 核对；表中方法时间取
脚本 JSON 的 `monotonic`，trace marker 写入比该值略晚，不混为同一时刻。

| I2C / 收帧边界 | 第一轮 | 第二轮 |
| --- | ---: | ---: |
| claim 前末笔 I2C 失败 | 5389.296765 | 5409.656021 |
| claim 后首笔 I2C 成功 | 5390.415416 | 5410.774825 |
| 首轮采集以 rc=124 结束 | 5396.508249 | 5416.867280 |
| 下一轮首帧 | 5397.683969 | 5418.025544 |
| release 后末笔 I2C 成功 | 5406.105911 | 5426.392463 |
| release 后首笔 I2C 失败 | 5406.242874 | 5426.395139 |
| release 返回到首错 | 1.049140s | 1.016182s |

第一轮首错为 `0x0103=1`，第二轮首错为模式表中的 `0x3905=0x8d`；前笔
`0x3903=0xa0` 刚在 2.676ms 前成功。因此该现象不依赖固定某个 sensor 寄存器触发。
每轮 held 阶段的 1 次 failure 都是已恢复 I2C 后的 6s 无帧超时，不能算作 NACK。

整段没有 display-subsystem 状态变化、背光寄存器写、L12B/L3D 开关。两次
Claim/Release 到总线变化的窗口内没有相机 rail/reset 开关；第一轮 release 后
5405.568147s 有 UFS L4G disable，第二轮 release 到首错则没有任何 regulator/GPIO
切换。因此不能把相机恢复/失败归因于同窗的 AP 显示或相机供电切换，也不能仅凭
AP trace 未见动作而否定 SSC 固件内部的资源变化。

结果证明在当前条件下，单独控制 ALS claim 足以改变相机的成功/失败状态，
不需要把 GDM 或显示重启作为干预。release 后仍有短暂成功窗口，不能把 D-Bus
返回时间等同于硬件状态变化时间。

后续 boot `f910…` 中，route 已恢复且 PipeWire 已停止的对照使用
`ClaimAccelerometer`：约 719.229s
发起、719.413s 返回，保持 15s 得 33 帧（另 1 次超时）；734.414s release 后
观察 5s 得 10 帧、3 次失败。随后 Light 约 742.502s claim，保持 15s 得 31 帧
（另 1 次超时）；757.680s release 后再次失败。此前因 EPIPE 的 accel 对照不纳入
阴性证据。该结果说明共同资源优先级应高于 ALS 特异机制，仍需重复对照。

源码支持上述操作确实启停 SSC 传感器：iio-sensor-proxy 按 D-Bus unique sender
计数，首个 claim 调用 `driver_set_polling(TRUE)`，最后一个 release 或连接消失
调用 `driver_set_polling(FALSE)`；SSC light 后端分别调用 libssc 的 light open/close。
libssc v0.4.4 的 close 发出 SSC disable-report 消息 10，open 发出 enable 消息
513/514，经 protobuf/QMI/QRTR 交给 SSC。

因此需要继续区分 ADSP/SSC 的电源、时钟、总线或固件资源动作；当前不能直接声称
某条物理电源已被证实是根因。独立 accel/light 共同性与 PMIC 硬件读回由现场继续验证。

GNOME 源码解释了此前两种显示操作的区别：GSD 按自己的 `screen_blanked` 与 session
active 状态决定 ALS claim；手工写 Mutter `PowerSaveMode` 不会反向更新这个字段。
所以正常熄屏/唤醒会伴随 ALS release/claim，而手工 DPMS off 可以在关闭显示轨时
仍保持 ALS，手工 DPMS on 也可以在点亮屏幕时仍不持有 ALS。Mutter 的加速度计
inhibitor 则直接跟随 DPMS，需与 ALS 分开验证。源码证据与最小实验方法另存
`/tmp/iceland-ssc-claim-source-notes.md`。

## 数据来源

- 首错归档：`/tmp/iceland-cpuqos-b2134c24/`，含 `window.trace`、`journal.log`、
  `timeline.log`、`cpu-latency-hold.log`、快照与 cmd-db。
- 两次恢复及再次失败：`/tmp/iceland-b213-recovery-windows/` 下的
  `2347-2362.trace`、`2419-2427.trace`、`2499-2514.trace`、`2529-2537.trace`。
- 第一次手动 DPMS on：`/tmp/iceland-display-on-4123.trace`。
- 后续受控 DPMS/GDM 对照：`/tmp/iceland-b213-controlled.tar.gz`，已通过 `gzip -t`，
  解包至 `/tmp/iceland-b213-controlled/`，含 `4342-4364.trace`、`4442-4451.trace`、
  `4513-4524.trace`。4258s 的第二次 DPMS on 及 4477.94s 的观察点来自现场记录，
  不在这三个 trace 片段内。
- 两轮独立 ALS 对照：`/tmp/iceland-b213-als/5387-5433.trace`，包含脚本 JSON marker、
  I2C 返回、收帧与电源事件。后续 boot `f910…` 的 accel/light 数据目前来自现场记录，
  不与 b213 trace 的单调时钟拼接。

## 0us QoS 下首次失败

`cpu-latency-hold.log` 记录 `CPU_LATENCY_HOLD_RESULT value_us=0 uptime=3.35`；
timeline 对应标记为 3.363410s。首错窗口内没有 `psci_domain_idle_enter` 或
`rpmh_flush_enter` 事件。QoS 排除了此次故障需要这类 CPU 深 idle/flush 的解释，
不代表停止了其他设备的 runtime PM 或 RPMh 投票。

| 单调秒 | 事件 |
| ---: | --- |
| 320.684051 | 显示 L12B disable |
| 320.726799 | 显示 L3D disable |
| 320.727635 | display-subsystem 进入 RPM_SUSPENDED |
| 321.537687 | 最后成功的 I2C，传感器停流 `0x0100=0` |
| 321.673062 | 下一轮开始写 `0x0103=1` |
| 321.673879 | 首个 I2C `-5`，成功到失败间隔 136.192ms |

三次自然故障中，显示 subsystem suspend 到首错分别相隔 0.946244s、0.825212s、
0.922384s；这种相关性不能覆盖后面的受控 DPMS off 反例。
第一次首错前 7.93ms 有 UFS L4G disable，但两次重复故障不具有相同近邻动作，
不能据此把 UFS 关闭认定为共同触发条件。

## 两次恢复与重复失败

| 事件 | 第一次恢复 | 第二次恢复 |
| --- | ---: | ---: |
| 最后一次 I2C `-5` | 2349.438835 | 2501.577839 |
| display-subsystem 开始 resume | 2349.485106 | 2501.663508 |
| L3D enable | 2349.488986 | 2501.666797 |
| L12B enable | 2349.534051 | 2501.710094 |
| journal 的 power-button short press | 2349.725176 | 2501.814983 |
| 首笔成功的 `0x0103=1` | 2350.550779 | 2502.694318 |
| 同轮成功写 `0x0100=1` | 2350.600778 | 2502.745898 |
| 等待一帧超时后成功停流 | 2356.545698 | 2508.684779 |
| 下一轮收到首帧 | 2357.811762 | 2509.934104 |
| 后续显示 subsystem suspend | 2422.579435 | 2532.114050 |
| 再次出现 I2C `-5` | 2423.404647 | 2533.036434 |

第一轮恢复后的超时尝试为 attempt 3172，下一轮 3173 收到首帧；第二次分别为
attempt 3528 与 3529。两次恢复后的超时不能判为 I2C 仍然失败。
第一次超时之后传感器发生一次供电/reset 周期，第二次则没有，因此该周期不是
这两次 I2C 恢复的共同前提。

第二次 SSH 服务到 2510.923932s 才开始监听，登录认证在 2511.564123s，用户
PipeWire/WirePlumber 分别在 2512.294337s / 2512.300331s 启动；均晚于总线恢复，
也晚于首帧。第一次恢复没有相邻 SSH 登录。这两次恢复不能归因于 SSH/PipeWire 启动。

## 手动 DPMS 与 GDM 对照

| 单调秒 | 操作与结果 |
| ---: | --- |
| 4123.464829 | 手动 DPMS on，display-subsystem resume |
| 4123.511082 | L12B enable，面板 reset 随后按高/低/高序列完成 |
| 4123.826358 | 亮屏后 SE9 第一次尝试仍 `-5` |
| 4162.337887 | 亮屏 trace 中末笔 SE9 仍 `-5`；全片段共 38 次尝试均失败 |
| 约 4258 | 第二次仅 DPMS on 对照，仍失败 |
| 4345.101363 | `GDM_RESTART_DISPLAY_TEST_BEGIN` |
| 4347.164841 | `GDM_RESTART_DISPLAY_TEST_END` |
| 4347.924838 | restart 后末笔 I2C `-5` |
| 4349.048794 | 首笔 I2C 恢复，`0x0103=1` 成功 |
| 4356.291574 | 后续首帧 |
| 4444.266680 | `HEALTHY_DISPLAY_OFF_CONTROL_BEGIN` |
| 4444.435133 | L12B disable |
| 4444.477401 | L3D disable |
| 4444.478306 | display-subsystem 进入 RPM_SUSPENDED |
| 至少至 4477.94 | 关屏后仍连续采集成功 |
| 4515.356811 | `STOP_GDM_ALREADY_DISPLAY_OFF_BEGIN` |
| 4516.217718 | stop GDM 之后仍收到一帧 |
| 4516.400958 | 最后成功的 I2C，`0x3e02=0` |
| 4516.400971 | 同轮开始写 `0x3e08=0` |
| 4516.401991 | 该写入返回 `-5`，距前笔成功仅 1.033ms |
| 4520.278784 | `STOP_GDM_ALREADY_DISPLAY_OFF_END` |
| 4520.287523 | display-subsystem 开始 resume |
| 4520.290812 / 4520.335091 | L3D / L12B 再次 enable |
| 4523.139476 | 新片段内末笔 I2C 仍 `-5` |

GDM restart 恢复片段 `4342-4364.trace` 内没有 L12B/L3D 的 enable/disable，
也没有 display-subsystem 状态变更。attempt 5454 在 4349.048794s 已恢复 I2C，
随后写 stream-on，却等不到帧；4355.143362s 以 rc=124 结束。下一轮 5455 在
4356.291574s 收帧，与前两次恢复一样，首帧延迟包含一次 6s 采集超时。

关屏片段 `4442-4451.trace` 记录 6471 笔成功 I2C、39 帧、零失败，片段末笔
I2C 成功时间为 4450.999833s。后续现场持续成功到至少 4477.94s；再后一个片段
`4513-4524.trace` 仍从正常采集开始，直到 stop GDM 之后才失败。

此次首错是同一轮配置/controls 写入中途的 `0x3e08=0`，既不是 `0x0103`，
也不是 stream-on/off 写入。最后成功至首错的 1.033ms 内没有 regulator/GPIO/clock
开关；CAMSS clock disable 从 4516.402044s 才开始，属于失败后的清理，不能倒置因果。
停 GDM 返回后显示反而恢复且两轨上电，但 I2C 仍失败，再次表明亮屏不能保证恢复。

第一次手动亮屏与两次成功唤醒均有 DPU、DSI、面板 reset、背光 I2C、触控 SPI
以及相关 clocks/runtime PM 动作；未发现两次成功唤醒都具有、而手动亮屏缺少的
上述事件类型。一个具体差异是背光寄存器：成功唤醒从亮度 1256 进一步更新到约
1920，再继续变化；第一次手动亮屏仅写入 1256，至少到 trace 末尾 4162.995511s 未再更新。
这只是候选差异，尚不能证明背光亮度有因果作用。

受控关屏后持续成功、而随后 stop GDM 又失败，将“面板 off”与“GDM 退出”区分开来。
后续独立 SSC sensor Claim/Release 对照进一步隔离出传感器消费者生命周期；仍不能据此
认定某条电源轨、GPU、DPU 或相机传感器时序是底层根因。

## 解释边界

- QoS 结论仅针对已验证被阻止的深 idle/flush 路径，不能外推为所有低功耗行为均已排除。
- “同 boot 可以恢复”纠正的是永久楔死的推断，不否认历史上一次控制器解绑重绑无效，
  也不证明任意暖重启必然恢复。
- 缺少某个 trace 事件只能在采集覆盖和完整性范围内解释；软件 enabled/voltage 缓存
  不能替代电源轨的硬件读回或电气测量。
