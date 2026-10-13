# 同一前摄连续采样：115.855ms 首错窗口

Boot `5be94a65-0ca9-4791-95ca-e7b1612054d6`，AF仍disabled，无相机应用打开。
归档 `/tmp/iceland-fullpower-5be94a65.tar.gz`；解包目录同名，包含177.507–192.623秒全量trace与journal/快照/丢失统计。

## 已证实的顺序

| 时间（单调秒） | 事件 |
| --- | --- |
| 184.918433 | 图形登录开始 |
| 187.621682 / 187.850123 | DPU modeset / enable，随后仍成功7帧 |
| 188.121 | 前摄和SE9恢复后保持ACTIVE |
| 188.661558 | greeter Shell停止，随后仍成功4帧 |
| 189.507138 | attempt786，前摄0x10写0100=0最后成功 |
| 189.605317 / 189.605340 | GFX/GMXC撤票0，GPU_CX关闭 |
| 189.612178 / 189.620372 | CAM titan_top/TFE0 ON硬件状态轮询成功 |
| 189.619553 | GPU_CX ON硬件状态轮询成功 |
| 189.622094 | GFX corner1请求 |
| 189.622186 | sensor resume ret=1，已ACTIVE |
| 189.622191 | attempt787，前摄写0103=1 |
| 189.622192 | SE9 resume ret=1，已ACTIVE |
| 189.622223 | GFX请求ack |
| 189.622268 / 189.622279 | GMXC corner1请求 / ack |
| 189.622993 | I2C返回-5，距最后成功115.855ms |
| 189.628955–189.695044 | 首错快照，延迟5.962ms启动、72.051ms结束 |
| 189.711504 / 189.711569 | LPASS RX/TX MCLK关闭，晚于首错88.5ms |
| 190.038560 / 190.047277 | greeter WP / PW开始停止，晚于首错约0.42秒 |

此前累计781帧成功；attempt编号包含5次已恢复的EPIPE。整份journal未见Snapshot、OpenPipeWireRemote或libcamera配置流。
关键窗没有用户服务退出日志，没有GPIO/pinctrl/SPMI/reset、sensor电源enable/disable、clk11或SE9 clock切换。
L3I mode4→5是CSIPHY5随采集停止/启动的常规操作，42个成功间隔均出现，不是本次独有。
MMCX/MXC等依赖未见持续撤票未恢复，CAM ON poll成功；首错快照regulator内容与188.928秒周期快照逐字相同。
243组统计中overrun/commit-overrun/dropped与kprobe misses均0，coverage无缺项。

## 结论边界

本轮确认相机应用并非必要触发；首败不是sensor/SE9重新上电失败，也不是greeter WP/PW退出或LPASS关钟先导致。
显示modeset后多轮成功，使“显示撤轨后立即坏且没有恢复”的解释不符合本轮顺序。
AP事件不能排除固件自主操作、延迟影响、物理轨压或时钟毛刺。

GPU唤醒与0103首笔写重叠是可检验候选，尚未定因：16次GPU唤醒中182.821989也与普通寄存器的成功I2C重叠；42个成功间隔中8个有GPU on、6个有off。
需要隔离GPU runtime PM转换，而不是仅凭相关性修改供电约束。

## 下一轮单变量隔离

开机监视器在存在 `/var/tmp/iceland-camera-tools/gpu-runtime-hold` 时，等待GPU驱动及runtime PM可用后设置 `3d00000.gpu/power/control=on`。
在trace/log中记录原control、请求和结果；必须实测control=on/status=active，且GFX/GMXC/GMU在测试窗口不再挂起，才算隔离有效。
仅改变GPU runtime PM自动挂起设置；AF和相机供电代码保持原实验状态。
补充AOSS/SCM/GPU现有事件以观察AP→固件调用，此为观测覆盖变化。
该实验同时改变GPU负载瞬态、父资源票和登录耗时；即使未复现，也只能支持GPU PM转换相关，不能确认某条物理轨。
回退：移走上述标志文件，重启恢复默认auto；或在当前boot写auto允许再次挂起（须标记且保留前后证据）。
