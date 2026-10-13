# Iceland stock CamX / SEE path audit

2026-10-12. Offline inspection only; no kernel or target firmware replacement.

## Result and limits

The supplied stock Iceland front module has three resolution modes, and the
main module has four. Every mode's capability array contains only enum 0. None
contains AON enum 2. The inspected CamX path derives isAONCamera from capability
2; the QSEE AON library creates objects only for isAONCamera == 1.

This is evidence that these module configurations do not enable this particular
CamX physical AON sensor-object construction path. Subsequent inspection found
an independent OEM camera open path calling AcquireApCamera, gated by
isSupportSensorhub; isUpdateAFPositionToSensorHub is also configured. Therefore
the missing physical AON capability is not evidence against OEM SEE arbitration.
The user confirms this stock vendor can open the camera. Successful runtime
initialization/acquisition for these actual modules remains to be traced.

## Reproduction and binary identity

`../iceland-module-capabilities.py` accepts only the two audited module hashes.
Run it on the stock ODM `com.qti.sensormodule.icelandfront.bin` and
`com.qti.sensormodule.icelandmain.bin` files. Results are saved in
`stock-camera-capabilities.json`.

| Binary | SHA256 |
| --- | --- |
| Iceland front module | 7d081442cc73d13c099522d94322e21792e5d0b94143386cb2ecfaa0a93e78a2 |
| Iceland main module | a94533c4ebf7cf213c432520719e0437d1a93b65ff4e102aad63c3118cd077fc |
| /vendor/lib64/hw/camera.qcom.core.so | 0f68bc4649525dce821c6b33010b3cd79fba5faca01c538d9cdb9bb8b39940c0 |

## Serialized field derivation

The section count is at 0xa4, followed at 0xa8 by (type, offset, size) triplets.
Type 3 holds 12-byte (data offset, length, duplicate ID) symbol records; type 1
holds the referenced bytes. Symbol indices are zero-based, including dummy 0.

Symbol 31 is a 20-byte ResolutionInformation record: length 16, optional selector
count 1 / symbol 32, mode count 3 or 4 / symbol 33. Its layout matches
SensorDriverData::Load at 0x5a1f48 through 0x5a2048; that loader calls
ResolutionData::Load at 0x5a215c. Symbol 33 contains 460-byte records, each
starting with length 456.

ResolutionData::Load (0x59c08c) directly reads 440 bytes from its parent entry.
There are two additional four-byte load-limit prefixes: its own at 0x59c0ec
and an inline nested structure at 0x59ca04. SettingsInfo::Load at 0x59d750
consumes another 12 bytes (four-byte limit, count, pointer). Hence 460 total.
SettingsInfo does NOT itself consume 20 bytes.

ReadLoadDataLimit at 0x581d5c conditionally reads a u32 for this format version
and computes an end position; UpdatePosition at 0x581ed4 advances to that end.
The actual record prefixes and total lengths agree with this layout.

The capability count read at 0x59e820 has direct-read offset 248, plus the
preceding 4 + 4 + 12 bytes, giving serialized offset 268. The pointer follows
at 272 (read at 0x59e848). Its elements are decoded by
ReadEnum_SensorCapability at 0x59e95c. The runtime fields are count +756 and
array +768, also consumed by CheckResolutionCapability at 0xa5cfa4.

Front mode capability symbols: 177, 344, 511. Main: 177, 344, 511, 698.
All contain one u32 equal to zero.

ReadEnum_SensorCapability (0x599e5c) uses a byte jump table at 0x22f7ba.
Entry 0 branches to 0x599ecc and writes runtime value 0. Entry 2 branches to
0x599f20 and writes runtime value 2. Thus neither a guessed enum mapping nor
a raw whole-file search was used to identify the capability.

## From capability to AON construction

- PopulateSensorStaticCapability at 0xa65928 calls CheckResolutionCapability
  with mode index and value 2; on a match it writes 1 to static caps +372 at
  0xa65950.
- ChiContext::GetCameraInfo copies static caps +372 to ChiCameraInfo +72 at
  0x374ecc / 0x374ed0.
- com.qti.qseeaon.so BuildAONSensorObjArray (0x3da54) checks that field for 1
  before building an AON sensor object. See `iceland-aon-constructor.dis`.

## Expanded backup coverage

`stock-protobuf-inventory.json` now covers 14 EROFS partition inventories:
vendor, odm, my_product, my_stock, system_ext, product, system, my_bigball,
my_carrier, my_engineering, my_heytap, my_manifest, my_region, system_dlkm.
No Iceland camera PB was found.

`stock-archive-audit/` records ZIP/APK/JAR/APEX container scans (including nested
ZIP archives): vendor 19, odm 4, my_product 159, my_stock 79, system_ext 304,
product 40, system 158, my_region 2. Searched names and selected content types
for Iceland sensor names, camera PB directory and handshake identifiers.
Four selected APEX ext4 payloads were also inventoried; this is NOT a claim
that all Android APEX payload images were inspected. A separate scan covered
3058 configuration files. Generic AON feature switches were found, but no
Iceland PB producer/configuration.

Ext4 persist (557 entries) and dsp (124 entries) were inventoried. Persist's
`/hlos_rfs/shared/imx766_ois_pb.pb` identifies an unrelated actuator/module;
it is not an Iceland camera configuration. DSP has camera model libraries,
but no corresponding camera configuration PB.

`stock-ramdisk-audit/` records init_boot (28 entries), vendor_boot (509),
and recovery (824). Boot has no ramdisk. No matching PB or PB-generation
command was found there. Userdata was not provided and was not inspected.

## Stock versus installed ADSP

The backup modem FAT partition's adsp.mdt/adsp.bNN files were reconstructed
using the STOCK MDT program headers (segment positions differ between builds).

| | Backup ADSP | Current mainline firmware |
| --- | --- | --- |
| Bytes | 40814792 | 40835272 |
| SHA256 | eb56ce0322e1616d6eec0d482e0d63bd523066fdc0a29027bdf56be07902eeca | 75c4de7550088bf3cff68e87448fb16e95f3a48121be2acb526b2cd99b8fcfa6 |
| OEM build | kvm-slave-build-s-bp-12681041 | kvm-slave-build-s-bp-09944077 |

Both report QC LPAIDSP.HT.1.2-00854-KAANAPALI-1 / kaanapali.adsp.prodQ.
Stock handle_handshake_cmd_init is at 0xb21213e8, file offset 0x13533e8.
It uses the same `/vendor/lib64/camera/%s_%lu.pb` mechanism: format load
0xb212146c, reader call 0xb2121484 -> 0xb254cc64, failure branch 0xb212149c.
See `iceland-stock-see-framework.dis`. Changing firmware alone has no evidence
of solving the missing configuration; no replacement was attempted.

## Implementation status

`oplus_camres`, shared CAM/VCM votes, SEE symbol dependencies and probe retries
remain unimplemented. The runtime INIT failure is a failed protocol ACK, not
an absent supplier; returning EPROBE_DEFER forever would hide that distinction.
No failed INIT was followed by AP takeover or camera I2C. No donor module PB
was renamed/deployed. GDM and the user WirePlumber remain stopped after the
earlier authorized experiment.
