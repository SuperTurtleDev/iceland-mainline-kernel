# GPU runtime PM 常开隔离仍复现

Boot `dcf91ae1-7437-4185-8f77-65b74eceb409`，AF disabled，内核 #104。
归档 `/tmp/iceland-fullpower-dcf91ae1.tar.gz`，解包目录同名。

GPU 在3.261242秒确认 `control=on/status=active`。归档窗口没有GPU/GMU/GXCLKCTL
runtime suspend、GPU GDSC关闭或GFX/GMXC active零票，仍然出现同类故障。
这排除AP GPU runtime挂起/唤醒是必要条件，不覆盖固件IFPC或GPU变频。

| 单调秒 | 事件 |
| --- | --- |
| 14.767667 | 图形登录会话打开 |
| 16.683016 | DPU enable，此后仍成功6帧 |
| 16.955437 | SCM SET_REMOTE_STATE(1,0)，视频固件启动；随后5次前摄复位写成功 |
| 17.022267 | greeter Shell停止，此后仍成功5帧 |
| 17.950409 | 第63轮停流0100=0最后成功 |
| 18.028645 / 18.039295 | greeter WP / PW开始停止 |
| 18.065930 | 前摄resume ret=1，已经ACTIVE |
| 18.065936 | 第64轮前摄写0103=1 |
| 18.065937 | SE9 resume ret=1，已经ACTIVE |
| 18.066556 | I2C -5，最后成功到首错116.147ms |
| 18.128463–18.178975 | 首错供电快照，延迟61.907ms启动 |
| 18.359357 | SE9真正runtime suspend，晚于首错 |
| 18.891307 | LPASS RX MCLK关闭，晚于首错824.751ms |
| 19.316065 | 前摄reset拉低，晚于首错 |
| 39.126854 | 相机应用才被激活，晚于首错21.060298秒 |

关键窗无sensor轨、reset、MCLK、SE9 clock、SPMI/pinctrl变更，也无AOSS/SCM调用。
98个相关动态API均ret=0。CAMSS GDSC开关、L3I mode4→5、ICC票是常规采集操作；
此前54个成功间隔同样有L3I切换。触屏SPI恢复来自QUP4，不是SE9所在QUP2，旧轮首错窗也没有此动作。
GPI仍返回`10000000 00228042`错误完成（NACK），没有证实DMA引擎无响应。

本轮WP/PW退出先于首错，但旧轮5be94a65退出晚于首错，不能当作共同直接触发。
两轮greeter Shell停止到首错分别1.044289与0.961435秒；这是值得追踪的相关性。
用户新增最小复现：无需登录，只需停止GDM进入console；下一轮先沿用原sensor驱动验证这一触发。

135个供电事件无missing/errors；201组统计overrun/dropped/kprobe miss均为0。
早期runtime状态快照存在缺口：扫描时间初值0导致开机30秒内跳过，首错快照count=0。
ACTIVE结论来自trace，而非空快照。采样器已修为首次立即扫描、开机30秒内每5秒重扫，之后30秒；
模拟3/4/8/13/28/33/58秒验证通过，修复已部署供下一次启动使用。

GPU常开标志及日志已保存到本轮设备日志目录，约527.27秒恢复auto，后续启动不再常开GPU。
未据时间相关性修改任何供电约束。寄存器前置读诊断尚未加入内核。

## 停止 GDM 的最小复现

在新鲜 boot `5ba50ebd-fa60-4b2a-8b33-05e1757e43df` 中，greeter 下连续 669 帧成功后，
在155.798652秒执行 `systemctl stop gdm`。停止动作本身不是首错：之后第670–673轮仍各收一帧。
第674轮在156.844812秒收帧，随后156.845041秒写前摄 `0x0100=0`，156.846944秒返回−5；
首错距离停止GDM 1.048292秒，距离上一笔成功 I2C 48.667ms。下一轮才因残留错误在STREAMON失败。
这直接排除了 `0x0103` 软复位是首个必要触发点，也说明显示退出/会话关闭在无需相机应用时足以触发。

首错前没有 camera rail、CAMSS clock/GDSC、MCLK 或 SE9 时钟切换。与首错最近的共同资源动作是
UFS PHY 关闭与 L4G 0.9V disable（156.799225–156.799328），以及随后 CPU2 进入
`state=0x200c354`（domain idle state，DT 定义为约10.15ms minimum residency）；RPMh
在156.803921秒编程 wake/sleep TCS。相同 UFS/RPMh/CPU idle 序列在前一轮成功周期也出现，
因此目前只是可检验候选，不能据时间邻近归因。首错窗内未见 `xo.lvl` 0x30080 撤票。

已准备下一项单变量：开机监视器持有 `/dev/cpu_dma_latency` 的 0us QoS 请求，阻止 CPU
进入深 idle，同时保持相机、显示和 UFS 配置不变。由于当前故障经 i2c 控制器重绑仍返回−5，
该实验需要完全断电后的干净启动；暖重启不能作为基线。
