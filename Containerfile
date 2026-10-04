# sm8850 (OnePlus Pad 4, iceland/kaanapali) kernel build container
#
# Base is ubuntu:26.04 whose clang matches the kernel config
# (CONFIG_CC_VERSION_TEXT="Ubuntu clang version 21.1.8 (6ubuntu1)").
# If the -21 versioned packages are not in the archive any more we fall
# back to the default clang/lld/llvm and record the real versions in
# /opt/build-env.txt.
FROM docker.io/library/ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C \
    TZ=UTC

RUN set -eux; \
    apt-get update; \
    #
    # --- toolchain: prefer clang-21 (matches config), fall back to default ---
    if apt-get install -y --no-install-recommends clang-21 lld-21 llvm-21; then \
        echo "toolchain: versioned clang-21/lld-21/llvm-21 installed" > /opt/toolchain-choice.txt; \
        # versioned packages do not provide the unversioned names kbuild
        # expects with LLVM=1, so provide them via /usr/local/bin symlinks
        for t in clang clang++ lld ld.lld \
                 llvm-ar llvm-as llvm-nm llvm-objcopy llvm-objdump \
                 llvm-profdata llvm-ranlib llvm-readelf llvm-strip llvm-config; do \
            if ! command -v "$t" >/dev/null 2>&1; then \
                if [ -x "/usr/bin/$t-21" ]; then \
                    ln -sf "/usr/bin/$t-21" "/usr/local/bin/$t"; \
                fi; \
            fi; \
        done; \
    else \
        echo "toolchain: clang-21 not available, using default clang/lld/llvm" > /opt/toolchain-choice.txt; \
        apt-get install -y --no-install-recommends clang lld llvm; \
    fi; \
    #
    # --- build dependencies ---
    apt-get install -y --no-install-recommends \
        bc bison flex libssl-dev libelf-dev \
        python3 python3-dev cpio zstd xz-utils rsync make gcc git file kmod dwarves; \
    #
    # --- arm64 busybox-static for the debug initrd (extracted, not installed) ---
    dpkg --add-architecture arm64; \
    apt-get update; \
    mkdir -p /opt/busybox-arm64 /tmp/busybox-dl; \
    cd /tmp/busybox-dl; \
    apt-get download busybox-static:arm64; \
    dpkg -x busybox-static_*_arm64.deb /opt/busybox-arm64; \
    file /opt/busybox-arm64/bin/busybox; \
    file /opt/busybox-arm64/bin/busybox | grep -q 'aarch64'; \
    file /opt/busybox-arm64/bin/busybox | grep -q 'statically linked'; \
    #
    # --- record the build environment (key package versions) ---
    : > /opt/build-env.txt; \
    echo "base-image: docker.io/library/ubuntu:26.04" >> /opt/build-env.txt; \
    echo "toolchain-choice: $(cat /opt/toolchain-choice.txt)" >> /opt/build-env.txt; \
    echo "busybox-arm64-deb: $(cd /tmp/busybox-dl && ls busybox-static_*_arm64.deb)" >> /opt/build-env.txt; \
    echo >> /opt/build-env.txt; \
    echo "clang: $(clang --version | head -1)" >> /opt/build-env.txt; \
    echo "ld.lld: $(ld.lld --version | head -1)" >> /opt/build-env.txt; \
    echo >> /opt/build-env.txt; \
    dpkg-query -W -f='${binary:Package}\t${Version}\n' \
        clang clang-21 lld lld-21 llvm llvm-21 \
        bc bison flex libssl-dev libelf-dev python3 python3-dev \
        cpio zstd xz-utils rsync make gcc git file kmod dwarves \
        busybox-static:arm64 >> /opt/build-env.txt 2>/dev/null || true; \
    #
    # --- cleanup ---
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/busybox-dl /var/tmp/*

WORKDIR /work
