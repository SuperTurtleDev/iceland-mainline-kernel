# Greeter → session 全量供电跟踪

2026-10-12，按用户要求扩展现有开机相机监视器；不改内核供电策略，不增加 always-on。
AF 仍保持 DT disabled。软件跟踪的“全量”指 Linux/AP 可见的资源操作，不是所有物理电源的电压测量。

## 覆盖

- 所有 regulator、runtime PM、clk、RPMh、interconnect、GPIO、SPMI 事件，取消原有按相机轨/设备的过滤。
- 电源回调、系统 suspend/resume、PSCI domain idle、wakeup source、devfreq，以及 regmap 写入和 cache 状态事件。
- 动态入口/返回探针：GDSC 开关/硬件模式/状态轮询，RPMhPD 开关/性能等级，regulator mode/load/force-disable，时钟 API 返回码，GPIO/pinctrl/PMIC/reset，RPMh write/batch/flush。
- 保留 DPU modeset、SE9 I2C、单帧采集和 journal 同步时间线。
- 全部 CMD-DB 地址保留，包括 ARC 的 MMCX/MXC 等 0x300xx 与 ICC BCM；不能只筛 LDO 地址。

`power-events.py` 最初确认124个事件；dcf91ae1扩展到135个，missing/errors均为空。
新增AOSS发送/完成、SCM调用与waitq、GPU/GMU频率和GPU挂起/恢复事件。
其中75个标准事件、60个动态入口/返回事件。
资源名称所需的结构偏移由当前 vmlinux DWARF 核实，只有运行 build ID
`1dd4d3b789aab5be5c98495c6e99ea640253867e` 匹配时使用；其它内核只记录指针/符号。
记录每个事件的实际 format/filter 和探针定义，不把“脚本尝试开启”当作成功覆盖。

## 状态与完整性

`power-snapshots.py` 每秒保存各 CPU 的 trace stats、kprobe_profile、trace 文件大小和磁盘余量。
每5秒保存 regulator/genpd/interconnect/GPIO/pinctrl 和设备 runtime_status；runtime 路径首次立即扫描，
开机30秒内每5秒重扫，之后约30秒重扫。dcf91ae1暴露的前30秒漏扫问题已修复，旧日志无法补采。
每个 debugfs 读取记录单调时钟起止与返回值，超时2秒，并在 trace 中标记整个读取窗口。
周期快照不重入；首次 I2C 错误通过独立 request 异步触发专属快照，不被此前 EPIPE 消耗。

`clk_summary` 会调用 clk_pm_runtime_get_all() 主动唤醒 clock provider，因此已从开机/失败快照移除。
其他快照仍有持锁、CPU和总线开销，不能宣称零扰动；精确资源变化以事件记录为主。
trace 每 CPU 缓冲扩大至16MiB，唯一 trace_pipe reader 批量写入、约100ms flush；首 I2C 错误立即 flush。
停止时保存最终统计。overrun/dropped 会显式报告；kretprobe miss-hit 保留在 profile 中。

## 部署与验证

工具在 `/var/tmp/iceland-camera-tools/`；旧版备份为其下 `before-full-power-48110e17/`。
开机服务仍为 `iceland-camera-watch.service`，在 udev trigger 前启动。无需重编/部署内核。
日志目录为 `/var/tmp/iceland-camera-watch/<boot-id>/`，current 指向当前轮。
本轮 48110e17 在已有故障后原位扩大覆盖，不能补回此前未记录的事件。

验证通过：Python编译、shell语法、首错异步request/124ms窗口夹具、实机周期快照、资源名解码。
原位验证各 CPU overrun/commit-overrun/dropped 为0，kprobe profile miss-hit为0。
全量事件量较大，实测约数MB/s；保留原始日志，不自动删除或轮转。每秒记录剩余空间，适用于登录复现窗口。

全量监控部署后已重启，boot `8adaedd5-2da1-4c30-83c5-91686b52a0b4`。
开机13.64秒验证服务active、事件无missing/errors，greeter仍在tty1，单帧已连续成功至少27次，无FIRST_I2C_ERROR。
已通知用户可执行登录→相机流程；采集和首错供电快照持续自动进行。
开机245.97秒再次验证：已成功到第1042次单帧，FIRST_I2C_ERROR仍为空；124事件无缺项/错误，所有CPU的overrun/commit-overrun/dropped及kprobe miss-hit均为0。
此时trace约1.58GB、可用空间约470.95GB，说明全量跟踪必须结合容量统计使用，不能无限期忽略日志增长。

## 已有窄窗口的证据

Boot `48110e17-4f1b-4d2a-9128-425ca171d8a0` 在20.759545最后成功，20.883693首个-5，窗口124.148ms。
该窗无 ARC/MMCX 命令；MMCX此前19.979666为corner10，MXC19.979624为corner6，下一次变更在21.857秒，已晚于首错。
L3I mode4→5与单帧停止/启动一致。L4G/clk8撤票对应UFS休眠，此前13次同类撤票后I2C仍成功，不能只凭相邻时间归因。
ICC BCM变化均保持VALID位；窗口无modeset事件。关键相机轨未记录到AP撤票。
原始窄窗口快照 `/tmp/iceland-power-before-48110e17.tar.gz`，完整日志仍在设备。

## 判读边界

- regulator/genpd状态多为缓存；RPMh ack表示AP命令完成，不代表示波器测得电压。
- RPMh sleep/wake事件是TCS编程，固件稍后执行或其他主控投票可能没有AP事件。
- clk complete 不代表成功，需结合返回探针；返回0也不能证明MCLK波形。
- GDSC poll成功证明驱动读到目标状态位，但自主硬件门控仍可能没有入口事件。
- SPMI记录AP PMIC事务；看不到AOP自身SPMI，也不主动扫描PMIC寄存器或改变引脚方向。
- GPIO逻辑值与PMIC原始电平区分，PMIC pin为零基。首错必须有之前成功I2C基线，否则不能排除旧状态残留。
