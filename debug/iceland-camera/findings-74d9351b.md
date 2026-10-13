# 单帧循环首次 I2C 故障：74d9351b

设备内核：7.2.9-sm8850 #104。Boot ID：74d9351b-f9a5-41e7-816a-cb397dc5327e。
本轮只采集、分析，没有修改内核、构建或刷写。

日志归档：`/tmp/iceland-oneframe-74d9351b.tar.gz`。
解压目录：`/tmp/iceland-oneframe-74d9351b/`。
设备原始日志：`/var/tmp/iceland-camera-watch/74d9351b-f9a5-41e7-816a-cb397dc5327e/`。
以下时间均为开机 monotonic 秒；journal 时间是日志记录时间，不能代替 trace 的硬件操作时间。

## 结论

前摄每次采一帧、关闭并立即重开，前 317 轮成功，第 318 轮首次 I2C 失败。
最后成功事务结束于 76.930122，首次失败返回于 77.044448，相隔 114.326ms。
这是观测到的正常/失败边界，不是已测定硬件状态改变的准确时刻。

首次失败紧贴 GDM greeter 的 WirePlumber/PipeWire 退出和相机节点释放。
Snapshot App 到 87.967100 才被启动请求，比首次错误晚 10.923 秒，不能是本轮首次故障的触发者。
DPU modeset/enable 之后仍有多轮成功拍摄，当前证据不支持 modeset 当场破坏 I2C。
greeter 退出与错误时间相邻，但尚未证明具体因果路径。

## 时间线

| 时间 | 来源 | 事件 |
| --- | --- | --- |
| 74.664493 | trace | DPU mode_set |
| 74.883041 | trace | DPU enable，3392×2400 |
| 75.598655 | journal | greeter GNOME Shell 开始退出 |
| 75.718384 | journal | greeter GNOME Shell service 已停止 |
| 76.797575–76.798732 | trace | LPASS RX/TX MCLK、fsgen 关闭，随后第 317 轮 I2C 仍成功 |
| 76.929612 | trace | 第 317 轮 DQBUF，没有 ERROR 标记 |
| 76.929796–76.930122 | trace | 前摄 @0x10 写 0x0100=0，ret=1，最后成功事务 |
| 77.014630 | journal | greeter gnome-login session manager 停止 |
| 77.015579 | trace | 第 317 轮采集进程结束 |
| 77.021406 | journal | greeter WirePlumber 开始停止 |
| 77.024066 | trace | CameraManager-2621 释放 AF runtime PM 引用，剩余 2 |
| 77.025874 | trace | 第 318 轮开始 |
| 77.030526 | trace | CameraManager-2917 释放 AF runtime PM 引用，剩余 1 |
| 77.030536 | journal | greeter WirePlumber 停止 |
| 77.033388 | journal | greeter PipeWire 停止 |
| 77.033864 | journal | gdm-greeter PAM session 关闭 |
| 77.043829–77.043838 | trace | 前摄与 SE9 resume 都返回 1，已经 runtime active |
| 77.043837–77.044448 | trace | 前摄 @0x10 写 0x0103=1，首次 ret=-5 |
| 77.044553 | journal | GPI event：fffff340 00000000 10000000 00228042，随后 Error in Transaction |
| 77.137165 | trace | 第 318 轮 capture_failed，0 帧，STREAMON EIO，进程 exit code 仍为 0 |
| 77.356023–77.356422 | trace | 首败后 SE9 才真正 suspend，关闭 wrap2_s1/wrapper AHB clocks |
| 78.169531–78.170956 | trace | 首败后前摄 reset low、clk11/L1F/L14B 关闭 |
| 78.178435 | journal | 第 319 轮 call_s_stream WARN，见下文 |
| 87.967100 | journal | 请求启动 org.gnome.Snapshot |
| 88.018317 | journal | Snapshot App 启动日志 |

## 供电、时钟与持有者

114ms 窗口内记录的时钟事件全部属于逐轮 CAMSS 开关；没有 SE9、clk11、显示或音频时钟变化，没有记录到 regulator/GPIO 变化。
AF 自 8.872291 起一直 runtime active；77 秒两次 put 没有降到零，没有 AF 停车写或 L16B disable。
前摄从 4.277080 一直 active 至首败，后摄自 3.991949 一直 suspended。
首败后的 regulator 快照仍显示前摄 L1F/L14B/L2F 及 AF L16B 引用，L2F 为 1.8V、use count=2。

owners.log 在 76.85 秒看到 greeter 的 pipewire PID2501、wireplumber PID2508 和用户 wireplumber PID8870 持有相机节点；77.93 秒只剩用户 wireplumber。
这与 greeter 服务退出及 CameraManager 引用释放一致，不证明释放动作改变了总线硬件状态。

