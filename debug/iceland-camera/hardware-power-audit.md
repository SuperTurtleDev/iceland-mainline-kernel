# Iceland 登录故障：vendor 接线与共享供电审计

日期：2026-10-11。对应首次故障日志 boot `74d9351b-f9a5-41e7-816a-cb397dc5327e`，内核 `7.2.9-sm8850 #104`。
内核、DT 未修改，未构建或刷写。本轮更新的是采集脚本与分析记录；设备 SSH 超时，新增采集尚未部署。

## 结论与证据边界

显示与相机确实共享部分电源，但现有证据尚不能证明 modeset 将相机 I2C 相关电源关掉。
vendor 编译 DT 确认的共享叶轨是 **L1D（DSI + 全部 CSIPHY）与 L3D（DSI PHY + CSIPHY2/4）**。
前摄 CSIPHY5 的低压轨是 L3I。显示没有直接引用传感器的 L2F、L1F、L14B 或 AF 的 L16B。

主线描述显示 L12B 与相机 I/O/上拉 L2F 共父轨 S8F、L1D 与传感器 L1F 共父轨 S7F、DSI PHY 的 L3D 与前摄 CSI 的 L3I 共父轨 S7G。
vendor DT 没有 LDO 输入供电拓扑，不能用它独立证明这些父轨的物理接线；也未发现相反接线证据。
PMIC GPIO VIN 同样没有 supply phandle，接线缺口需 PMIC/板级资料或电气测量补齐。

首次错误前的最后成功事务是 76.930122，首次错误返回 77.044448，观测窗口 114.326ms。
74.664493 的 modeset 后仍有成功拍摄。错误紧贴 77.015–77.034 的 greeter D-Bus/多媒体服务退出。
这保留了延迟或共享资源影响的可能性，但不支持把 modeset 立即断电写成已证实原因。
在已故障的 boot 内调回 60Hz 后仍失败，不能单独用来排除首次 modeset 触发。

## 输入与定位

vendor 源码根：`/home/wyb/Documents/mainline/repos/android_kernel_modules_and_devicetree_oneplus_sm8850/`。
下文 vendor 路径以此为根；主线路径以当前 kernel 工作目录为根。

- `/home/wyb/Documents/mainline/repos/iceland-fw/vendor_boot.img` 中共有 14 个 FDT，其中 4 个是 Canoe 普通/alt thermal、v1/v2 基树。
- `/home/wyb/Documents/mainline/repos/iceland-fw/dtbo.img` 中共有 10 个 Iceland overlay；相机轨映射和 LS1B/LS2B 常开配置一致。
- 代表性合并：`/tmp/iceland-vendor-power/merged-08-02.dts`，由 Canoe v2 base-08 与项目 25926 overlay-02 通过 fdtoverlay 合并。没有将其认定为设备 bootloader 实际选择的精确组合。
- 独立解析记录：`/tmp/iceland-vendor-power/audit.md`；解析脚本：`/tmp/iceland_vendor_power_audit.py`。
- 故障快照：`/tmp/iceland-oneframe-74d9351b/regulators-first-failed-cycle.txt`。

## 电源矩阵

| 资源 | 显示消费者 | 相机消费者 | 证据与差异 |
| --- | --- | --- | --- |
| L1D，1.2V | DSI controller0/1 | CSIPHY0–5 PLL | vendor 与主线映射相同；vendor 另有 active-only 常开票 |
| L3D，0.88V | DSI PHY0/1 | CSIPHY2/4，后摄使用 PHY4 | vendor 与主线映射相同；vendor 另有 active-only 常开票 |
| L3I，0.88V | 无 panel/DSI 消费者 | CSIPHY0/1/3/5，前摄使用 PHY5 | 不与 DSI 共叶轨；主线还给 PCIe PHY 供电 |
| L12B | panel VDDIO | 无 | vendor 实际 panel 请求 1.9V、220mA；主线故障快照请求值 1.8V、0mA |
| L2F，1.8V | 无 | sensor/AF/EEPROM VIO，板级注释指定 SE9 上拉 | 主线 always-on；无显示直接 consumer |
| L1F，1.2V | 无 | sensor DVDD | 无显示直接 consumer |
| L14B，2.8V | 无 | sensor AVDD | 无显示直接 consumer |
| L16B，2.8V | 无 | AF、后摄 AFVDD | 故障窗口 AF 引用未归零，没有停车写或 disable |
| S8F | 经 L12B 给显示供电 | 经 L2F 给相机 I/O 供电 | 只由主线输入供电拓扑确认；也接音频 L15B |
| S7F | 经 L1D 给显示供电 | 经 L1D/L1F 给 CSI/sensor 供电 | 只由主线输入供电拓扑确认；也接音频 L1G |
| S7G | 经 L3D 给 DSI PHY 供电 | 经 L3D/L3I 给 CSI PHY 供电 | 只由主线输入供电拓扑确认；也供 UFS/USB 低压叶轨 |

