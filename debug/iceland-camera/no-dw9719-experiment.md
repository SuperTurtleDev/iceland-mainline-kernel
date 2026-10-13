# 禁用 dw9719 的隔离实验

## 改动与目的

2026-10-11，按用户要求排除 AF 驱动的传输和 runtime PM 路径。
仅修改 `linux/arch/arm64/boot/dts/qcom/kaanapali-oneplus-iceland.dts`：

- `camera_rear_vcm` 设置 `status = "disabled"`，从启动起不实例化 0-000c。
- 移除后摄 `lens-focus` 引用，避免 V4L2 子 notifier 永久等待已禁用的 AF，进而阻塞整个 CAMSS 媒体图完成。
- 保留后摄 `afvdd-supply`、sensor/AF 驱动代码和其它供电约束。

这是隔离补丁，不是已确认的修复。没有删除 jiggle 写，没有运行时 unbind；后者对 active AF 会调用 power_down 并发出 shutdown 写，不能实现零 AF 事务的对照。

## 对原推测的复核

`cci_write(..., NULL)` 仍经 regmap 发 I2C，也会进入 I2C trace；NULL 只取消错误累积指针。
原 boot 74d9351b 的 8.869675、8.870899 两笔 `@0c [02-00]` 都出现在 trace，直接反证“jiggle 不可见”。
该轮 77.024066 和 77.030526 的 AF 引用递减后分别为 2 和 1，没有归零。
76.930122–77.044448 临界窗口无 AF suspend/resume、@0c 传输或 L16B disable。
所以原时间线并未证实 AF 掉电/唤醒导致首败；首笔 sensor 写失败也不能单独证明 GPI 在发起它之前已经损坏。

## 禁用前的新基线

Boot ID：`830f93c0-80e4-4b15-a9ae-33cf7234b7f8`，内核仍是 `7.2.9-sm8850 #104`。
原始日志保留在设备 `/var/tmp/iceland-camera-watch/830f93c0-80e4-4b15-a9ae-33cf7234b7f8/`。
已下载前 25 秒 trace 至 `/tmp/iceland-af-baseline-830f93c0-first25s.trace`。

| 时间（开机秒） | 事件 |
| --- | --- |
| 9.743221 | 首败前最后一笔 AF @0c 写 |
| 9.743474 | AF ACTIVE |
| 17.768021 | AF 引用仍为 2 |
| 19.410140 | sensor 最后成功 I2C |
| 19.521926–19.522915 | sensor 首次失败，AF 在此窗口无 PM/I2C 动作 |
| 19.697352 | LPASS 开始关 MCLK，已在首败之后 |
| 20.028419 / 20.030461 | AF 引用降为 1 / 0，归零比首败晚约 508ms |
| 20.532078 / 20.533444 | sensor reset 拉低 / MCLK 关闭，已在首败之后 |
| 21.280833–21.280848 | AF 首次 suspend/停车写，传输失败，未走到撤 L16B |

这轮 AF suspend 错误是总线先失败后的现象。此轮前 25 秒 trace 未记录 DPU/DSI 事件，不能拿空白记录排除显示侧变化。

已核实设备包版本：gdm3 50.0-0ubuntu1、gnome-session-bin 50.0-0ubuntu3、gnome-shell 50.1-0ubuntu1、PipeWire 1.6.2-1ubuntu1、WirePlumber 0.5.13-1ubuntu1。
此前 GDM/gnome-session 50.1 上游源码审计与设备版本不同，不能视为已逐行核实设备实际执行代码。

## 构建与部署记录

完整 `./build.sh` 通过，总计 211 秒；包括 OOT charge_boost、四个 deb 和最终产物校验。
构建日志：`/tmp/iceland-no-dw9719-build.log`。
编译 DTB 已用 fdtget 验证 AF disabled、后摄无 lens-focus。
DTB SHA256：`7848ae2e19d88f4eb74782cfbce19fecad1776d0f241b50ba22a083d4a7550d0`。

本次仅 DT 变化，Image 未重编，UTS_VERSION 仍是 `#104 SMP PREEMPT_DYNAMIC @1791705392`。部署不能只看 uname，必须检查运行中 DT 和 AF 设备是否消失。
部署脚本 `install-no-af.sh` 按 modules → firmware → image → headers 安装，核对 DTB 哈希和 initrd 分区刷写日志；脚本本身不重启。

新采集脚本已备份旧版至设备 `/var/tmp/iceland-camera-tools-before-no-af-830f93c0/`，原子替换后在无 AF 启动中使用。
增加的 RPMh/共享电源事件见 `hardware-power-audit.md`。脚本语法检查通过。

## 判定标准

重启后验证运行中 AF status=disabled、后摄无 lens-focus、无 0-000c I2C 实例，且前摄媒体链完整。
先观察成功单帧/I2C 基线，再进行用户登录与相机操作。

若本轮从健康基线再次失败，而从未实例化 AF，则可排除本轮 dw9719 传输/PM 作为必要触发。
若仅一次未失败，只能记作未复现，不能据此确认 jiggle 根因。
若启动起已失败，则缺少健康基线，仍受此前设备残留状态影响，不能用于此因果判定。

## 无 AF 实测结果

四个包依次安装成功；部署日志 `/tmp/iceland-no-af-deploy.log` 明确包含
`iceland: initrd.img-7.2.9-sm8850 flashed to partition 'initrd' (129037280 bytes)`，
且安装后 DTB 哈希匹配。设备部署日志为 `/var/tmp/iceland-no-af-install-20261011T183116Z.log`。
随后执行 `systemctl reboot -i`。