以上是 Linux 软件观测。现有 trace 没有 clk_prepare/unprepare、clk_set_parent、pinctrl、完整电源域或 RPMh 投票，不能据此排除未记录的资源变更或 PMIC/固件实际状态变化。

## 首败之后的 WARN

`linux/drivers/media/v4l2-core/v4l2-subdev.c:484` 的 WARN 检测已开启 subdev 再次收到 s_stream(1)。
`linux/drivers/media/platform/qcom/camss/camss-video.c` 的 video_start_streaming 逐段开启链路，失败分支只调用 video_device_pipeline_stop 和缓冲区 flush，没有逐段 s_stream(0) 回滚。
第 318 轮 sensor 失败后，第 319 轮重新启动触发该 WARN；堆栈为 call_s_stream → video_start_streaming → vb2_start_streaming → STREAMON ioctl。
它发生在首次 NACK 后约 1.134 秒，是需另行处理的失败清理问题，不能解释本轮首败。

## 状态与下一步

最后设备读取时 uptime 412.79 秒，监控 service 仍 active，第 612 轮仍失败，第 613 轮开始；没有重启或停监控。
下一轮应围绕 greeter 相机节点 close/release 补充调用路径与缺失资源事件，再单独控制 greeter 音视频服务退出，区分登录显示切换和资源释放。
这项后续实验尚未执行，本轮未据时间相关性应用内核修复。

## 后续核查：刷新率与 vendor 引脚

同一 boot 登录后的只读检查：用户 `/home/ubuntu/.config/monitors.xml` 为 3392×2400@60.000，DRM 当前 CRTC 也是 60Hz。
`modetest -M msm -c` 显示 3392×2400@120.00 是唯一 preferred mode。
greeter 的 `/var/lib/gdm3/seat0/config/` 没有 monitors.xml，另查 /etc/xdg、/var/lib/gdm3、/run/gdm3 也没有该配置。
因此用于对齐的默认目标是 120Hz；本轮没有在 greeter 存活时直接读取其活动模式，不能把默认选择推断当成该时段的硬件采样。
刷新率对齐只能消除刷新率差异，登录时是否仍有完整 modeset 需要下一轮 trace 验证。

已直接解析 `/home/wyb/Documents/mainline/repos/iceland-fw/vendor_boot.img` 中 14 个 FDT 里的 4 个 Canoe 基础 DTB，以及 `dtbo.img` 的 10 个 Iceland overlay，并对照源码：

| 信号 | vendor 与主线的物理引脚 |
| --- | --- |
| 相机 SE9 SDA/SCL | TLMM4/5，QUP wrapper2 |
| 显示 reset | TLMM171 |
| 显示 TE | TLMM86；vendor 另有 TLMM87 |
| 背光 SE14/SE15 I2C | TLMM8/9、TLMM12/13，QUP wrapper3 |
| 相机前/后 reset | PMH0110_G GPIO13/14 |
| 相机前/后 MCLK | PMK8850 GPIO1/2 |
| 显示 TE 电平配对 | PMH0110_D GPIO7/8、GPIO9/10 |
| 主线显示 reset 电平配对 | PMH0110_F GPIO9/10 |

未发现显示与 SE9/相机使用同一控制器同一 GPIO 的冲突。不同 PMIC 或 TLMM 的同号 GPIO 是不同引脚。
故障后的 GPIO 快照仍是 TLMM4/5 high、func1（qup2_se1）；后续 live pinmux-pins 也显示由 884000.i2c 持有，不能排除未采到的瞬时变化。
一个真实配置差异：vendor SE9 使用 8mA drive-strength，主线为 2mA；它属于尚未验证的电气配置差异，不是 pinmux 冲突证据。

共享资源仍需检查：vendor 确认 DSI 与 CSIPHY 直接共享 L1D；主线输入供电拓扑描述显示 L12B 与相机 L2F 共父轨 S8F、DSI L1D 与相机 L1F 共父轨 S7F，但 vendor DT 不提供父轨拓扑以独立验证接线。
现有 regulator 过滤漏掉 L1D/L3D/L3I/L12B 等显示/PHY 叶轨，时钟事件也未覆盖 RPMh 时钟实际投票所在的 prepare/unprepare，不能据旧 trace 排除所有共享资源变更。

后续完整审计与下一轮采集准备见 [hardware-power-audit.md](hardware-power-audit.md)。其中区分 vendor 的 ACTIVE 常开票、独立 LS 电平转换资源、Linux 引用保护和未验证的板级 VIN。后续 SSH 连接超时；本段前述 active 状态只代表历史读取，不能当作设备当前监控状态。