主线位置：`linux/arch/arm64/boot/dts/qcom/kaanapali-oneplus-iceland.dts:414`、`:611`、`:669`（父轨），`:905`（CSI），`:1184`（DSI）。
vendor 合并 DTS：`:37118`、`:37152`（DSI），`:40537`、`:40589`、`:40615`（CSI）。

vendor Iceland panel 的定制 supply 表只列 vddio，见 `vendor/qcom/opensource/display-devicetree/oplus/iceland-25926-display-canoe-overlay.dtsi:18`。
不能把通用显示节点里的 L13B/L11B/L4B 属性全部当作此 panel 实际启停的电源。
主线 `panel-novatek-nt36536.c:359` 只 bulk enable，没有针对 VDDIO 设置电压/负载。
电压、负载请求差异需单独验证，不能据 cached 值判断物理电压或父轨 headroom 不足。

## 常开票与 Linux 引用保护

vendor `kernel_platform/qcom/opensource/devicetree/qcom/canoe-regulators.dtsi:750` 和 `:809` 分别为 L1D/L3D 设置独立 ACTIVE 常开票；ALL 消费者释放不代表 AP active 状态下该轨关闭。
主线 L1D/L3D 无该常开票。这是真实差异，但普通主线 always-on 并不完全等价于 vendor ACTIVE-only 策略，不能直接扩大到所有休眠状态。

本轮故障快照中 L1D use=6：DSI0/1、UFS PHY、PCIe PHY、USB HS、USB DP 各持一个引用。
L3D use=2，由两个 DSI PHY 持有；L3I use=1，由 PCIe PHY 持有。
因此不能仅凭缺少 vendor 常开票，就认定显示释放会使 L1D 掉电。

regulator core 的正常路径也未发现显示关闭 L2F/S8F 的机制：

- `linux/drivers/regulator/core.c:1665`：always-on 初始化持父轨引用，并给本轨永久 use_count。
- `core.c:3255`：只有最后用户且非 always-on 才执行硬件 disable；子 use_count 归零才释放父轨。
- `core.c:4154`：NLDO530 没有 min_dropout_uV 且有电压 getter，不触发此处 Linux 父轨自动调压；正常 disable 不主动降低 S8F 电压。
- `core.c:5185`：always-on 不锁死工作模式，负载变化仍可改模式。sensor、AF、panel 没有 set_load 调用；DSI/CSI 有初始化负载，释放会影响它们共用轨的模式请求。
- `linux/drivers/regulator/qcom-rpmh-regulator.c:300`：电压/enable/mode 是独立命令，分别位于资源地址 +0/+4/+8。NORMAL 对应 OPM/AUTO，不能误读成关电。

vendor `kernel_platform/qcom/opensource/devicetree/bindings/regulator/rpmh-regulator.yaml:184` 明确 RPMh 管理父轨 headroom。`regulator_summary` 是 Linux 请求缓存，不是电压测量；S8F 显示 1800mV 不足以证明物理轨只有 1800mV。

## LS1B/LS2B 与 GPIO 接线缺口

`canoe-regulators.dtsi:673` 起将 LS1B/LS2B 定义为独立 `qcom,rpmh-xob-regulator`，分别控制 PMH0101_B GPIO11/12、13/14 的双向电平转换资源。
`vendor/qcom/opensource/camera-devicetree/oplus/iceland-camera-sensor-mtp-EVB.dtsi:136`、`:141` 对它们设 always-on；10 个 overlay 均已编入。
主线 regulator 驱动没有这些 LS 项，GPIO pinconf 也不会代为投票。

