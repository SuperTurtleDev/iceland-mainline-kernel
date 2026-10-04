#!/usr/bin/env python3
"""Topologically sort a depmod modules.dep file into a module load order.

Input (as produced by ``depmod -b <root> <kver>``) has one line per module:

    kernel/drivers/net/usb/cdc_ether.ko: kernel/drivers/net/usb/usbnet.ko

The path before the colon is the module, the space-separated paths after it
are its prerequisites.  Output: one module path per line with every
dependency listed before its dependents (deterministic DFS post-order over
the lexicographically sorted input).  /init loads the modules in this order
with busybox modprobe; modules.dep lets modprobe resolve the dependencies
itself, the order file guarantees an insmod fallback would also work.
"""
import sys

sys.setrecursionlimit(100000)


def main(path):
    deps = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            head, _, tail = line.partition(":")
            mod = head.strip()
            deps[mod] = [d for d in tail.split() if d != mod]

    order = []
    state = {}  # path -> 1 while visiting, 2 when done

    def visit(mod):
        st = state.get(mod)
        if st == 2:
            return
        if st == 1:
            # depmod output should be acyclic; break cycles deterministically
            sys.stderr.write(f"module-order: dependency cycle at {mod}\n")
            return
        state[mod] = 1
        for d in deps[mod]:
            if d in deps:
                visit(d)
        state[mod] = 2
        order.append(mod)

    for mod in sorted(deps):
        visit(mod)

    sys.stdout.write("".join(m + "\n" for m in order))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write(f"usage: {sys.argv[0]} <modules.dep>\n")
        sys.exit(2)
    main(sys.argv[1])
