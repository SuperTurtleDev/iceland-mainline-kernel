# Build against the headers installed for the running kernel by default.
# Override KDIR for another prepared kernel tree and ODIR for a separate O= tree.
obj-m := charge_boost_lite.o

KDIR ?= /lib/modules/$(shell uname -r)/build

.PHONY: all clean
all:
	$(MAKE) -C $(KDIR) $(if $(ODIR),O=$(ODIR)) ARCH=arm64 LLVM=1 M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) $(if $(ODIR),O=$(ODIR)) ARCH=arm64 LLVM=1 M=$(CURDIR) clean
