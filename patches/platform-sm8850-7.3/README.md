# Iceland Linux 7.3 platform series

## Baseline and replay

- Upstream tag: v7.3, commit c03c1a14507dfaf8b856c2608f9ac216021fc222 (fetched from torvalds/linux).
- map220v iceland-7.3: 8f1ef42eb53ddd65ae909d0de3566186fe5256cf (30 commits).
- Local branch: iceland-7.3, HEAD aa36d0f611d6dca6b89fa839902ef4c6d8b19751.
- Final tree: 5f5c0f659a61795cbd3fa2236aa3de19e244318b.
- series: 79 ordered patches: 30 map220v submissions (including other authors),
  47 carried local submissions, and 2 explicit Linux 7.3 API adaptations.
- Verified using a fresh temporary Git index: git read-tree v7.3, then every
  git apply --cached in series order, without three-way fallback. The resulting
  full tree is exactly the target tree (zero differences). See manifest.json.
- Also verified all 79 patches with git am and am.threeWay=false in a fresh
  temporary shared clone. Result: the same target tree, zero differences.

For a clean checkout of v7.3, apply patches with git am in the order listed in
series. manifest.json records authors, committers, original cherry-pick sources
and checksums; SHA256SUMS validates all patch files. The original iceland-7.2 and
oneplus-cami2c branches remain at 06416a1eae89a50eaa4fc493ce57639cb65936c8.

## Migration decisions

- Start from map220v's 7.3 port rather than reviving obsolete 7.2 display/SoCCP
  implementations. New NT36536 panel framework, DSI1 triggering, supply names,
  WCN7860 defaults and USB PHY supply wiring are preserved.
- Keep local camera/CAMSS/SmartSens/DW9714V, Oplus camres, Iris VPU4, pogo keyboard,
  Gunyah protected sharing, SCMI, RTC and power/modeset fixes.
- The PCI iommu revert ce3e266f9e04 is already in the map220v tree.
- Skip 4f92b7d7d: upstream 7.3 disables the handover IRQ after handling it;
  preserve that lifecycle rather than restoring the old repeated-IRQ branch.
- Port the 48/50 Hz additions from 5f7fdae6d to csot_ppd200ub2_modes;
  retain the existing 144 Hz mode, so c11a4291b becomes redundant.
- Resolve Iris conflicts by retaining upstream force-key-frame/Milos support and
  local display-delay/context-bank support. Keep session capability initialization
  in the 7.3 open path, and avoid a duplicate OPB property entry.
- Resolve the camres Kconfig conflict without resurrecting removed PDR definitions.
- Adapt VPU4 .firmware_desc to .firmware_desc_gen2.
- Adapt Gunyah to mapping_rmap_tree_foreach(vma, mapping, ...).

## Configuration and packaging

config.diff lists semantic changes from the original root config. The final
config is regenerated with the existing amd64 build container's LLVM 21 toolchain:
CONFIG_LOCALVERSION=-iceland, shared GPIO proxy built-in, and renamed
CONFIG_HW_RANDOM_QCOM=m retained. Upstream disables QCE through its BROKEN
dependency; no forced override is added. Kernel olddefconfig drift is zero.

version.env defines kernel release 7.3.0-iceland and Debian version 7.3.0-1.
Package identities are stable linux-{image,modules,headers,tools,firmware}-iceland.
ABI-specific installed paths keep the release. Build verification is recorded
in logs/verify.log and buildinfo.txt under the build/kernel output directory.
Hardware runtime behavior still requires testing on the device.

## Build validation (2026-10-27)

- Image, DTB and 1,389 compressed modules (including charge_boost_lite) built.
- Root config equals kbuild/.config; olddefconfig drift is empty.
- 12 native arm64 header tools and native arm64 perf built.
- charge_boost_lite built in the arm64 container using only the unpacked headers.
- Debug initrd: 319 selected modules and 11 firmware files; none missing.
- Charge initrd: 320 modules and 11 firmware files; none missing.
- Full artifact verifier: 12/12 checks passed.
- Actual five deb payloads passed identity, exact dependency, directory layout,
  config, Image, native ELF, maintainer-script syntax and OOT vermagic checks.
- No installation, device flashing or hardware runtime test was performed.