但合并 DT 中 B GPIO11–14 无设备 gpios 引用、无 pinctrl consumer，LS1B/2B 也无 supply consumer。
源码中 ts_rst/ss_rst 配对只是注释。故不能宣称它们就是 SE9 SDA/SCL 转换器，也不能证明显示使用它们。
显示实际配对脚在 PMH0110_D GPIO7–10、PMH0110_F GPIO9/10；camera reset 在 PMH0110_G GPIO13/14；MCLK 在 PMK8850 GPIO1/2。
这些是不同 SID/控制器，不能因为 GPIO 编号重复而视为同一线路。

`linux/drivers/pinctrl/qcom/pinctrl-spmi-gpio.c:249` 通过 SPMI 写 pin 寄存器，没有 RPMh/regulator 调用。
其 pinmux_ops（`:380`）没有 free/release_mux 回调，单纯释放 ownership 不会清 GPIO EN 或 LS vote。
`power-source`（`:524`、`:579`）是直接写 DIG_VIN_CTL 的选择编码；PMIC DT 没有描述 VIN1/VIN2 接到哪条 LDO。
vendor camera reset active 使用 source=2，主线 source=1；现有代码无法独立证明真实电压，不据注释盲改。
故障快照中的 B GPIO11–18 `---` 只表示 GPIO EN 位关闭，不证明独立 LS XOB 状态。

另外，vendor wcd9378 对 L1F 的引用来自 disabled 节点。实际启用 wcd939x 用 L15B/BOB1/L1G，不存在已证实的 sensor DVDD 与此 codec 直接共 L1F。

## GDM 子任务与故障窗口

子 agent 审计 GNOME 上游 GDM/gnome-session/Shell/Mutter 50.1。设备安装包版本及 Ubuntu 补丁因 SSH 超时尚未核实。
75.564941 用户 Shell `Registering display with GDM` 后，GDM `gdm-manager.c:668` 将 display 设 MANAGED；`gdm-local-display-factory.c:320` 清理等待的 greeter，最终发送 SIGTERM。
gnome-session `data/gnome-session-shutdown.target:26` 随清理启动 restart-dbus；`tools/gnome-session-ctl.c:116` 调用用户 systemd `StopUnit("dbus.service", "fail")`。
日志吻合 77.015 restart-dbus，随后 WirePlumber/PipeWire 退出，77.044 首次 NACK。
GDM 的这条路径没有直接相机供电/V4L2 操作；多媒体持有者的退出仍需与内核资源变化闭合。
greeter 的音频服务正常停止不能当作用户桌面音频服务崩溃证据。

## 已准备的下一轮采集

保持原先每次一帧、关闭后立即重开的行为。补齐 L1D/L3D/L3I/L12B/S7G regulator 事件、时钟 prepare/unprepare 和 parent 事件、RPMh send/ack 与 cmd-db 映射。
首个失败周期后增加 clock/domain/DRM/pinctrl 快照，用 begin/end 标记其采样窗口；它们不是首次错误发生瞬间的原子快照。

RPMh active send/ack 是下发/完成证据，不是 PMIC 电压测量；sleep/wake send 是写入预置 TCS，不代表当场断电。ack 只带请求首命令地址。
优先检查最后成功到首次 NACK 窗口的 L2F/S8F、L1F/S7F、L3D/L3I/S7G、L1D/L12B，以及 camera MCLK 对应 C11A_E0 的投票。
LS 资源地址若出现在 cmd-db 可用于识别其记录；主线没有 LS consumer，不能预期必然出现 LS 投票，也无法由缺少事件证明固件状态未变。

下一轮须先观察到正常单帧/I2C 基线，再区分完整登录、仅 greeter 多媒体服务退出、单独显示切换。一次只改变一个条件。
本轮没有部署推测性电源补丁。设备恢复连接后需部署新脚本并验证事件可用性，当前不能声称新增事件正在采集。
