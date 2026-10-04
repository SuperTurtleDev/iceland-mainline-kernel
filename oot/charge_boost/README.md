# charge_boost_lite - USB PD fast charge for OnePlus Pad 4 (SM8850, mainline)

Out-of-tree kernel module + userspace service that brings a standard
USB-PD charger from the 5 V baseline contract up to a fixed 9 V (or
12 V) power profile on the Qualcomm SM8850 battery manager
(`qcom-battmgr` over pmic_glink), with a guaranteed return path:

**`rmmod charge_boost_lite` (or service stop) always restores the 5 V
baseline charging.**

PD-only release: standard PD fixed PDOs only. No proprietary charging
curves, current tables or private-protocol data are included.

## How it works

1. The module attaches its own pmic_glink client (auxiliary-bus based,
   exported kernel APIs only - no kernel tree modifications).
2. It checks the adapter detection state (type 6 = PD, 8 = PD_PPS).
3. Boost sequence (matches the reference charging stack):
   input current -> 500 mA, request fixed PDO (`SET_PDO`, mV),
   verify physical vbus >= 7.5 V (up to 3 attempts), then raise the
   input current limit (default 3 A).
4. On unload: PDO -> 5000 mV and input current -> captured baseline.

Measured on hardware (OnePlus Pad 4, standard 5V/3.25A-class PD charger):
5 V @ 2 A (~10 W) -> **8.9 V @ 2.4 A (~21.5 W input)**, stable, battery
temperature unchanged; `rmmod` returns to 4.95 V @ 2 A.

## Build

Requires a prepared kernel tree + output dir (clang/LLVM):

    make KDIR=/path/to/kernel/src O=/path/to/kernel/out

## Install

    sudo ./install.sh

Installs:
- `/usr/lib/modules/$(uname -r)/extra/charge_boost_lite.ko` (+ depmod)
- `/usr/local/sbin/pd-boost.sh` (bring-up + watchdog + fallback)
- `pd-boost.service` (systemd)
- udev rule: starts the service when the charger appears

## Official third-party charger compatibility (OnePlus published)

| protocol | official power |
|---|---|
| PD (fixed PDO) | 13.5 W |
| QC | 13.5 W |
| **PPS (PD 3.0 APDO)** | **55 W** |
| UFCS | 44 W |

The high-power third-party path is PPS; PD fixed PDOs are officially
capped at 13.5 W (~9 V / 1.5 A). Our measured 9 V fixed-PDO session
drew up to ~2.4 A input (~21.5 W) - above the official PD figure,
most likely because this charger is primarily a PPS source - so treat
1.5 A (curr_uv=1500000) as the conservative default for fixed-PDO
use on third-party bricks, or pursue PPS.

## PPS mode (PD 3.0 APDO, experimental)

`PD_MODE=pps` requests a programmable APDO operating point and keeps
it alive from the 5 s poll loop (PD requires a re-Request at least
every 10 s; the reference stack uses 3 s):

    Environment=PD_MODE=pps
    Environment=PD_PPS_MV=5500        # APDO voltage, mV
    Environment=PD_PPS_MA=2000        # APDO current, mA
    Environment=PD_FINAL_ICL_UA=3000000

Fallback ladder on failure: PPS -> fixed PDO (PD_TARGET_MV) -> 5 V
baseline. Termination identical to fixed mode (SOC/temp/status/vbus
gates; vbus sanity window 4.5-12 V). Module params for manual use:
`pps_mv` / `pps_ma` (runtime writable, rewrite = keepalive).

## Roadmap: PPS (next milestone, not in v0.1.0)

The battery-manager PPS primitives (verified present on this
firmware, GET 27 = PPS type reported 1 with a PPS-capable source):

- request APDO operating point: `SET_PPS_VOLT` (mV) + `SET_PPS_CURR` (mA)
- charge-pump MOS control: `PPS_MOS_CTRL`
- adapter authentication: `PPS_GET_AUTHENTICATE`

The reference implementation drives these from a closed-loop
controller (monitor/current/switch work queues on top of the charge
pump); a minimal bring-up (request 9 V / conservative current inside
the APDO window, verify physical vbus) is the planned first step,
gated on a PPS source being attached.

## Profiles (runtime configuration)

The service reads its numbers from the environment; configure a
profile with a systemd drop-in, e.g. the conservative 18 W profile:

    # /etc/systemd/system/pd-boost.service.d/conservative.conf
    [Service]
    Environment=PD_TARGET_MV=9000       # fixed PDO, mV (5/9/12)
    Environment=PD_FINAL_ICL_UA=2000000 # input current cap, uA
    Environment=PD_STOP_SOC=90          # stop PD at/above, %
    Environment=PD_STOP_TEMP=430        # stop PD at/above, 0.1 degC

    systemctl daemon-reload && systemctl restart pd-boost

Verified on hardware: 8.91 V @ 1.99 A = 17.8 W with SOC/temp gates
armed (9 V x 2 A profile, PD source attached).

## Architecture (event-driven state machine)

```
idle --(power_supply uevent: charger add/change)--> wake/query
wake/query: wait for PD contract (type 6 = PD / 8 = PD_PPS via module),
            read adapter capability (current_max)
negotiate : request preferred fixed PDO (default 9 V, PD_TARGET_MV;
            the battery manager accepts fixed 5/9/12 V requests);
            selection = ask for the preferred tier and verify the
            physical vbus moved (>= 7.5 V); if the adapter does not
            offer it, fall back to the 5 V baseline
poll(5 s) : SOC >= 90 % (PD_STOP_SOC)  -> PD off, 5 V baseline, idle
            battery temp >= 43.0 C (PD_STOP_TEMP, generic Li-ion
            safe charging ceiling; NOT copied from any vendor table)
            -> PD off, idle
            status != Charging or charger gone -> idle
idle      : no process running, zero polling; the next charger
            uevent starts the cycle again (unplug also stops the
            service through the udev remove rule)
```

No idle polling: the service exists only while a charger is attached;
wake-up and shutdown are both driven by kernel power_supply uevents
(udev rules), not by timers.

## Use

    systemctl start pd-boost     # or just (re)plug the charger
    systemctl stop pd-boost      # back to 5 V baseline (rmmod)

Manual / no-systemd:

    modprobe charge_boost_lite               # auto sequence (apply=1)
    modprobe charge_boost_lite apply=0       # passive attach
    echo 9000  > /sys/module/charge_boost_lite/parameters/pdo_mv
    echo 3000000 > /sys/module/charge_boost_lite/parameters/curr_uv
    echo 1 > /sys/module/charge_boost_lite/parameters/check   # detection log
    rmmod charge_boost_lite                  # restore 5 V

## Module parameters

| param | default | meaning |
|---|---|---|
| pdo_mv | 9000 | fixed PDO voltage, mV (5000/9000/12000), runtime writable (re-sends) |
| curr_uv | 3000000 | input current limit after boost, uA, runtime writable |
| boost_icl_uv | 500000 | input current during renegotiation |
| retry | 3 | PDO request attempts |
| apply | true | run automatic sequence at load |
| base_icl | 2000000 | fallback restore ICL if capture fails |
| pd_type | ro | last detected type (6=PD, 8=PD_PPS) |

## Safety / fallback

- Watchdog (service): battery temp >= 43.0 C or status != Charging ->
  immediate `rmmod` (5 V baseline).
- Any module write that cannot be executed is simply acked by the
  firmware and physically verified; a failed boost restores the
  baseline automatically.
- The module never writes battery-side limits or charging curves.

## License

MIT, see LICENSE.
