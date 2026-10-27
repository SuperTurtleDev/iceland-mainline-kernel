# SM8850 / OnePlus Pad 4 (iceland) 平台补丁归档

收集日期：2026-10-27。来源：本地 `linux/` 子仓库已提交历史。

**应用入口为 `series`：86 个补丁从上游 v7.2.11 按序应用成功，结果与当前 HEAD 源码树零差异。** 已在两个独立干净工作树中分别实测 `git apply --index` 和 `git am --no-3way`，均无需三方回退、人工处理或额外补差异。

## 基线与范围

- 平台分支：`oneplus-cami2c`，HEAD `06416a1eae89a50eaa4fc493ce57639cb65936c8`。
- 稳定版基线：`v7.2.11`，`a2de78ee6ed8bf8cd99d177c74865a6e8c3cb6ea`。
- 当前分支共有 **90 个非合并平台提交**：map220v **22** 个、Yibo Wang **42** 个、其他作者配套提交 **26** 个。
- 筛选口径为 **Author 或 Committer 属于 map220v / Yibo Wang**，覆盖两人的已知历史邮箱。原作者与提交者分别记录；`Signed-off-by` 仅作签署信息，不据此推定提交者。
- **26 个第三方作者提交全部由两人提交**：map220v 18 个（SoCCP、GPU、WCN7860、DSI、USB 等），Yibo Wang 8 个（原作者为 `iceland-dev`，涉及 CPU capacity、pogo keyboard、Gunyah）。这些补丁原已保存在 `commits/supporting/`，现新增单独索引及明确归属。
- 90 个历史非合并提交生成 86 个有效应用补丁；4 个已由上游包含的提交不再重复应用，原因见 `already-upstream.json`。原始补丁均保留。
- 3 个 Linux 稳定版合并提交记录于 `merges.json`；合并时的适配已折入对应应用补丁，最终结果与原分支完全一致。
- 另归档 **51 个**仅存在于其他本地分支／已有远端跟踪引用中的作者或提交者匹配项，包含重发、旧版和 WIP；不进入主 `series`。其中本次新增 18 个由 Yibo Wang 提交的第三方作者补丁：Hangxiang Ma 的 CAMSS backport 10 个、`iceland-dev` 的键盘／Gunyah 8 个。
- 本仓库为浅克隆；这里只覆盖现有引用可达的历史，未联网刷新远端，不声称覆盖作者全部公开提交。`refs/stash` 与未提交文件不纳入。

## 文件用途

| 文件 | 用途 |
|---|---|
| `commits/map220v/`、`commits/yibo-wang/` | 两位作者的原始 `git format-patch`，保留作者、日期、消息和 diff |
| `commits/supporting/` | 其他作者的配套平台提交 |
| `series`、`apply/` | 基于 v7.2.11 的可直接顺序应用序列（86 个），已经完整重放验证 |
| `apply-manifest.json`、`apply-commits.tsv` | 应用顺序、原始提交映射、适配说明、每一步预期 tree ID 与校验和 |
| `already-upstream.json` | 4 个已由上游包含、无需重复应用的原始提交 |
| `original.series` | 当前分支 90 个原始补丁的历史拓扑顺序索引；用于溯源，不是 v7.2.11 应用入口 |
| `contributors.series` | Author 或 Committer 匹配两人的原始历史索引（90 个） |
| `third-party-submitted.series`、`third-party-submitted.tsv` | 两人提交的第三方作者补丁（26 个），含独立作者／提交者字段 |
| `authors.series` | 仅两位目标作者的索引；缺少配套提交，不是完整应用序列 |
| `platform-v7.2.11.diff` | `git diff --binary --full-index v7.2.11 HEAD`，恢复当前平台树的完整净差异 |
| `commits.tsv`、`manifest.json` | SHA、Author／Committer 各自的姓名邮箱与日期、标题、路径、patch-id、SHA-256 和引用快照 |
| `alternatives.list`、`alternatives.json`、`alternatives.tsv` | 其他分支候选及其包含引用、与主分支完全相同的 patch-id 对照 |
| `alternatives-third-party-submitted.list` | 其他分支中两人提交的第三方作者补丁索引（18 个） |
| `merges.json` | 未导出为普通补丁的三个稳定版合并提交 |
| `diffstat.txt`、`changed-files.tsv` | 完整净差异的统计与文件清单 |
| `validation.json`、`SHA256SUMS` | 应用验证结果与归档文件校验和 |
| `verify-series.py` | 在独立临时工作树中重放序列，验证每一步及最终树，不修改源仓库 |
| `validation-series-apply.json`、`validation-series-am.json` | 两种顺序应用方式的实测结果（各 86 个补丁） |

## 应用与验证

在干净的上游 `v7.2.11` 内核工作树中执行。精确基线提交为 `a2de78ee6ed8bf8cd99d177c74865a6e8c3cb6ea`。将 `patch_dir` 替换为本归档的绝对路径，按 `series` 顺序应用：

```sh
patch_dir=/path/to/platform-sm8850-7.2.11
while IFS= read -r patch; do
    git apply --check --index "$patch_dir/$patch" || exit 1
    git apply --index --whitespace=nowarn "$patch_dir/$patch" || exit 1
done < "$patch_dir/series"
git write-tree
```

如需同时创建提交，在另一棵同样干净、位于上述基线的工作树中使用：

```sh
patch_dir=/path/to/platform-sm8850-7.2.11
while IFS= read -r patch; do
    git am --no-3way --whitespace=nowarn "$patch_dir/$patch" || exit 1
done < "$patch_dir/series"
git rev-parse 'HEAD^{tree}'
```

两种方式的预期树对象均为 **`bca7d288b38b7fbabe1c87922357694fbc99065f`**，与目标 HEAD `06416a1eae89a50eaa4fc493ce57639cb65936c8` 完全一致，包括文件内容、路径和权限。当前 `linux/` 无未提交变更，故此目标也就是当前工作树。

两份验证报告均记录：86/86 成功、关闭三方回退、每一步 tree ID 符合预期、最终索引及工作树对目标提交 `git diff --exit-code` 通过、差异文件数 0。`git am` 方式还验证生成恰好 86 个提交且工作树干净。

可从归档目录复验（默认使用本项目 `linux/` 的 Git 对象，只读源仓库；其他对象库可用 `--source /path/to/linux` 指定）：

```sh
python3 verify-series.py --method apply
python3 verify-series.py --method am
```

