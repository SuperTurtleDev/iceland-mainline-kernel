# map220v iceland-7.3 补丁检查

检查日期：2026-10-27。来源：[map220v/sm8850-mainline](https://github.com/map220v/sm8850-mainline/tree/iceland-7.3)。

分支 HEAD：`8f1ef42eb53ddd65ae909d0de3566186fe5256cf`（提交时间 2026-10-19）。上游基线：`c03c1a14507dfaf8b856c2608f9ac216021fc222`，提交标题 `Linux 7.3`。比较对象为本地 `06416a1eae89a50eaa4fc493ce57639cb65936c8` 及已收集的 7.2.11 平台补丁。

## 结论

共 30 个平台提交：map220v 编写 20 个，第三方编写但由 map220v 提交 10 个（Teguh Sobirin 4、Gianni Spadoni 2，Gaurav Kohli / Akhil P Oommen / Jingyi Wang / Qingqing Zhou 各 1）。没有发现全新独立功能系列，但有需要在 bump 时采用的新版平台适配。

- 21 个与现有归档补丁的 stable patch-id 完全相同。相同 patch-id 表示补丁等价；当前树后续修改仍须保留。
- 5 个包含应纳入迁移评估的更新：WCN7860 硬件描述、板级 DTS、配置片段、面板支持和面板节点。
- 3 个仅补丁上下文改变：QDSS、KTZ8869、cache info。
- 1 个电池补丁改用 devm_work_autocancel，当前树已实现，未发现额外功能改动。

## 新版适配细节

| 提交 | 内容 | 迁移处理 |
|---|---|---|
| `860f49637eb0` | WCN7860 增加两个显式 false 字段 | 随 7.3 硬件表适配；属于零值初始化 |
| `44e759cddb83` | 删除 orientation-gpios；调换 USB DP PHY 的 L4F 0.8V / L1D 1.2V 电源映射 | 对照当前板级 DTS 迁移；usb-role-switch 删除已在当前树实现 |
| `5067c1189527` | 增加 CONFIG_GPIO_SHARED_PROXY=y | 纳入 7.3 配置 |
| `1d43c83a6254` | 在上游 NT36536 驱动增加 CSOT PPD200UB2，替换旧整文件驱动；更新 DSI mode flags / DSC 接口 | 使用新版补丁替换旧驱动补丁 |
| `182c8a042300` | compatible 改为 csot,ppd200ub2；avdd/avee 改为 vsp/vsn | 与新版面板驱动同时迁移 |

## 显示部分必须配套调整

7.3 基线已经包含 NT36536 框架。map220v 的新补丁只添加 PPD200UB2 的初始化序列、显示模式和描述，不再新建整个驱动。新版 mode_flags 加入 NO_EOT_PACKET、VIDEO_BURST、DSC_ALL_SLICES_IN_PKT。

旧 `972c7a104c94` 把双 DSI 触发改为 DSI0；map220v 7.3 树不再携带它。读取 7.3 基线 dsi_manager.c 确认仍从 DSI1 触发，新面板补丁的注释也改为命令从 dsi1 发送。因此不能将这个旧补丁机械叠加到新面板方案。

旧 `e7765030a49d` 使用 dsi->dsc_slice_per_pkt，7.3 已通过 MIPI_DSI_MODE_DSC_ALL_SLICES_IN_PKT 支持多 slice，使用新版接口即可。SoCCP loader / DTS、USB 控制器 role-switch / wakeup 属性也在读取的 7.3 基线中存在；不再出现于远端平台提交列表不等于功能丢失。这里未逐个证明所有消失补丁均与上游等价。

## 后续 bump 的边界

remote.series 是远端 30 个提交的原始顺序索引，用于审查和下一步迁移；本步骤没有验证它可直接应用到当前 7.2.11。没有修改 linux/ 的源码、分支、索引或引用，也未执行 bump、编译或设备测试。

当前树额外的相机、pogo 键盘、Gunyah、SCMI 等 Yibo Wang / 第三方补丁仍须单独迁移，不能用远端 30 个补丁代替本地完整平台集。远端已有的 PCIe iommu-map revert（8f1ef42eb53d）与当前 ce3e266f9e04 patch-id 相同，不需要重复添加。

## 归档和验证

- patches/：全部 30 个原始邮件补丁，按拓扑顺序编号。
- comparison.json：每个提交的 Author / Committer、patch-id、旧补丁映射和分类。
- github-commits.json：30 个平台提交和基线的 API 元数据；已核验每个父提交形成连续的单父链。
- patch-edit-comparisons/：9 个 patch-id 不同补丁的新增/删除行比较；不包含上下文，因此空文件表示新增/删除行一致，不证明完整源码树一致。
- upstream-evidence/：从精确 7.3 基线提交下载的相关源码，用于显示 / SoCCP / USB 对照。
- SHA256SUMS：归档完整性校验。

## 全部提交对照

| 顺序 | 7.3 提交 | 原作者 | 旧提交 | 分类 | 标题 |
|---|---|---|---|---|---|
| 1 | [161adc78cd64](https://github.com/map220v/sm8850-mainline/commit/161adc78cd64ba72f5d44bdd9275583d8e9336c0) | Qingqing Zhou | 84367cda4bc5 | patch-id 相同 | arm64: dts: qcom: kaanapali: add the GPU SMMU node |
| 2 | [ccc1d658585c](https://github.com/map220v/sm8850-mainline/commit/ccc1d658585cd9d439715b593b9d8d75ae721d51) | Jingyi Wang | 5828f9e0a528 | patch-id 相同 | arm64: dts: qcom: kaanapali: Add qfprom node |
| 3 | [d557301dcb35](https://github.com/map220v/sm8850-mainline/commit/d557301dcb354761b04f49d18c6cd6d3d0b2a224) | Akhil P Oommen | 9757148c5bb1 | patch-id 相同 | arm64: dts: qcom: Add GPU support for Kaanapali |
| 4 | [cb02d702abb9](https://github.com/map220v/sm8850-mainline/commit/cb02d702abb97cfc12f73f51e8b8343d233510e8) | Gaurav Kohli | 856c9a5d76e2 | patch-id 相同 | arm64: dts: qcom: kaanapali: Add GPU cooling |
| 5 | [781baaeaf948](https://github.com/map220v/sm8850-mainline/commit/781baaeaf9482231ddc718a499845c73c4ce1b32) | map220v | 8a10b551846e | patch-id 相同 | SM8850: Fix gpuss thermal polling delay |
| 6 | [3eae7909bae3](https://github.com/map220v/sm8850-mainline/commit/3eae7909bae33f4cf707e504b16dcfb1f1a970c2) | map220v | a89e7724daf1 | patch-id 相同 | SM8850: Add DSI1 nodes |
| 7 | [860f49637eb0](https://github.com/map220v/sm8850-mainline/commit/860f49637eb00acc4eda553392fc4208a48befaf) | Teguh Sobirin | bf079c30d01f | 迁移适配更新 | wifi: ath12k: add initial hardware definition for WCN7860 |
| 8 | [bd5ce5933f81](https://github.com/map220v/sm8850-mainline/commit/bd5ce5933f81a4aab38bff56dfd4d857f8c666a3) | Gianni Spadoni | 64258447b10f | 仅上下文 | wifi: ath12k: send QDSS config when CNSS_QDSS_CFG_MISS_V01 is disabled |
| 9 | [58f0f42060f9](https://github.com/map220v/sm8850-mainline/commit/58f0f42060f930dac245cf5a013f5e8fcc6e9917) | Gianni Spadoni | 1b693cd9928c | patch-id 相同 | wifi: ath12k: disable CNSS_QDSS_CFG_MISS_V01 for the WCN7860 |
| 10 | [5f83bf94bffb](https://github.com/map220v/sm8850-mainline/commit/5f83bf94bffb544349800510316eb5fb927aaa35) | Teguh Sobirin | c72982d5ad79 | patch-id 相同 | PCI/pwrctrl: pwrseq: add support for WCN7860 |
| 11 | [14b6772b4df1](https://github.com/map220v/sm8850-mainline/commit/14b6772b4df1346ebd18db06018dd42b267fbd52) | Teguh Sobirin | 719fa465db93 | patch-id 相同 | power: sequencing: qcom-wcn: add support for WCN7860 |
| 12 | [4c731204370f](https://github.com/map220v/sm8850-mainline/commit/4c731204370f4ece35afd8bb58d6c571347fc7fc) | Teguh Sobirin | 1568c3ce3502 | patch-id 相同 | Bluetooth: qca: add WCN7860 support |
| 13 | [44e759cddb83](https://github.com/map220v/sm8850-mainline/commit/44e759cddb837286f77c230c231962577083fe46) | map220v | afe020923fc8 | 迁移适配更新 | SM8850: Add device tree for OnePlus Pad 4 |
| 14 | [5067c1189527](https://github.com/map220v/sm8850-mainline/commit/5067c11895277e9fff97cf135f466b730c607aab) | map220v | e3195e5ffd91 | 迁移适配更新 | SM8850: Add sm8850.config fragment |
| 15 | [b0d3dbbadd97](https://github.com/map220v/sm8850-mainline/commit/b0d3dbbadd979888bc5a4cfe03ca0cba68b8d3a0) | map220v | 38a053d131b4 | 仅上下文 | backlight: Add KTZ8869 driver for iceland |
| 16 | [514fb2b118d3](https://github.com/map220v/sm8850-mainline/commit/514fb2b118d3ebf41c83c8b073d4b6f0e1b9b0ad) | map220v | bad9102cb260 | patch-id 相同 | ICELAND: Add KTZ8869 nodes |
| 17 | [5a30e30610f4](https://github.com/map220v/sm8850-mainline/commit/5a30e30610f4114e284d8e28eda0ae410db516f3) | map220v | 66b96f877451 | patch-id 相同 | drm/msm/dpu: Fix Compressed width calculation |
| 18 | [1d43c83a6254](https://github.com/map220v/sm8850-mainline/commit/1d43c83a6254a9c50b96cccc28f1406e0d36b8ac) | map220v | 6b790f157d18 | 迁移适配更新 | drm/panel: nt36536: Add PPD200UB2 support |
| 19 | [182c8a042300](https://github.com/map220v/sm8850-mainline/commit/182c8a042300286ff3205f6b4730ce1685d2da2a) | map220v | cb5e37b61579 | 迁移适配更新 | ICELAND: Add panel node |
| 20 | [6db2e5ef2dd7](https://github.com/map220v/sm8850-mainline/commit/6db2e5ef2dd78ac40644790405f8b181f1071341) | map220v | d8f0b2f4e40a | patch-id 相同 | Input: Add NT36536 touch driver |
| 21 | [ae49f087a737](https://github.com/map220v/sm8850-mainline/commit/ae49f087a73716be87e7bb56386f141b3b323a3e) | map220v | f43cb00d872e | patch-id 相同 | ICELAND: Add touchscreen node |
| 22 | [003582bc34af](https://github.com/map220v/sm8850-mainline/commit/003582bc34af89c2384e30f33f9313ba916aa57a) | map220v | 65152354d8ae | patch-id 相同 | SM8850: Fix GMU address |
| 23 | [1e4e58d10787](https://github.com/map220v/sm8850-mainline/commit/1e4e58d10787cc9a01f40fa186ef9a8bc580fe95) | map220v | 4fdc45fcc700 | 仅上下文 | SM8850: Add cache info |
| 24 | [7a7b941d12d7](https://github.com/map220v/sm8850-mainline/commit/7a7b941d12d721677b5ffb40552c3962bc28071f) | map220v | 2bc508d899d0 | 当前已包含 | qcom_battmgr: Add basic support for Kaanapali OnePlus SOCCP FW |
| 25 | [3918c1308d42](https://github.com/map220v/sm8850-mainline/commit/3918c1308d4240118ffb4290a08c195b75af2244) | map220v | 5f86156d7b81 | patch-id 相同 | ASoC: Add simple TFA9865 driver |
| 26 | [dff38a509eeb](https://github.com/map220v/sm8850-mainline/commit/dff38a509eeb24660e639bfb519ef101740033b4) | map220v | be941be03817 | patch-id 相同 | ICELAND: Add sound nodes |
| 27 | [25e696226a9d](https://github.com/map220v/sm8850-mainline/commit/25e696226a9dada33cdae494a2983894b07477c2) | map220v | 39708d9ccc23 | patch-id 相同 | SM8850: Update GPU OPP table |
| 28 | [16c9f5076dbd](https://github.com/map220v/sm8850-mainline/commit/16c9f5076dbd593266a8db38031b400028ca51bd) | map220v | ed9d01daed04 | patch-id 相同 | ICELAND: Reserve llcc_lpi_mem to fix Gunyah crash |
| 29 | [521b8c8697c5](https://github.com/map220v/sm8850-mainline/commit/521b8c8697c572ff5e43b37308d22462fecd0065) | map220v | 175302a0a2f9 | patch-id 相同 | ICELAND: Reserve adsp_mhi_mem and global_sync_mem |
| 30 | [8f1ef42eb53d](https://github.com/map220v/sm8850-mainline/commit/8f1ef42eb53ddd65ae909d0de3566186fe5256cf) | map220v | ce3e266f9e04 | patch-id 相同 | Revert "arm64: dts: qcom: kaanapali: Fix the PCIe iommu-map entries" |
