# sm8850 (OnePlus Pad 4 / iceland) 主线内核构建仓库

内核 + OOT 模块 + initrd + 网络部署工具链的一体化构建。所有阶段经
`../podman_container/runin.sh` 在容器内执行，产物落到 `../../build/kernel/`。

```
build.sh              构建入口（stage 编排，全部串行、增量）
config                内核 .config（Git 自动 release, clang/LLVM, MODULES=zstd）
linux/                内核源码（gitlink，补丁在 linux 仓库内）
oot/charge_boost/     域外模块 charge_boost_lite（PD 协商）
initrd_debug/         debug initrd 根文件树（NCM + telnetd 调试面）
initrd_charge/        充电 initrd 的 /init（自定义 PD 曲线状态机）
initrd-modules.txt    initrd 精选模块/固件清单（debug 319 模块 + 11 固件）
deploy/               deployd / deployclient / makeblob 源码 + init-net
debian/               五个 deb 包模板（见下）
scripts/              各构建阶段脚本
firmware/             设备固件（bluetooth_a 提取 + map220v/iceland-firmware）
```

构建：`./build.sh`（或 `OUT=... ./build.sh`）。只生成并验证五个 deb 可用
`./build.sh --debs`；中断后用 `./build.sh --from <stage>` 从指定阶段继续，
前置产物必须已完成且与当前源码和配置一致。阶段顺序见 build.sh 头部注释：
build-kernel → build-hdr-tools（arm64 容器）→ pack-headers → build-oot（arm64
容器，原生验证 headers 包）→ build-debs → build-deployd → make-initrd →
make-charge-initrd → make-deploy-net-initrd → build-deploy-tools → pack-images。
内核用 kbuild 原生增量（kbuild 与 kbuild_hdr 两棵树），其余 stage 每次全量重建
（快且确定）。

## 版本与 Debian 包名

`version.env` 定义上游版本 `7.3.1` 和 Debian revision `1`。配置使用
`CONFIG_LOCALVERSION=""`、`CONFIG_LOCALVERSION_AUTO=y`，由上游
`scripts/setlocalversion` 根据 `linux/` 的 tag、提交数、12 位 commit hash
和已跟踪文件的 dirty 状态自动生成 release，不附加手工 `-sm8850` 或 `-iceland`。
正好处于干净的上游版本 tag 时不附加 Git 后缀；未跟踪文件不参与 dirty 判定。
Debian Version 为 `<release>-<revision>`；当前 clean 源码对应
`7.3.1-00082-g3ff36e698404-1`，dirty 时为 `7.3.1-00082-g3ff36e698404-dirty-1`。
五个固定包名是 `linux-image-iceland`、`linux-modules-iceland`、
`linux-headers-iceland`、`linux-tools-iceland` 和 `linux-firmware-iceland`；
例如 `linux-image-iceland_7.3.1-00082-g3ff36e698404-1_arm64.deb`。
hash/dirty 仅出现在版本信息与 release 路径中，不进入 `Package` 字段。
配置、打包脚本或固件变化需递增 Debian revision；dirty 后缀仅描述 `linux/`。
内核、模块、headers 和 perf 的安装路径仍包含完整 release，防止 ABI 混用。
modules 包声明对旧 `linux-modules-7.2.11-sm8850` 公共文件的 Replaces；
旧版内核文件可继续保留，新的五包通过精确版本依赖配套安装。

`debian/` 使用固定目录与 `@KVER@` / `@VERSION@` 模板，
`initrd-modules.txt` 使用 `@KVER@`，构建时生成实际路径清单。
调整配置后运行 `./scripts/normalize-config.sh`，再运行 `./build.sh`；
构建阶段检测到配置漂移会报错。规范化使用与内核构建相同的容器工具链。
同一稳定系列的后续更新使用 `./bump-stable.py 7.3.2`，脚本会更新统一版本入口、
规范化配置并提交三层仓库；跨系列移植仍需要单独审核平台补丁。