原始历史补丁见 `original.series`；`authors.series`、`contributors.series` 和其他分支候选均用于溯源，不混入应用序列。应用补丁保留原作者、日期、消息，并通过 `X-Original-Commit`、`X-Original-Committer` 及清单记录原提交归属。因适配新基线，生成的提交 SHA 可以不同，源码树必须相同。

基线适配主要包括：电池驱动使用与当前树一致的 `devm_work_autocancel` 初始化；Iris 避免重复注册上游已有的 OPB 属性；DP／DPU 补丁只保留尚未进入上游的改动。没有末尾补差异补丁。

`platform-v7.2.11.diff` 同时保留为完整净差异。它与顺序应用序列结果相同，含所有配套作者的改动及原提交中的文档／调试说明文件。

完整净差异原有的正向／反向验证仍通过；141 个原始／其他分支补丁保留，另有 86 个已顺序重放的应用补丁。此验证不包含编译或设备运行测试。

在归档目录执行 `sha256sum --check SHA256SUMS` 可校验文件完整性。

## 当前分支目标作者提交

| 提交 | 原作者 (Author) | 提交者 (Committer) | 标题 |
|---|---|---|---|
| [`8a10b551846e`](commits/map220v/0007-8a10b551846e-SM8850-Fix-gpuss-thermal-polling-delay.patch) | map220v | map220v | SM8850: Fix gpuss thermal polling delay |
| [`beaffadffca7`](commits/map220v/0008-beaffadffca7-SM8850-Add-SOCCP-nodes.patch) | map220v | map220v | SM8850: Add SOCCP nodes |
| [`a89e7724daf1`](commits/map220v/0009-a89e7724daf1-SM8850-Add-DSI1-nodes.patch) | map220v | map220v | SM8850: Add DSI1 nodes |
| [`afe020923fc8`](commits/map220v/0016-afe020923fc8-SM8850-Add-device-tree-for-OnePlus-Pad-4.patch) | map220v | map220v | SM8850: Add device tree for OnePlus Pad 4 |
| [`e3195e5ffd91`](commits/map220v/0017-e3195e5ffd91-SM8850-Add-sm8850-config-fragment.patch) | map220v | map220v | SM8850: Add sm8850.config fragment |
| [`38a053d131b4`](commits/map220v/0020-38a053d131b4-backlight-Add-KTZ8869-driver-for-iceland.patch) | map220v | map220v | backlight: Add KTZ8869 driver for iceland |
| [`bad9102cb260`](commits/map220v/0021-bad9102cb260-ICELAND-Add-KTZ8869-nodes.patch) | map220v | map220v | ICELAND: Add KTZ8869 nodes |
| [`8430ac47e620`](commits/map220v/0022-8430ac47e620-drm-msm-dpu-Add-missing-rect-offsets-for-Kaanapali-DMA-SSPP.patch) | map220v | map220v | drm/msm/dpu: Add missing rect offsets for Kaanapali DMA SSPP |
| [`66b96f877451`](commits/map220v/0023-66b96f877451-drm-msm-dpu-Fix-Compressed-width-calculation.patch) | map220v | map220v | drm/msm/dpu: Fix Compressed width calculation |
| [`6b790f157d18`](commits/map220v/0024-6b790f157d18-drm-panel-Add-driver-for-NT36536-panels.patch) | map220v | map220v | drm/panel: Add driver for NT36536 panels |
| [`cb5e37b61579`](commits/map220v/0025-cb5e37b61579-ICELAND-Add-panel-node.patch) | map220v | map220v | ICELAND: Add panel node |
| [`d8f0b2f4e40a`](commits/map220v/0026-d8f0b2f4e40a-Input-Add-NT36536-touch-driver.patch) | map220v | map220v | Input: Add NT36536 touch driver |
| [`f43cb00d872e`](commits/map220v/0027-f43cb00d872e-ICELAND-Add-touchscreen-node.patch) | map220v | map220v | ICELAND: Add touchscreen node |
| [`65152354d8ae`](commits/map220v/0028-65152354d8ae-SM8850-Fix-GMU-address.patch) | map220v | map220v | SM8850: Fix GMU address |
| [`4fdc45fcc700`](commits/map220v/0029-4fdc45fcc700-SM8850-Add-cache-info.patch) | map220v | map220v | SM8850: Add cache info |
| [`2bc508d899d0`](commits/map220v/0030-2bc508d899d0-qcom-battmgr-Add-basic-support-for-Kaanapali-OnePlus-SOCCP-FW.patch) | map220v | map220v | qcom_battmgr: Add basic support for Kaanapali OnePlus SOCCP FW |
| [`5f86156d7b81`](commits/map220v/0031-5f86156d7b81-ASoC-Add-simple-TFA9865-driver-Since-TFA9865-and-TFA9864-has-no-DSP-and-container-file-con.patch) | map220v | map220v | ASoC: Add simple TFA9865 driver Since TFA9865 and TFA9864 has no DSP and container file contains only init regs, this basic driver should be good for now. |
| [`be941be03817`](commits/map220v/0032-be941be03817-ICELAND-Add-sound-nodes.patch) | map220v | map220v | ICELAND: Add sound nodes |
| [`39708d9ccc23`](commits/map220v/0033-39708d9ccc23-SM8850-Update-GPU-OPP-table.patch) | map220v | map220v | SM8850: Update GPU OPP table |
| [`d629943c0894`](commits/map220v/0035-d629943c0894-ICELAND-Remove-usb-role-switch.patch) | map220v | map220v | ICELAND: Remove usb-role-switch |
| [`ed9d01daed04`](commits/map220v/0036-ed9d01daed04-ICELAND-Reserve-llcc-lpi-mem-to-fix-Gunyah-crash.patch) | map220v | map220v | ICELAND: Reserve llcc_lpi_mem to fix Gunyah crash |
| [`175302a0a2f9`](commits/map220v/0037-175302a0a2f9-ICELAND-Reserve-adsp-mhi-mem-and-global-sync-mem-Both-have-XN-2-EL1-EL0-NOEXEC-in-VTTBR.patch) | map220v | map220v | ICELAND: Reserve adsp_mhi_mem and global_sync_mem Both have XN=2(EL1&EL0 NOEXEC) in VTTBR |
| [`baa5fda60af0`](commits/yibo-wang/0049-baa5fda60af0-backlight-ktz8869-treat-enable-gpio-defer-as-non-fatal-workaround.patch) | Yibo Wang | Yibo Wang | backlight: ktz8869 - treat enable gpio defer as non-fatal (workaround) |
| [`cedbce88b66f`](commits/yibo-wang/0050-cedbce88b66f-Revert-backlight-ktz8869-treat-enable-gpio-defer-as-non-fatal-workaround.patch) | Yibo Wang | Yibo Wang | Revert "backlight: ktz8869 - treat enable gpio defer as non-fatal (workaround)" |
| [`aa2aab052619`](commits/yibo-wang/0051-aa2aab052619-arm64-dts-qcom-kaanapali-drop-duplicate-enable-gpios-from-second-ktz8869-node.patch) | Yibo Wang | Yibo Wang | arm64: dts: qcom: kaanapali: drop duplicate enable-gpios from second ktz8869 node |
| [`2a73922c776a`](commits/yibo-wang/0052-2a73922c776a-PCI-pwrctrl-default-PCI-PWRCTRL-PWRSEQ-to-y-on-qcom.patch) | Yibo Wang | Yibo Wang | PCI: pwrctrl: default PCI_PWRCTRL_PWRSEQ to y on qcom |
| [`81b77fb34a63`](commits/yibo-wang/0053-81b77fb34a63-backlight-ktz8869-fetch-vddio-as-an-optional-regulator.patch) | Yibo Wang | Yibo Wang | backlight: ktz8869: fetch vddio as an optional regulator |
| [`600503179d80`](commits/yibo-wang/0054-600503179d80-Revert-backlight-ktz8869-fetch-vddio-as-an-optional-regulator.patch) | Yibo Wang | Yibo Wang | Revert "backlight: ktz8869: fetch vddio as an optional regulator" |
| [`03be252e7197`](commits/yibo-wang/0055-03be252e7197-firmware-arm-scmi-quirk-skip-P2A-CHANNEL-FREE-ack-for-Qualcomm-CPUCP.patch) | Yibo Wang | Yibo Wang | firmware: arm_scmi: quirk: skip P2A CHANNEL_FREE ack for Qualcomm CPUCP |
| [`7a8c303db897`](commits/yibo-wang/0056-7a8c303db897-arm64-dts-qcom-iceland-RTC-offset-cell-in-SDAM2-for-time-persistence.patch) | Yibo Wang | Yibo Wang | arm64: dts: qcom: iceland: RTC offset cell in SDAM2 for time persistence |
| [`af65f2a632d2`](commits/yibo-wang/0057-af65f2a632d2-media-qcom-iceland-camera-bring-up-Kaanapali-CAMSS-SmartSens-SC-sensors.patch) | Yibo Wang | Yibo Wang | media: qcom: iceland camera bring-up: Kaanapali CAMSS + SmartSens SC sensors |
| [`9e31a5791e78`](commits/yibo-wang/0058-9e31a5791e78-media-qcom-iceland-camera-follow-up-AF-actuator-flash-CSIPHY-supplies.patch) | Yibo Wang | Yibo Wang | media: qcom: iceland camera follow-up: AF actuator, flash, CSIPHY supplies |
| [`dfa968065e58`](commits/yibo-wang/0059-dfa968065e58-media-i2c-dw9719-DW9714V-SAC-tuning-from-the-vendor-actuator-init.patch) | Yibo Wang | Yibo Wang | media: i2c: dw9719: DW9714V SAC tuning from the vendor actuator init |
| [`e585d5621c60`](commits/yibo-wang/0060-e585d5621c60-media-qcom-iceland-declare-camera-orientation-fix-mirrored-rear-image.patch) | Yibo Wang | Yibo Wang | media: qcom: iceland: declare camera orientation, fix mirrored rear image |
| [`cb23870f29a2`](commits/yibo-wang/0061-cb23870f29a2-arm64-dts-qcom-kaanapali-asymmetric-CPU-capacity-from-the-vendor-calibration.patch) | Yibo Wang | Yibo Wang | arm64: dts: qcom: kaanapali: asymmetric CPU capacity from the vendor calibration |
| [`a6e51c9ce179`](commits/yibo-wang/0062-a6e51c9ce179-media-qcom-iris-Kaanapali-VPU4-video-codec-support-for-iceland.patch) | Yibo Wang | Yibo Wang | media: qcom: iris: Kaanapali (VPU4) video codec support for iceland |
| [`4f92b7d7df62`](commits/yibo-wang/0063-4f92b7d7df62-remoteproc-qcom-q6v5-quiet-repeated-handover-interrupts.patch) | Yibo Wang | Yibo Wang | remoteproc: qcom_q6v5: quiet repeated handover interrupts |
| [`2201139167a5`](commits/yibo-wang/0064-2201139167a5-power-supply-qcom-battmgr-compute-power-now-on-kaanapali.patch) | Yibo Wang | Yibo Wang | power: supply: qcom_battmgr: compute power_now on kaanapali |
| [`c0e9662bef2d`](commits/yibo-wang/0065-c0e9662bef2d-drm-msm-dpu-fix-black-screen-after-refresh-rate-modeset-on-dual-DSI.patch) | Yibo Wang | Yibo Wang | drm/msm/dpu: fix black screen after refresh-rate modeset on dual-DSI |
| [`ce3e266f9e04`](commits/yibo-wang/0066-ce3e266f9e04-arm64-dts-qcom-kaanapali-revert-PCIe-iommu-map-to-1-cell-format.patch) | Yibo Wang | Yibo Wang | arm64: dts: qcom: kaanapali: revert PCIe iommu-map to 1-cell format |
| [`5f7fdae6d0e5`](commits/yibo-wang/0067-5f7fdae6d0e5-drm-panel-nt36536-add-50-48-Hz-modes-drop-unreachable-144-Hz.patch) | Yibo Wang | Yibo Wang | drm/panel: nt36536: add 50/48 Hz modes, drop unreachable 144 Hz |
| [`c11a4291b27d`](commits/yibo-wang/0068-c11a4291b27d-drm-panel-nt36536-restore-the-144-Hz-mode-on-iceland.patch) | Yibo Wang | Yibo Wang | drm/panel: nt36536: restore the 144 Hz mode on iceland |
| [`b84d67fc6afa`](commits/yibo-wang/0069-b84d67fc6afa-Revert-drm-msm-a6xx-Fix-stale-rpmh-votes-after-suspend.patch) | Yibo Wang | Yibo Wang | Revert "drm/msm/a6xx: Fix stale rpmh votes after suspend" |
| [`81243488c7b8`](commits/yibo-wang/0070-81243488c7b8-soc-qcom-oplus-camres-shared-camera-I2C-bus-manager-AP-SEE.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres — shared camera I2C bus manager (AP/SEE) |
| [`9f35ddcd2f54`](commits/yibo-wang/0071-9f35ddcd2f54-soc-qcom-oplus-camres-restrict-force-sysfs-knobs-to-CAP-SYS-ADMIN.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: restrict force sysfs knobs to CAP_SYS_ADMIN |
| [`e5437354cad3`](commits/yibo-wang/0072-e5437354cad3-soc-qcom-oplus-camres-event-driven-SNS-receive-path.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: event-driven SNS receive path |
| [`da9dd1f65df5`](commits/yibo-wang/0073-da9dd1f65df5-Input-remove-the-v2-pogo-keyboard-driver-replaced-by-the-v3-series.patch) | Yibo Wang | Yibo Wang | Input: remove the v2 pogo-keyboard driver (replaced by the v3 series) |
| [`f9e801c2a0b7`](commits/yibo-wang/0074-f9e801c2a0b7-dt-bindings-input-add-OnePlus-pogo-pin-keyboard.patch) | Yibo Wang | Yibo Wang | dt-bindings: input: add OnePlus pogo-pin keyboard |
| [`1b3df9532919`](commits/yibo-wang/0075-1b3df9532919-Input-add-OnePlus-OPPO-Pad-pogo-pin-keyboard-serdev-driver.patch) | Yibo Wang | Yibo Wang | Input: add OnePlus/OPPO Pad pogo-pin keyboard serdev driver |
| [`c624cf890723`](commits/yibo-wang/0076-c624cf890723-arm64-dts-qcom-iceland-pogo-keyboard-node-for-the-v3-binding.patch) | Yibo Wang | Yibo Wang | arm64: dts: qcom: iceland: pogo keyboard node for the v3 binding |
| [`4529d5096a85`](commits/yibo-wang/0077-4529d5096a85-soc-qcom-oplus-camres-corrected-SEE-session-bring-up-and-REVOKE-takeover.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: corrected SEE session bring-up and REVOKE takeover |
| [`2e439c2338c1`](commits/yibo-wang/0078-2e439c2338c1-soc-qcom-oplus-camres-self-classify-the-no-handshake-SEE-drop-quiet-mode.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: self-classify the no-handshake SEE, drop quiet mode |
| [`89ef9e4c6e0b`](commits/yibo-wang/0079-89ef9e4c6e0b-soc-qcom-oplus-camres-fd-driven-state-machine-exact-boundary-child-hooks.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: fd-driven state machine, exact-boundary child hooks |
| [`dba210f9568d`](commits/yibo-wang/0080-dba210f9568d-soc-qcom-oplus-camres-fix-boot-ordering-AON-subscribe-needs-a-free-bus.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: fix boot ordering — AON subscribe needs a free bus |
| [`81e1c6b3677d`](commits/yibo-wang/0081-81e1c6b3677d-soc-qcom-oplus-camres-five-fixes-from-self-review.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: five fixes from self-review |
| [`a81556edac54`](commits/yibo-wang/0082-a81556edac54-soc-qcom-oplus-camres-fixes-from-subagent-audit.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: fixes from subagent audit |
| [`7b7e12620161`](commits/yibo-wang/0083-7b7e12620161-soc-qcom-oplus-camres-ap-hold-DEINIT-manual-vote-policy-drop-boot-retry.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: ap_hold/DEINIT manual-vote policy, drop boot retry |
| [`c5cf65eef19e`](commits/yibo-wang/0084-c5cf65eef19e-soc-qcom-oplus-camres-document-the-park-while-CONFIGURING-loop.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: document the park-while-CONFIGURING loop |
| [`a434f155340a`](commits/yibo-wang/0085-a434f155340a-soc-qcom-oplus-camres-clear-PM-runtime-error-on-state-recovery.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: clear PM runtime_error on state recovery |
| [`4c743c779b1b`](commits/yibo-wang/0086-4c743c779b1b-soc-qcom-oplus-camres-unified-vote-architecture-protocol-identical-to-v1.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: unified vote architecture + protocol identical to v1 |
| [`14458640b1d9`](commits/yibo-wang/0087-14458640b1d9-dt-bindings-media-i2c-dongwoon-dw9719-Document-the-DW9714V.patch) | Yibo Wang | Yibo Wang | dt-bindings: media: i2c: dongwoon,dw9719: Document the DW9714V |
| [`e9b66e94bc57`](commits/yibo-wang/0088-e9b66e94bc57-media-i2c-dw9719-Add-DW9714V-support.patch) | Yibo Wang | Yibo Wang | media: i2c: dw9719: Add DW9714V support |
| [`87b96a2a8dfc`](commits/yibo-wang/0089-87b96a2a8dfc-arm64-dts-qcom-kaanapali-oneplus-iceland-Tune-the-rear-AF-actuator.patch) | Yibo Wang | Yibo Wang | arm64: dts: qcom: kaanapali-oneplus-iceland: Tune the rear AF actuator |
| [`06416a1eae89`](commits/yibo-wang/0090-06416a1eae89-virt-gunyah-Add-runtime-protected-share-GuestAccept-ioctls.patch) | Yibo Wang | Yibo Wang | virt: gunyah: Add runtime protected share (GuestAccept) ioctls |

## 两人提交的第三方作者补丁（当前分支）

下表直接依据 Git 的 Author 与 Committer 字段。原始邮件补丁保留原作者；提交者信息见清单，未改写作者归属。

| 提交 | 原作者 (Author) | 提交者 (Committer) | 标题 |
|---|---|---|---|
| [`e40142cfa314`](commits/supporting/0001-e40142cfa314-remoteproc-qcom-pas-Add-late-attach-support-for-subsystems.patch) | Jingyi Wang | map220v | remoteproc: qcom: pas: Add late attach support for subsystems |
| [`9de9261f09df`](commits/supporting/0002-9de9261f09df-remoteproc-qcom-q6v5-pas-Add-SoCCP-node-on-Kaanapali.patch) | Jingyi Wang | map220v | remoteproc: qcom_q6v5_pas: Add SoCCP node on Kaanapali |
| [`84367cda4bc5`](commits/supporting/0003-84367cda4bc5-arm64-dts-qcom-kaanapali-add-the-GPU-SMMU-node.patch) | Qingqing Zhou | map220v | arm64: dts: qcom: kaanapali: add the GPU SMMU node |
| [`5828f9e0a528`](commits/supporting/0004-5828f9e0a528-arm64-dts-qcom-kaanapali-Add-qfprom-node.patch) | Jingyi Wang | map220v | arm64: dts: qcom: kaanapali: Add qfprom node |
| [`9757148c5bb1`](commits/supporting/0005-9757148c5bb1-arm64-dts-qcom-Add-GPU-support-for-Kaanapali.patch) | Akhil P Oommen | map220v | arm64: dts: qcom: Add GPU support for Kaanapali |
| [`856c9a5d76e2`](commits/supporting/0006-856c9a5d76e2-arm64-dts-qcom-kaanapali-Add-GPU-cooling.patch) | Gaurav Kohli | map220v | arm64: dts: qcom: kaanapali: Add GPU cooling |
| [`bf079c30d01f`](commits/supporting/0010-bf079c30d01f-wifi-ath12k-add-initial-hardware-definition-for-WCN7860.patch) | Teguh Sobirin | map220v | wifi: ath12k: add initial hardware definition for WCN7860 |
| [`64258447b10f`](commits/supporting/0011-64258447b10f-wifi-ath12k-send-QDSS-config-when-CNSS-QDSS-CFG-MISS-V01-is-disabled.patch) | Gianni Spadoni | map220v | wifi: ath12k: send QDSS config when CNSS_QDSS_CFG_MISS_V01 is disabled |
| [`1b693cd9928c`](commits/supporting/0012-1b693cd9928c-wifi-ath12k-disable-CNSS-QDSS-CFG-MISS-V01-for-the-WCN7860.patch) | Gianni Spadoni | map220v | wifi: ath12k: disable CNSS_QDSS_CFG_MISS_V01 for the WCN7860 |
| [`c72982d5ad79`](commits/supporting/0013-c72982d5ad79-PCI-pwrctrl-pwrseq-add-support-for-WCN7860.patch) | Teguh Sobirin | map220v | PCI/pwrctrl: pwrseq: add support for WCN7860 |
| [`719fa465db93`](commits/supporting/0014-719fa465db93-power-sequencing-qcom-wcn-add-support-for-WCN7860.patch) | Teguh Sobirin | map220v | power: sequencing: qcom-wcn: add support for WCN7860 |
| [`1568c3ce3502`](commits/supporting/0015-1568c3ce3502-Bluetooth-qca-add-WCN7860-support.patch) | Teguh Sobirin | map220v | Bluetooth: qca: add WCN7860 support |
| [`972c7a104c94`](commits/supporting/0018-972c7a104c94-drm-msm-dsi-change-sync-mode-to-sync-on-DSI0-rather-than-DSI1.patch) | Dmitry Baryshkov | map220v | drm/msm/dsi: change sync mode to sync on DSI0 rather than DSI1 |
| [`e7765030a49d`](commits/supporting/0019-e7765030a49d-drm-msm-dsi-support-DSC-configurations-with-slice-per-pkt-1.patch) | Jonathan Marek | map220v | drm/msm/dsi: support DSC configurations with slice_per_pkt > 1 |
| [`089225f217af`](commits/supporting/0034-089225f217af-arm64-dts-qcom-kaanapali-Add-missing-properties-to-usb-controller.patch) | Krishna Kurapati | map220v | arm64: dts: qcom: kaanapali: Add missing properties to usb controller |
| [`696975ebf0e4`](commits/supporting/0038-696975ebf0e4-drm-msm-dpu-Drop-sneaky-dev-pm-opp-set-rate-0.patch) | Konrad Dybcio | map220v | drm/msm/dpu: Drop sneaky dev_pm_opp_set_rate(0) |
| [`331d7eefa2aa`](commits/supporting/0039-331d7eefa2aa-drm-msm-dp-Drop-dev-pm-opp-set-rate-0.patch) | Konrad Dybcio | map220v | drm/msm/dp: Drop dev_pm_opp_set_rate(0) |
| [`bc3e5fc83c9c`](commits/supporting/0040-bc3e5fc83c9c-drm-msm-dsi-Drop-dev-pm-opp-set-rate-0.patch) | Konrad Dybcio | map220v | drm/msm/dsi: Drop dev_pm_opp_set_rate(0) |
| [`7e578f0121e1`](commits/supporting/0041-7e578f0121e1-arm64-dts-qcom-kaanapali-add-cpu-capacity-dmips-mhz-EAS-capacity-hints-cpupm-work.patch) | iceland-dev | Yibo Wang | arm64: dts: qcom: kaanapali: add cpu capacity-dmips-mhz (EAS capacity hints, cpupm work) |
| [`4e9b716912e0`](commits/supporting/0042-4e9b716912e0-arm64-dts-qcom-kaanapali-add-uart17-and-wire-the-OnePlus-Pad-4-pogo-keyboard.patch) | iceland-dev | Yibo Wang | arm64: dts: qcom: kaanapali: add uart17 and wire the OnePlus Pad 4 pogo keyboard |
| [`a862a8973f65`](commits/supporting/0043-a862a8973f65-Input-add-OnePlus-OPPO-Pad-pogo-pin-keyboard-serdev-driver.patch) | iceland-dev | Yibo Wang | Input: add OnePlus/OPPO Pad pogo-pin keyboard serdev driver |
| [`645096c6bbc1`](commits/supporting/0044-645096c6bbc1-virt-gunyah-import-Gunyah-hypervisor-drivers-from-android17-6-18.patch) | iceland-dev | Yibo Wang | virt: gunyah: import Gunyah hypervisor drivers from android17-6.18 |
| [`d552aaff3771`](commits/supporting/0045-d552aaff3771-Input-oneplus-pogo-kbd-fix-link-loss-after-attach-and-stuck-re-detection.patch) | iceland-dev | Yibo Wang | Input: oneplus-pogo-kbd: fix link loss after attach and stuck re-detection |
| [`fceb74ea1552`](commits/supporting/0046-fceb74ea1552-Input-oneplus-pogo-kbd-expose-the-keyboard-backlight-as-a-LED-class-device.patch) | iceland-dev | Yibo Wang | Input: oneplus-pogo-kbd: expose the keyboard backlight as a LED class device |
| [`91d78aa40296`](commits/supporting/0047-91d78aa40296-virt-gunyah-adapt-to-mainline-7-2.patch) | iceland-dev | Yibo Wang | virt: gunyah: adapt to mainline 7.2 |
| [`56944665c1a3`](commits/supporting/0048-56944665c1a3-tools-virt-gunyah-add-VM-smoke-test-and-record-verification-results.patch) | iceland-dev | Yibo Wang | tools: virt: gunyah: add VM smoke test and record verification results |

## 其他分支候选（未纳入主序列）

收集 Author 或 Committer 匹配项。patch-id 相同只表示补丁差异相同；未匹配不等于应当应用，可能是不同版本或被后续实现覆盖。具体引用见 `alternatives.json`。

| 提交 | 原作者 (Author) | 提交者 (Committer) | 标题 | 主分支相同 patch-id |
|---|---|---|---|---|
| [`6bacfd50d522`](alternatives/map220v/0001-6bacfd50d522-media-i2c-Add-OV32D40-image-sensor-driver.patch) | map220v | bluseliu50 | media: i2c: Add OV32D40 image sensor driver | 未匹配；需单独评估 |
| [`469a19821136`](alternatives/yibo-wang/0002-469a19821136-firmware-arm-scmi-quirk-skip-P2A-CHANNEL-FREE-ack-for-Qualcomm-CPUCP.patch) | Yibo Wang | Yibo Wang | firmware: arm_scmi: quirk: skip P2A CHANNEL_FREE ack for Qualcomm CPUCP | 03be252e7197 |
| [`0f8951a1a28f`](alternatives/third-party-submitted/0034-0f8951a1a28f-arm64-dts-qcom-kaanapali-add-uart17-and-wire-the-OnePlus-Pad-4-pogo-keyboard.patch) | iceland-dev | Yibo Wang | arm64: dts: qcom: kaanapali: add uart17 and wire the OnePlus Pad 4 pogo keyboard | 4e9b716912e0 |
| [`9a21ac268861`](alternatives/third-party-submitted/0035-9a21ac268861-Input-add-OnePlus-OPPO-Pad-pogo-pin-keyboard-serdev-driver.patch) | iceland-dev | Yibo Wang | Input: add OnePlus/OPPO Pad pogo-pin keyboard serdev driver | a862a8973f65 |
| [`d2b84d01ae8a`](alternatives/third-party-submitted/0036-d2b84d01ae8a-Input-oneplus-pogo-kbd-fix-link-loss-after-attach-and-stuck-re-detection.patch) | iceland-dev | Yibo Wang | Input: oneplus-pogo-kbd: fix link loss after attach and stuck re-detection | d552aaff3771 |
| [`c040c2a89578`](alternatives/third-party-submitted/0037-c040c2a89578-Input-oneplus-pogo-kbd-expose-the-keyboard-backlight-as-a-LED-class-device.patch) | iceland-dev | Yibo Wang | Input: oneplus-pogo-kbd: expose the keyboard backlight as a LED class device | fceb74ea1552 |
| [`c4abca95007b`](alternatives/third-party-submitted/0038-c4abca95007b-virt-gunyah-import-Gunyah-hypervisor-drivers-from-android17-6-18.patch) | iceland-dev | Yibo Wang | virt: gunyah: import Gunyah hypervisor drivers from android17-6.18 | 645096c6bbc1 |
| [`dbe63e43847b`](alternatives/third-party-submitted/0039-dbe63e43847b-virt-gunyah-adapt-to-mainline-7-2.patch) | iceland-dev | Yibo Wang | virt: gunyah: adapt to mainline 7.2 | 91d78aa40296 |
| [`fd503a492d38`](alternatives/third-party-submitted/0040-fd503a492d38-tools-virt-gunyah-add-VM-smoke-test-and-record-verification-results.patch) | iceland-dev | Yibo Wang | tools: virt: gunyah: add VM smoke test and record verification results | 56944665c1a3 |
| [`a14184f58147`](alternatives/yibo-wang/0003-a14184f58147-firmware-arm-scmi-quirk-skip-P2A-CHANNEL-FREE-ack-for-Qualcomm-CPUCP.patch) | Yibo Wang | Yibo Wang | firmware: arm_scmi: quirk: skip P2A CHANNEL_FREE ack for Qualcomm CPUCP | 03be252e7197 |
| [`1d9b86fe5c8d`](alternatives/yibo-wang/0004-1d9b86fe5c8d-rtc-pm8xxx-use-s64-offset-for-full-Unix-timestamp-range.patch) | Yibo Wang | Yibo Wang | rtc: pm8xxx: use s64 offset for full Unix timestamp range | 未匹配；需单独评估 |
| [`ecda847706d2`](alternatives/third-party-submitted/0041-ecda847706d2-BACKPORT-media-dt-bindings-Add-CAMSS-device-for-Kaanapali-lore-https-lore-kernel-org-r-202.patch) | Hangxiang Ma | Yibo Wang | BACKPORT: media: dt-bindings: Add CAMSS device for Kaanapali (lore: https://lore.kernel.org/r/20260601-kaanapali-camss-v14-0-e76f26aa6691@oss.qualcomm.com) | 未匹配；需单独评估 |
| [`1bdb5a2fab78`](alternatives/third-party-submitted/0042-1bdb5a2fab78-BACKPORT-media-qcom-camss-Add-Kaanapali-compatible-camss-driver-lore-https-lore-kernel-org.patch) | Hangxiang Ma | Yibo Wang | BACKPORT: media: qcom: camss: Add Kaanapali compatible camss driver (lore: https://lore.kernel.org/r/20260601-kaanapali-camss-v14-0-e76f26aa6691@oss.qualcomm.com) | 未匹配；需单独评估 |
| [`3119da4089bf`](alternatives/third-party-submitted/0043-3119da4089bf-BACKPORT-media-qcom-camss-csiphy-Add-support-for-v2-4-0-two-phase-CSIPHY-lore-https-lore-k.patch) | Hangxiang Ma | Yibo Wang | BACKPORT: media: qcom: camss: csiphy: Add support for v2.4.0 two-phase CSIPHY (lore: https://lore.kernel.org/r/20260601-kaanapali-camss-v14-0-e76f26aa6691@oss.qualcomm.com) | 未匹配；需单独评估 |
| [`104e98d14bda`](alternatives/third-party-submitted/0044-104e98d14bda-BACKPORT-media-qcom-camss-csid-Add-support-for-CSID-gen4-lore-https-lore-kernel-org-r-2026.patch) | Hangxiang Ma | Yibo Wang | BACKPORT: media: qcom: camss: csid: Add support for CSID gen4 (lore: https://lore.kernel.org/r/20260601-kaanapali-camss-v14-0-e76f26aa6691@oss.qualcomm.com) | 未匹配；需单独评估 |
| [`d58f3fe013cf`](alternatives/third-party-submitted/0045-d58f3fe013cf-BACKPORT-media-qcom-camss-vfe-Add-support-for-VFE-gen4-lore-https-lore-kernel-org-r-202606.patch) | Hangxiang Ma | Yibo Wang | BACKPORT: media: qcom: camss: vfe: Add support for VFE gen4 (lore: https://lore.kernel.org/r/20260601-kaanapali-camss-v14-0-e76f26aa6691@oss.qualcomm.com) | 未匹配；需单独评估 |
| [`17d42e63847e`](alternatives/third-party-submitted/0046-17d42e63847e-BACKPORT-media-dt-bindings-Add-CAMSS-device-for-SM8750-lore-https-lore-kernel-org-r-202606.patch) | Hangxiang Ma | Yibo Wang | BACKPORT: media: dt-bindings: Add CAMSS device for SM8750 (lore: https://lore.kernel.org/r/20260601-add-support-for-camss-on-sm8750-v5-0-dac36a190de8@oss.qualcomm.com) | 未匹配；需单独评估 |
| [`a46c4fba7303`](alternatives/third-party-submitted/0047-a46c4fba7303-BACKPORT-media-qcom-camss-Add-SM8750-compatible-camss-driver-lore-https-lore-kernel-org-r-.patch) | Hangxiang Ma | Yibo Wang | BACKPORT: media: qcom: camss: Add SM8750 compatible camss driver (lore: https://lore.kernel.org/r/20260601-add-support-for-camss-on-sm8750-v5-0-dac36a190de8@oss.qualcomm.com) | 未匹配；需单独评估 |
| [`d3e945185331`](alternatives/third-party-submitted/0048-d3e945185331-BACKPORT-media-qcom-camss-csiphy-Add-support-for-v2-3-0-two-phase-CSIPHY-lore-https-lore-k.patch) | Hangxiang Ma | Yibo Wang | BACKPORT: media: qcom: camss: csiphy: Add support for v2.3.0 two-phase CSIPHY (lore: https://lore.kernel.org/r/20260601-add-support-for-camss-on-sm8750-v5-0-dac36a190de8@oss.qualcomm.com) | 未匹配；需单独评估 |
| [`c68c5ca7bc47`](alternatives/third-party-submitted/0049-c68c5ca7bc47-BACKPORT-media-qcom-camss-csid-Add-support-for-CSID-980-lore-https-lore-kernel-org-r-20260.patch) | Hangxiang Ma | Yibo Wang | BACKPORT: media: qcom: camss: csid: Add support for CSID 980 (lore: https://lore.kernel.org/r/20260601-add-support-for-camss-on-sm8750-v5-0-dac36a190de8@oss.qualcomm.com) | 未匹配；需单独评估 |
| [`943cbadc211f`](alternatives/third-party-submitted/0050-943cbadc211f-BACKPORT-media-qcom-camss-vfe-Add-support-for-VFE-980-lore-https-lore-kernel-org-r-2026060.patch) | Hangxiang Ma | Yibo Wang | BACKPORT: media: qcom: camss: vfe: Add support for VFE 980 (lore: https://lore.kernel.org/r/20260601-add-support-for-camss-on-sm8750-v5-0-dac36a190de8@oss.qualcomm.com) | 未匹配；需单独评估 |
| [`2a7197cd5fe7`](alternatives/yibo-wang/0005-2a7197cd5fe7-WIP-camera-bring-up-iceland-DT-wiring-sc1300cs-probe-driver.patch) | Yibo Wang | Yibo Wang | WIP: camera bring-up: iceland DT wiring + sc1300cs probe driver | 未匹配；需单独评估 |
| [`d5ff9063961a`](alternatives/yibo-wang/0006-d5ff9063961a-WIP-sc1300cs-bring-up-diagnostics-power-hold-bus-scan-on-ID-failure.patch) | Yibo Wang | Yibo Wang | WIP: sc1300cs bring-up diagnostics (power-hold + bus scan on ID failure) | 未匹配；需单独评估 |
| [`1f1df99c980e`](alternatives/yibo-wang/0007-1f1df99c980e-media-qcom-iris-Kaanapali-VPU4-video-codec-support-for-iceland.patch) | Yibo Wang | Yibo Wang | media: qcom: iris: Kaanapali (VPU4) video codec support for iceland | a6e51c9ce179 |
| [`811954758c03`](alternatives/third-party-submitted/0051-811954758c03-arm64-dts-qcom-kaanapali-add-uart17-and-wire-the-OnePlus-Pad-4-pogo-keyboard.patch) | iceland-dev | Yibo Wang | arm64: dts: qcom: kaanapali: add uart17 and wire the OnePlus Pad 4 pogo keyboard | 未匹配；需单独评估 |
| [`f95ec4dd8f5f`](alternatives/yibo-wang/0008-f95ec4dd8f5f-dt-bindings-input-add-OnePlus-pogo-pin-keyboard-binding.patch) | Yibo Wang | Yibo Wang | dt-bindings: input: add OnePlus pogo-pin keyboard binding | 未匹配；需单独评估 |
| [`6978c2a92061`](alternatives/yibo-wang/0009-6978c2a92061-Input-add-OnePlus-OPPO-Pad-pogo-pin-keyboard-serdev-driver.patch) | Yibo Wang | Yibo Wang | Input: add OnePlus/OPPO Pad pogo-pin keyboard serdev driver | 未匹配；需单独评估 |
| [`fe676efa9588`](alternatives/yibo-wang/0010-fe676efa9588-dt-bindings-input-add-OnePlus-pogo-pin-keyboard.patch) | Yibo Wang | Yibo Wang | dt-bindings: input: add OnePlus pogo-pin keyboard | 未匹配；需单独评估 |
| [`3511ee4409e4`](alternatives/yibo-wang/0011-3511ee4409e4-Input-add-OnePlus-OPPO-Pad-pogo-pin-keyboard-serdev-driver.patch) | Yibo Wang | Yibo Wang | Input: add OnePlus/OPPO Pad pogo-pin keyboard serdev driver | 未匹配；需单独评估 |
| [`d95e1fc9de2b`](alternatives/yibo-wang/0012-d95e1fc9de2b-arm64-dts-qcom-kaanapali-revert-PCIe-iommu-map-to-1-cell-format.patch) | Yibo Wang | Yibo Wang | arm64: dts: qcom: kaanapali: revert PCIe iommu-map to 1-cell format | ce3e266f9e04 |
| [`68828a4e7a6d`](alternatives/yibo-wang/0013-68828a4e7a6d-media-qcom-iceland-camera-bring-up-Kaanapali-CAMSS-SmartSens-SC-sensors.patch) | Yibo Wang | Yibo Wang | media: qcom: iceland camera bring-up: Kaanapali CAMSS + SmartSens SC sensors | af65f2a632d2 |
| [`01d193790c4f`](alternatives/yibo-wang/0014-01d193790c4f-media-qcom-iceland-camera-follow-up-AF-actuator-flash-CSIPHY-supplies.patch) | Yibo Wang | Yibo Wang | media: qcom: iceland camera follow-up: AF actuator, flash, CSIPHY supplies | 9e31a5791e78 |
| [`69c0b0063c72`](alternatives/yibo-wang/0015-69c0b0063c72-media-i2c-dw9719-DW9714V-SAC-tuning-from-the-vendor-actuator-init.patch) | Yibo Wang | Yibo Wang | media: i2c: dw9719: DW9714V SAC tuning from the vendor actuator init | dfa968065e58 |
| [`cc9c7c98d9da`](alternatives/yibo-wang/0016-cc9c7c98d9da-media-qcom-iceland-declare-camera-orientation-fix-mirrored-rear-image.patch) | Yibo Wang | Yibo Wang | media: qcom: iceland: declare camera orientation, fix mirrored rear image | e585d5621c60 |
| [`4bae7c0a5461`](alternatives/yibo-wang/0017-4bae7c0a5461-soc-qcom-oplus-camres-shared-camera-I2C-bus-manager-AP-SEE.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres — shared camera I2C bus manager (AP/SEE) | 81243488c7b8 |
| [`8d235662ecc0`](alternatives/yibo-wang/0018-8d235662ecc0-soc-qcom-oplus-camres-restrict-force-sysfs-knobs-to-CAP-SYS-ADMIN.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: restrict force sysfs knobs to CAP_SYS_ADMIN | 9f35ddcd2f54 |
| [`d8ed13a7fc2e`](alternatives/yibo-wang/0019-d8ed13a7fc2e-soc-qcom-oplus-camres-event-driven-SNS-receive-path.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: event-driven SNS receive path | e5437354cad3 |
| [`c815f01ceb8e`](alternatives/yibo-wang/0020-c815f01ceb8e-soc-qcom-oplus-camres-corrected-SEE-session-bring-up-and-REVOKE-takeover.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: corrected SEE session bring-up and REVOKE takeover | 4529d5096a85 |
| [`399b30a55af3`](alternatives/yibo-wang/0021-399b30a55af3-soc-qcom-oplus-camres-self-classify-the-no-handshake-SEE-drop-quiet-mode.patch) | Yibo Wang | Yibo Wang | soc: qcom: oplus-camres: self-classify the no-handshake SEE, drop quiet mode | 2e439c2338c1 |
| [`5a879a569c22`](alternatives/yibo-wang/0022-5a879a569c22-dt-bindings-input-add-OnePlus-pogo-pin-keyboard.patch) | Yibo Wang | Yibo Wang | dt-bindings: input: add OnePlus pogo-pin keyboard | 未匹配；需单独评估 |
| [`a1f5cd88a406`](alternatives/yibo-wang/0023-a1f5cd88a406-Input-add-OnePlus-OPPO-Pad-pogo-pin-keyboard-serdev-driver.patch) | Yibo Wang | Yibo Wang | Input: add OnePlus/OPPO Pad pogo-pin keyboard serdev driver | 1b3df9532919 |
| [`d5e8583b9900`](alternatives/yibo-wang/0024-d5e8583b9900-dt-bindings-media-i2c-dongwoon-dw9719-Document-DW9714V.patch) | Yibo Wang | Yibo Wang | dt-bindings: media: i2c: dongwoon,dw9719: Document DW9714V | 未匹配；需单独评估 |
| [`8d9289f52567`](alternatives/yibo-wang/0025-8d9289f52567-media-i2c-dw9719-Add-DW9714V-support.patch) | Yibo Wang | Yibo Wang | media: i2c: dw9719: Add DW9714V support | 未匹配；需单独评估 |
| [`eb66d56acbd7`](alternatives/yibo-wang/0026-eb66d56acbd7-dt-bindings-media-i2c-dongwoon-dw9719-Document-DW9714VA.patch) | Yibo Wang | Yibo Wang | dt-bindings: media: i2c: dongwoon,dw9719: Document DW9714VA | 未匹配；需单独评估 |
| [`aefe15bc73bf`](alternatives/yibo-wang/0027-aefe15bc73bf-media-i2c-dw9719-Add-DW9714VA-support.patch) | Yibo Wang | Yibo Wang | media: i2c: dw9719: Add DW9714VA support | 未匹配；需单独评估 |
| [`f2978d0e6a4a`](alternatives/yibo-wang/0028-f2978d0e6a4a-dt-bindings-input-add-OnePlus-pogo-pin-keyboard.patch) | Yibo Wang | Yibo Wang | dt-bindings: input: add OnePlus pogo-pin keyboard | 未匹配；需单独评估 |
| [`532a6977cce5`](alternatives/yibo-wang/0029-532a6977cce5-Input-add-OnePlus-OPPO-Pad-pogo-pin-keyboard-serdev-driver.patch) | Yibo Wang | Yibo Wang | Input: add OnePlus/OPPO Pad pogo-pin keyboard serdev driver | 1b3df9532919 |
| [`4f402defefe2`](alternatives/yibo-wang/0030-4f402defefe2-dt-bindings-input-add-OnePlus-pogo-pin-keyboard.patch) | Yibo Wang | Yibo Wang | dt-bindings: input: add OnePlus pogo-pin keyboard | 未匹配；需单独评估 |
| [`0a75eb19d7bc`](alternatives/yibo-wang/0031-0a75eb19d7bc-Input-add-OnePlus-OPPO-Pad-pogo-pin-keyboard-serdev-driver.patch) | Yibo Wang | Yibo Wang | Input: add OnePlus/OPPO Pad pogo-pin keyboard serdev driver | 1b3df9532919 |
| [`88a61897359a`](alternatives/yibo-wang/0032-88a61897359a-dt-bindings-media-i2c-dongwoon-dw9719-Document-DW9714VA.patch) | Yibo Wang | Yibo Wang | dt-bindings: media: i2c: dongwoon,dw9719: Document DW9714VA | 未匹配；需单独评估 |
| [`c8ca818ac54f`](alternatives/yibo-wang/0033-c8ca818ac54f-media-i2c-dw9719-Add-DW9714VA-support.patch) | Yibo Wang | Yibo Wang | media: i2c: dw9719: Add DW9714VA support | 未匹配；需单独评估 |
