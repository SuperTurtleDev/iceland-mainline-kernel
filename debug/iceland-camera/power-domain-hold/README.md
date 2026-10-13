# Temporary LCX/LMX genpd hold

This module uses the live `qcom,kaanapali-rpmhpd` provider and standard genpd/runtime
PM APIs. It performs no direct register writes. Each selected domain has its own
temporary consumer device, so existing consumers retain their votes.

`domains=1` selects LCX, `domains=2` selects LMX, and `domains=3` selects both.
`level=256` is the default. The requested level must exactly match a nonzero entry
in each selected resource's CMD-DB table; unsupported values fail before attach.
These are performance levels, not hardware corner indices or microvolts.

Loading attaches suspended consumers without enabling them. The module pins itself
until an explicit successful release, so ordinary `rmmod` cannot lose live handles.
Run one module instance per trial:

```sh
insmod iceland_power_domain_hold.ko domains=1 level=256
cat /sys/module/iceland_power_domain_hold/parameters/setup_status
echo 1 > /sys/module/iceland_power_domain_hold/parameters/hold
cat /sys/module/iceland_power_domain_hold/parameters/held
echo 1 > /sys/module/iceland_power_domain_hold/parameters/release
rmmod iceland_power_domain_hold
```

Require `setup_status=0` and a successful `hold` write before interpreting the
trial. `held=Y` means this module's requests succeeded; it is not a hardware
measurement. A hold failure attempts to drop all votes and keeps the module
available for explicit release. A release failure retains handles and the module
reference: stop the sequence and inspect its error before retrying release.
Do not force module removal. Successful release drops votes, detaches consumers,
and makes the instance unavailable for further holds; reload for the next trial.

Release first removes the performance constraint while the device is active,
then synchronously runtime-suspends it and detaches it. Other consumers can keep
the domain powered. The genpd core does not propagate every provider power-off
failure to runtime PM; check RPMh/dmesg alongside the command result before
assuming physical power changed.