Boot ID：`17d319ef-2cf4-4920-a892-9178a212e0b6`。
运行中 DT 的 `camera-lens@c/status` 为 disabled，后摄没有 lens-focus，`/sys/bus/i2c/devices/0-000c` 不存在。
完整采集 trace 中没有 `a=00c` 事务或 `0-000c` PM 事件。
前摄实际采集节点本轮为 `/dev/video2`，由 msm_vfe0_video0 实体自动查找。

| 时间（trace/journal 开机秒） | 事件 |
| --- | --- |
| 3.308117 | MONITOR_READY |
| 4.557665–9.637440 | 成功采集 24 个单帧 |
| 9.637872 | 最后成功 I2C，写 `0x0100=0` |
| 9.722 / 9.730 | WirePlumber 的 CameraManager 登记前摄 / 后摄 |
| 9.749696 | attempt 25 首次 pipeline -32 / EPIPE |
| 10.672043–10.673443 | 前摄 reset 拉低，MCLK/L1F/L14B 关闭 |
| 27.079266 / 27.223115 | 用户 display 注册 / greeter Shell 停止 |
| 280.751120–280.753975 | 手工恢复前摄媒体链接，保留前后图快照 |
| 281.861641 | 前摄开始完整 resume |
| 281.862059 / 281.862635 | L14B / L1F enable 完成 |
| 281.865408 / 281.866707 | MCLK enable / reset 释放 |
| 281.877125 | attempt 262 发出 `0x0103=1` |
| 281.877570 | SE9 resume 完成 |
| 281.878569 | I2C 首次返回 -5，之后持续同类错误 |

媒体图中 CSIPHY4→CSID0 被启用，CSIPHY5→CSID0 被禁用，导致 attempts 25–261 共 237 次 EPIPE。
没有 link ioctl 跟踪，CameraManager 枚举与图变化只能作时间关联，不能证明具体修改调用者。
这 272.240697 秒空窗内没有任何 SE9 I2C 事务，所以不能定位故障是在登录时发生，还是恢复采集后的上电/首写触发。
前摄、SE9 在首败前都经历了完整 resume，与前两轮 already-active 首败不同。

首次 GPI 原始事件 `fffff3a0 00000000 10000000 00228042` 与原故障签名一致：
code=0x10，status=0x8042 带 NACK 位；首字段是 TRE 地址，不是错误码。
GPI 仍返回错误完成事件，不能仅凭此称 DMA 引擎完全无响应。
本轮 dmesg 此处比 trace/journal 偏后约 205ms，不能跨时钟直接混排。

**结论：在本次启动没有 dw9719 传输/PM 行为的条件下，仍从成功出帧基线复现同种故障。**
本轮无需 AF 驱动的 jiggle 或 suspend/resume 即可复现；不能据此排除仍物理连接的 AF 电路，也不是冷启动消除全部历史状态的实验。
不能把此次结果当成对 modeset 或登录准确故障时刻的确认。

本地原始快照：`/tmp/iceland-no-af-17d319ef.tar.gz`，解包目录 `/tmp/iceland-no-af-17d319ef/`。
远端原始日志：`/var/tmp/iceland-camera-watch/17d319ef-2cf4-4920-a892-9178a212e0b6/`。
监视器继续运行，当前故障现场保留。

## 本轮共享供电观测

cmd-db 解码与 RPMh send/ack 显示，26.7 秒附近 modeset 的确撤回过 AP 电源票：

| 轨 | vendor 消费者 | 本轮命令 |
| --- | --- | --- |
| L1D | DSI controller 和 CSIPHY0–5 | trace 中未记录到该轨命令 |
| L3D | DSI PHY 和 CSIPHY2/4 | 26.775275 enable=0，26.779486 enable=1，间隔 4.211ms |
| L3I | 前摄 CSIPHY5 等 | 只有 mode=4/5 切换，没有 enable=0 |
| L12B | panel VDDIO | 26.733035 enable=0，26.824083 enable=1，间隔 91.048ms |
| L2F | sensor VIO / SE9 上拉 | trace 中未记录到该轨命令 |

L3D/L12B 撤票都有 rpmh_tx_done，夹着 dpu_crtc_disable / dpu_enc_mode_set；这证明命令被确认，不是物理电压测量。
28.018–28.037 秒 greeter 服务退出窗口没有这些目标轨的撤票。
vendor 对 L1D/L3D 设置 active-only always-on，主线没有；但前摄 PHY5 用 L3I，L1D 又有其他持票消费者，尚不足以解释前摄 NACK。
vendor 没有 LDO 输入拓扑，不能独立确认主线的 L12B/L2F 共 S8F 或 L1D/L1F 共 S7F 接线。
272 秒 I2C 空窗仍限制因果判定；当前没有据此修改电源约束。

## 采集工具修正

`stream.sh` 现对明确的 Broken pipe 最多尝试三次恢复前摄链接/格式，每次保留媒体图和 trace marker。
正常成功循环没有新增媒体图操作；-EIO/GPI 失败不触发恢复；超过次数会记录 FRONT_ROUTE_RECOVERY_LIMIT。
脚本已通过 bash -n，并原子更新到设备，下次启动生效，当前运行脚本未重启。
该修正只减少枚举改图造成的观测空窗，不修复 I2C 硬件故障，也不保证与相机应用并发争用时始终保持测试链路。
