# out-of-tree build; no kernel tree modifications
#   make KDIR=<kernel src> O=<kernel out> ; defaults below
obj-m := charge_boost_lite.o

KDIR ?= /home/wyb/ML/bootloader/kernel/sm8850-mainline-iceland-7.2
ODIR ?= /home/wyb/ML/bootloader/kernel/out

.PHONY: all clean install

all:
	$(MAKE) -C $(KDIR) O=$(ODIR) ARCH=arm64 LLVM=1 M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) O=$(ODIR) ARCH=arm64 LLVM=1 M=$(CURDIR) clean
