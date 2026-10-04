# sm8850 debug initrd

Minimal busybox initramfs for OnePlus Pad 4 (SM8850, iceland/kaanapali)
mainline kernel bring-up. It does not touch the onboard storage; it only
provides a USB gadget network with a DHCP server and a password-less
telnet shell, plus interactive shells on the serial and framebuffer
consoles.

## Boot

Flash `initrd_debug.img` into the `initrd` GPT partition and
`bootcfg_debug.img` into `bootcfg`. The debug cmdline is:

```
console=tty0 console=ttyMSM0,115200n8 earlycon ignore_loglevel initcall_debug clk_ignore_unused pd_ignore_unused loglevel=8
```

## USB network from the host

Default gadget function is NCM. Add `usbnet=rndis` (or `usbnet=ecm`) to
the kernel cmdline to switch.

- device (tablet): `192.168.42.42/24` on `usb0`
- host: DHCP from `192.168.42.100` - `192.168.42.200` (gateway and DNS
  `192.168.42.42`)
- debug shell: `telnet 192.168.42.42` (port 23, no authentication)

If the host does not configure automatically, set a fallback address
manually, e.g. `sudo ip addr add 192.168.42.100/24 dev <usb-iface>`.

## Consoles

- serial: `/dev/ttyMSM0` at 115200 8N1 (`earlycon` for the earliest logs)
- framebuffer: `/dev/tty0`
- both get a respawning root shell (`setsid cttyhack /bin/sh`)

Nothing in `/init` panics on failure; every step logs a `[init] ...`
line to the console and the boot continues.

## Modules

The initrd carries its module subset as bare `.ko` files (busybox
insmod/modprobe cannot load compressed modules) with matching
`modules.dep` metadata, plus `/etc/modules.order` generated at packaging
time (`scripts/module-order.py`, a dependency-first topological sort of
`modules.dep`). `/init` walks that file with busybox modprobe (insmod
fallback); modules already built into the kernel simply fail to load and
are not counted.

## Layout in this repository

- `init` - the initramfs `/init`
- `etc/udhcpd.conf` - DHCP pool for the host side of `usb0`

The kernel module subset and firmware files included in the initrd are
listed in `../initrd-modules.txt` (paths as installed on the device).