7.3 迁移保留本地摄像头、Iris VPU4、pogo 键盘、Gunyah 和 SCMI 改动，
采用 map220v 新版 NT36536 / DSI1 实现。迁移与重放记录见
`patches/platform-sm8850-7.3/README.md`。

7.3.1 使用双父节点合并提交 `3ff36e698404` 合入官方 stable tag `v7.3.1`。
第一父节点为 Iceland `82df006c5421`，第二父节点为 stable `79a907609d53`；
保留平台历史及 TFA9865、camres IRQ 锁修复。

## 启动协议（两种载荷格式）

**BootApp GPT 分区**（ABL/BDS 原生启动，分区 `kernel` / `dtb` / `bootcfg` /
`initrd` / `rootfs`，GPT label 即 PARTNAME）：分区内容 = `[UINT32 LE size][payload]`。
bootcfg payload 是 ini 文本，必须以 `cmdline=` 开头（TestBootApp 解析器要求）。

**TestBootApp RAM 暂存**（`fastboot boot TestBootApp.efi` 之后的 fastboot）：
同样的 `flash bootcfg/kernel/dtb/initrd` 命令，但载荷是 **RAW、无 4 字节前缀**，
只写 RAM，不碰分区；`fastboot continue` 引导。

> 危险：TestBootApp 的 flash 命令发给 ABL fastboot 会以 RAW 格式写真实分区，
> 损坏之。认串口：ABL = `31087C7E`（product `canoe`），TestBootApp = `8B0C705`
> （product `iceland`）。RAM 暂存写入耗时 0.1–0.2s/40MB，真分区写入明显更慢。

## 产物清单（build/kernel/）

| 产物 | 格式 | 用途 |
|---|---|---|
| `kernel.img` | `[u32]`+Image | 刷 kernel 分区；= `bootcfg/kernel.img` |
| `dtb.img` | `[u32]`+FDT | 刷 dtb 分区 |
| `bootcfg_debug.img` | `[u32]`+ini | debug cmdline（tty0 + ignore_loglevel + initcall_debug） |
| `initrd_debug.img` | `[u32]`+cpio.zst | debug initrd：全量精选模块 + 固件 + NCM 192.168.42.42 + telnetd:23 + 串口/framebuffer shell |
| `initrd_charge.img` | `[u32]`+cpio.zst | 充电 initrd：debug 底座 + charge_boost_lite + PD 曲线 |
| `modules.tar.gz` | tar.gz | `/lib/modules/<release>` 全集（含 charge_boost_lite） |
| `headers.tar.gz` | tar.gz | OOT 开发包（build-oot 用它编 charge_boost_lite） |
| `initrd_deploy_net_{release,debug}.cpio.zst` | RAW cpio.zst | 网络部署 initrd（TestBootApp RAM 引导，见下） |
| `debs/*.deb` | deb | image / modules / headers / tools / firmware-iceland 五包（headers 内 scripts/ 工具与 tools 内 perf 均为 arm64 容器原生编译） |
| `tools/makeblob`, `tools/deployclient` | x86 ELF | 主机端打包/推送 |
| `ramdeploy/` | RAW 文件集 | RAM 部署四件套 + `ramdeploy.sh` 一键流式部署 |
| `charge/` | RAW 文件集 | `*_charge.bin` 四件套 + `charge.sh` 一键临时充电启动 |

## deploy blob 协议

`makeblob [-o deploy.blob] <sparse-rootfs.img> [<deb> ...]`（源码
`deploy/makeblob.c`，设备端 `deployd` 直接消费）：

```
[u64 size][sparse rootfs 数据][u32 crc32]     第 1 个 blob，sparse 镜像
[u64 size][deb 数据][u32 crc32] ...           其后每包一个 deb
[u64 0]                                       终止符
```

