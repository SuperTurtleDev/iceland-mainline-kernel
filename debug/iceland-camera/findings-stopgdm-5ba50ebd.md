# `systemctl stop gdm` 最小复现

Boot `5ba50ebd-fa60-4b2a-8b33-05e1757e43df` 在 greeter 下连续采集单帧。
停止 GDM 前已成功 669 帧，监控完整性无丢失。原始归档为
`/tmp/iceland-stopgdm-5ba50ebd.tar.gz`，解包目录为
`/tmp/iceland-stopgdm-5ba50ebd-x/`。

## 时间线

| 单调秒 | 事件 |
| ---: | --- |
| 155.798652 | 写入 `STOP_GDM_TEST_BEGIN`，随后执行 `systemctl stop gdm` |
| 156.017905–156.704134 | 第 670–673 轮各成功一帧 |
| 156.798277 | 第 674 轮写 `0x0100=1` 成功 |
| 156.844812 | 第 674 轮收到一帧 |
| 156.845041 | 同一轮写 `0x0100=0` 开始 |
| 156.846944 | 该停流写返回 `-5`，GPI NACK；距 GDM 停止 1.048292s，距上次成功 48.667ms |
| 156.931515 | 采集脚本仍把第 674 轮记为收帧（停流错误被驱动路径吞掉） |
| 157.107334 | `systemctl stop gdm` 返回 |

因此首错是停流 `0x0100=0`，不是下一轮的 `0x0103` 软复位；
`0x0103` 不是必要触发点。PipeWire/WirePlumber 停止均在首错之后。

## 资源窗口

首错前没有 sensor rail、CAMSS clock/GDSC、MCLK 或 SE9 clock 切换。最近的动作是：

- UFS PHY 关闭、`vreg_l4g_0p9` disable：156.799225–156.799328；
- RPMh wake/sleep TCS flush：156.803921 起；
- CPU2 进入 `state=0x200c354`，对应 DT 的 domain idle state，最小驻留约 10.15ms。

同一 UFS/RPMh/CPU idle 序列在之前健康轮次出现，当时只能列为待隔离候选；
从停止 GDM 到首错，未观察到 `mmcx.lvl` (`0x30080`) 或 `xo.lvl` (`0x300e0`)
的发送事件，地址以本 boot 的 `cmd-db-initial.txt` 为准。
控制器解绑重绑后，前后摄 chip-id 仍返回 `-5`，只能说明此次解绑重绑没有恢复；
不能据此外推所有暖重置、暖重启或同 boot 内其他恢复路径均无效。

更精确地说，156.803909–156.825865 的 `state=0x200c354` 是 APSS/SS3 深度 Apps
power-collapse 边界，期间有 36 次 `rpmh_flush`；旧 `5be94a65` 与 `dcf91ae1` 的最近
同类 flush 分别早于首错 3.41 秒和 3.86 秒。它不是相机叶轨关闭证据，但使 CPU 深 idle
成为这次最小复现中当时待隔离的时序候选；后续 QoS 对照见下文。

## QoS 对照及后续修正

当时拟在下一次启动持有 `/dev/cpu_dma_latency` 的 0us QoS 请求，隔离 CPU 深 idle。
即使单次对照不再 NACK，也只能说明该次实验没有复现，不能证明 CPU/低功耗时序是
必要条件；还需要重复的开关对照和实际 idle/flush 覆盖验证。

后续 boot `b2134c24-9391-4d8e-8c24-05b2fd6355a1` 从 3.35s 起成功持有 0us QoS，
首错窗口没有 `psci_domain_idle_enter` 或 `rpmh_flush_enter`，仍在 321.673879s
首次 I2C `-5`。因此此类深 idle/flush 不是已观察故障的必要条件，不再作为本轮隔离方向。
同一 boot 随后两次在显示唤醒后恢复 I2C，证明至少存在无须重启的恢复路径。
精确边界及 DPMS/GDM 对照见 [findings-b2134c24.md](findings-b2134c24.md)。
