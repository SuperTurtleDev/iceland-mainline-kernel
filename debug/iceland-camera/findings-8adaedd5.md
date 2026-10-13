# 全量供电跟踪：8adaedd5

Boot ID `8adaedd5-2da1-4c30-83c5-91686b52a0b4`，AF disabled。
本地窗口归档 `/tmp/iceland-fullpower-8adaedd5.tar.gz`；解包目录同名（无扩展名）。
原始完整日志仍在设备 `/var/tmp/iceland-camera-watch/8adaedd5-2da1-4c30-83c5-91686b52a0b4/`。

## 本轮可以确定的事实

| 单调秒 | 事件 |
| --- | --- |
| 245.202567 | SSH ubuntu 会话开启，随后启动用户 systemd manager |
| 245.885057 | 前摄0x10最后I2C成功；累计取得1039帧，attempt编号1042（含3次失败） |
| 245.953911–245.967 | 用户 WirePlumber 启动libcamera并枚举前后摄 |
| 245.980820 / 246.089569 | 下一轮采集走后摄CSIPHY4，attempt1043记录EPIPE |
| 247.107–247.109 | 前摄reset拉低，MCLK/L1F/L14B正常挂起关闭 |
| 256.275302 | GDM用户会话登录 |
| 259.128341–259.131442 | modeset期间共享L3D撤票3.101ms后恢复 |
| 259.086088–259.179067 | panel L12B撤票92.979ms后恢复 |
| 261.032–261.044 | greeter WirePlumber/PipeWire停止 |
| 275.163 | Snapshot相机应用启动 |
| 275.830521 / 275.838299 | CAM titan_top/TFE0 ON硬件状态轮询成功 |
| 275.840415–275.845191 | 后摄L14B/L1F/L16B、MCLK和reset完成开启 |
| 275.856071 | PipeWire23544的CameraManager线程24160向后摄0x36写0103=1 |
| 275.857998 | 首个I2C -5；GPI code0x10/status0x8042，含NACK |
| 275.901516–276.037551 | 首错专属供电快照，错误后43.5ms开始、179.6ms结束 |

最后成功到首败29.972941秒内，前后两笔之间没有任何SE9 I2C事务。
不能把无I2C观测的空窗当作已知故障持续时间；也不能把前摄成功基线与后摄首败直接等同为同sensor前后对照。
SSH通过PAM/user manager间接启动媒体服务，是实际观测干扰；不能声称采集一直成功覆盖到了图形登录。

## 供电审计

未找到首败前相机依赖资源被AP持续关闭且未恢复的证据。
MMCX始终持有非零性能票，首败时level384；MXC、QUP2、SE9 wrapper/SE时钟在首写前恢复。
18404个配对动态调用返回均为0；GDSC ON poll成功比缓存状态更强，但仍不是轨压/MCLK波形实测。
GPIO/SPMI成功写入后摄reset高配置。首败后275.858秒的CAM/MXC关闭属于失败清理，晚于触发。
L3I停留低功耗模式符合前摄停用；后摄PHY4使用L3D。
窗口无L2F/L1D/S7F/S8F/LS1B/LS2B的AP RPMh命令；不能排除其它主控或电气变化。

全量事件覆盖无缺项/错误；所审计统计样本的ring overrun/commit-overrun/dropped和kprobe missed均为0。
快照不是原子状态，读取有持锁/CPU/SPMI开销，已记录窗口。
原始事件和资源分类详见 `/tmp/iceland-fullpower-vendor-report.md` 与 `/tmp/iceland-fullpower-vendor-analysis.json`。

## 修正与后续

此前stream.sh的三次恢复限制是整轮累计；开机阶段已耗尽，后来的正常出帧未恢复额度，造成登录前EPIPE长期空转。
现改为最多连续三次恢复，成功帧后重置连续计数；总计数仍保留用于唯一快照名。
仅EPIPE触发恢复，EIO/EBUSY不强制改图。新版已原子部署，下次启动生效。

首败后关闭Snapshot测试应用，发现PipeWire仍持有缓冲，S_FMT返回EBUSY；后续节点释放/前摄验证均有POST_ERROR前缀marker。
这些操作发生在归档窗口之后，不作为原始触发条件。

停止ubuntu用户的WirePlumber/PipeWire及其socket后，成功释放节点并恢复前摄链路。
开机1330–1331秒的attempt1999/2000均为前摄0x10 `0x0103` 写 -5，伴随同样GPI异常完成。
所以后摄首败后的状态也影响前摄；但不能据此倒推30秒空窗中究竟哪一步触发。
本轮未重绑定I2C/GPI、未修改电源约束，也未删除jiggle。下一轮使用修正后的路由恢复脚本，先只验证登录。

后续已重启到 `5be94a65-0ca9-4791-95ca-e7b1612054d6`，124个供电事件无缺项/错误。
SSH枚举再次使attempt464 EPIPE，但新版在111.664699–111.714413秒完成恢复；到140.48秒attempt586仍正常出帧，无FIRST_I2C_ERROR。
当前停留greeter，等待仅图形登录的复现，以保持前摄I2C采样覆盖会话交接。