- CRC32 (IEEE/zlib) 逐 blob 计算；deployclient 把文件**原样字节流**推给 5190 端口。
- 纯软件包更新：`makeblob --no-rootfs ...`，首帧 size=0，deployd 跳过 rootfs
  直写、只走 deb 暂存 + provision（rootfs 不动）。

## rootfs 安装全过程（网络部署）

1. **ABL fastboot**（串口 `31087C7E`）→ `fastboot boot TestBootApp.efi`，
   设备重枚举为 TestBootApp fastboot（`8B0C705`）。
2. **RAM 四件套**（`ramdeploy/ramdeploy.sh <deploy.blob> [debug]`）：
   flash bootcfg/kernel/dtb/initrd（RAW）→ `fastboot continue`。
   initrd = `initrd_deploy_net_{release,debug}.cpio.zst`。
3. **init-net 起网**：configfs NCM gadget，usb0 = 192.168.42.42/24，udhcpd
   给主机发 192.168.42.x，telnetd:23。release 模式成功即自动重启，debug 模式
   永不重启、保持调试面。
4. **deployd**（静态 ARM64，`deploy/deployd.c`，监听 5190）：256KB 窗口流式
   解码 sparse rootfs **直写 rootfs 分区**（不落盘、内存有界），逐 blob 校验
   CRC32；deb 存为 `/debs/blob-N.deb`。主机端：
   `tools/deployclient 192.168.42.42 5190 deploy.blob`（内置 30s 连接重试）。
   实测 3.79GB ≈ 1m55s。
5. **provision**（init-net 内）：挂 rootfs 分区 → 禁用 rootfs 镜像里坏掉的
   dhcpcd initramfs hook → bind /dev /proc /sys → `resize2fs` 扩容 →
   chroot `dpkg -i /root/kernel-debs/blob-*.deb`。
6. **deb postinst 刷分区**（dpkg 失败 = 整体失败 = 不重启）：
   - `linux-image`：刷 kernel 分区 + bootcfg 分区（生产 cmdline：
     `root=/dev/disk/by-partlabel/rootfs ro rootwait console=tty0
     clk_ignore_unused pd_ignore_unused`），再经 /etc/kernel/postinst.d
     重建 Ubuntu initramfs 并由 zz-iceland-flash-initrd 刷 initrd 分区；
   - `linux-firmware-iceland`：刷 dtb 分区 + 安装固件；
   - `linux-modules`：`depmod -a`；
   - `linux-headers`：仅装文件。
   分区定位不依赖 udev：扫 `/sys/class/block/*/uevent` 的 `PARTNAME=<label>`。
7. release 模式 `reboot -f` 进 Ubuntu 桌面。

## 充电启动（临时）

`charge/charge.sh`（设备在 ABL fastboot 时执行）：boot TestBootApp.efi →
RAM 四件套（`*_charge.bin`）→ continue。initrd 行为：
0–5%:9V/2A，5–40%:12V/3A，40–80%:9V/3A，80–90%:9V/2A，≥90%:5V；
charge_boost_lite 全程不卸载，5s 周期控制台遥测（SOC/Vbat/Ibat/Vbus/T），
NCM + telnet:23 可查。

## 已知事项

- **ABL fastboot 在大分区写入后会挂起**：先刷小分区、大分区最后、刷完立即
  重启，不要在写完大分区后再执行任何 fastboot 命令。
- **ktz8869 背光**：enable GPIO 的 -EPROBE_DEFER 死等已修（linux 仓库
  baa5fda60，defer 视作 NULL 继续）。
- dmesg 的 `qcom_battmgr: unknown message 0x33` 是 charge_boost_lite 的
  ICL 设置回包被同 owner 广播到内核态 battmgr 所致，噪音，不影响充电；
  连带 spurious-complete 竞态见分析（遥测偶发旧值，低危）。
- 设备无 RTC 电池，系统时间不可信（journal 按 boot ID 对齐）。
