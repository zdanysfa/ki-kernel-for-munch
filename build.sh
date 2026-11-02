#!/bin/bash
# Universal Ki-Kernel Build Script for SM8250 (munch / alioth / etc.)
# Supports: AOSP / Custom ROM, MIUI / HyperOS, & ColorOS / OxygenOS
# Usage: bash build.sh <target_device> [variant] [target_os] [profile]
#   variant   : ksu (default) | nosusfs | noksu
#   target_os : aosp (default) | miui | coloros | both
#   profile   : release (default) | debug | debug-kasan

set -e

TARGET_DEVICE=$1
KERNEL_NAME="Ki-kernel"
KERNEL_VERSION="v1.6.1"
BUILD_DATETIME=$(date +'%Y%m%d_%H%M')
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")

if [ -z "$1" ]; then
    echo "=========================================================="
    echo "  Ki-Kernel Build Script ($KERNEL_VERSION)"
    echo "=========================================================="
    echo "Usage: bash build.sh <target_device> [variant] [target_os] [profile]"
    echo ""
    echo "Arguments:"
    echo "  target_device : munch, alioth, apollo, lmi, umi, etc."
    echo "  variant       : ksu (default) | nosusfs | noksu"
    echo "  target_os     : aosp (default) | miui | coloros (or oplus/oos) | both"
    echo "  profile       : release (default) | debug | debug-kasan"
    echo ""
    echo "Examples:"
    echo "  bash build.sh munch ksu aosp     # Build AOSP with ReSukiSU + SuSFS"
    echo "  bash build.sh munch ksu miui     # Build MIUI/HyperOS with ReSukiSU + SuSFS"
    echo "  bash build.sh munch ksu coloros  # Build ColorOS/OxygenOS/RealmeUI with ReSukiSU + SuSFS"
    echo "  bash build.sh munch ksu both     # Build Universal Dual-OS zip"
    echo "=========================================================="
    exit 1
fi

# Detect Toolchain (ZyCromerZ Clang 16 > Neutron > Proton)
ZYC_PATH=$HOME/zyc-clang/bin
NEUTRON_PATH=$HOME/neutron-clang/bin
PROTON_PATH=$HOME/proton-clang/proton-clang-20210522/bin

if [ -d "$ZYC_PATH" ]; then
    export PATH="$ZYC_PATH:$PATH"
    echo "Using Toolchain: ZyCromerZ Clang 16 ($ZYC_PATH)"
elif [ -d "$NEUTRON_PATH" ]; then
    export PATH="$NEUTRON_PATH:$PATH"
    echo "Using Toolchain: Neutron Clang ($NEUTRON_PATH)"
elif [ -d "$PROTON_PATH" ]; then
    export PATH="$PROTON_PATH:$PATH"
    echo "Using Toolchain: Proton Clang ($PROTON_PATH)"
else
    echo "Error: No suitable Clang toolchain found."
    exit 1
fi

if ! command -v aarch64-linux-gnu-ld >/dev/null 2>&1; then
    echo "[aarch64-linux-gnu-ld] not found in environment."
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "[clang] not found in environment."
    exit 1
fi

# Prioritize ZyC Clang 16 if available
if [ -d "$HOME/zyc-clang/bin" ]; then
    export PATH="$HOME/zyc-clang/bin:$PATH"
    echo "Using ZyC Clang: [$HOME/zyc-clang/bin]"
fi

# Enable ccache for fast compiling
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache/bin:/usr/lib/ccache:$PATH"
echo "CCACHE_DIR: [$CCACHE_DIR]"

export KBUILD_BUILD_USER="build-user"
export KBUILD_BUILD_HOST="build-host 4.19.404R"

MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip HOSTCC=$PWD/tools/hostcc HOSTLD=/usr/bin/ld.bfd CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "Error: arch/arm64/configs/${TARGET_DEVICE}_defconfig not found."
    exit 1
fi

echo "[clang --version]:"
clang --version

# Parse Variant (Root / SuSFS)
KSU_ENABLE=1
SUSFS_ENABLE=1
VARIANT_TAG="KSU+SUSFS"

case "$2" in
    ksu|ksu-susfs|susfs|"")
        KSU_ENABLE=1
        SUSFS_ENABLE=1
        VARIANT_TAG="KSU+SUSFS"
        ;;
    ksu-nosusfs|nosusfs|plain|onlyksu|ksu-only|only-ksu)
        KSU_ENABLE=1
        SUSFS_ENABLE=0
        VARIANT_TAG="KSU"
        ;;
    noksu|vanilla|none|no-ksu)
        KSU_ENABLE=0
        SUSFS_ENABLE=0
        VARIANT_TAG="NOKSU"
        ;;
    *)
        echo "Unknown variant: $2. Defaulting to KSU+SUSFS."
        KSU_ENABLE=1
        SUSFS_ENABLE=1
        VARIANT_TAG="KSU+SUSFS"
        ;;
esac

# Parse Target OS (aosp, miui, coloros, both)
TARGET_OS="${3:-aosp}"
case "$TARGET_OS" in
    aosp|miui|both|all) ;;
    coloros|oplus|oos|realme) TARGET_OS="coloros" ;;
    *) TARGET_OS="aosp" ;;
esac

# Parse Build Profile (release, debug)
BUILD_PROFILE="${4:-release}"
case "$BUILD_PROFILE" in
    release) ;;
    debug) VARIANT_TAG="${VARIANT_TAG}-DEBUG" ;;
    debug-kasan) VARIANT_TAG="${VARIANT_TAG}-DEBUG-KASAN" ;;
    *)
        echo "Error: unknown profile: $BUILD_PROFILE (use release, debug or debug-kasan)"
        exit 1
        ;;
esac

echo "=========================================================="
echo "Target Device : $TARGET_DEVICE"
echo "Kernel        : $KERNEL_NAME $KERNEL_VERSION"
echo "Variant       : $VARIANT_TAG"
echo "Target OS     : $TARGET_OS"
echo "Profile       : $BUILD_PROFILE"
echo "=========================================================="

apply_ksu_config() {
    if [ $KSU_ENABLE -eq 1 ]; then
        scripts/config --file out/.config \
            -e KSU \
            -e THREAD_INFO_IN_TASK \
            -d KSU_KPROBES_HOOK \
            -d KSU_DEBUG \
            -d KSU_TRACEPOINT_HOOK \
            -e KSU_THRONE_TRACKER_ALWAYS_THREADED \
            -d KSU_ALLOWLIST_WORKAROUND \
            -e KSU_LSM_SECURITY_HOOKS \
            -d KSU_MANUAL_HOOK \
            -e KSU_MULTI_MANAGER_SUPPORT

        if [ $SUSFS_ENABLE -eq 1 ]; then
            scripts/config --file out/.config \
                -e KSU_SUSFS \
                -d KSU_MANUAL_HOOK \
                -d KSU_TRACEPOINT_HOOK \
                -e KSU_SUSFS_SUS_PATH \
                -e KSU_SUSFS_SUS_MAP \
                -e KSU_SUSFS_SUS_NETLINK \
                -e KSU_SUSFS_AUTO_ADD_SUS_KSURULES \
                -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
                -e KSU_SUSFS_SUS_SU \
                -e KSU_SUSFS_SUS_MOUNT \
                -e KSU_SUSFS_SUS_KSTAT \
                -e KSU_SUSFS_SPOOF_UNAME \
                -e KSU_SUSFS_ENABLE_LOG \
                -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
                -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
                -e KSU_SUSFS_OPEN_REDIRECT \
                -e KSU_SUSFS_SUS_OVERLAYFS \
                -e KSU_SUSFS_ENABLE_AVC_LOG_SPOOFING
        else
            scripts/config --file out/.config \
                -e KSU_MANUAL_HOOK \
                -d KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
                -d KSU_TRACEPOINT_HOOK \
                -d KSU_SUSFS \
                -d KSU_SUSFS_SUS_PATH \
                -d KSU_SUSFS_SUS_MAP \
                -d KSU_SUSFS_SUS_NETLINK \
                -d KSU_SUSFS_AUTO_ADD_SUS_KSURULES \
                -d KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
                -d KSU_SUSFS_SUS_SU \
                -d KSU_SUSFS_SUS_MOUNT \
                -d KSU_SUSFS_SUS_KSTAT \
                -d KSU_SUSFS_SPOOF_UNAME \
                -d KSU_SUSFS_ENABLE_LOG \
                -d KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
                -d KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
                -d KSU_SUSFS_OPEN_REDIRECT \
                -d KSU_SUSFS_SUS_OVERLAYFS \
                -d KSU_SUSFS_ENABLE_AVC_LOG_SPOOFING
        fi
    else
        scripts/config --file out/.config \
            -d KSU \
            -d KSU_MANUAL_HOOK \
            -d KSU_TRACEPOINT_HOOK \
            -d KSU_SUSFS \
            -d KSU_SUSFS_SUS_PATH \
            -d KSU_SUSFS_SUS_MAP \
            -d KSU_SUSFS_SUS_NETLINK \
            -d KSU_SUSFS_AUTO_ADD_SUS_KSURULES \
            -d KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
            -d KSU_SUSFS_SUS_SU \
            -d KSU_SUSFS_SUS_MOUNT \
            -d KSU_SUSFS_SUS_KSTAT \
            -d KSU_SUSFS_SPOOF_UNAME \
            -d KSU_SUSFS_ENABLE_LOG \
            -d KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
            -d KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
            -d KSU_SUSFS_OPEN_REDIRECT \
            -d KSU_SUSFS_SUS_OVERLAYFS \
            -d KSU_SUSFS_ENABLE_AVC_LOG_SPOOFING
    fi
}

apply_droidspaces_config() {
    echo "Enforcing Droidspaces & Containerization configs..."
    scripts/config --file out/.config \
        -e SYSVIPC \
        -e POSIX_MQUEUE \
        -e NAMESPACES \
        -e PID_NS \
        -e UTS_NS \
        -e IPC_NS \
        -e USER_NS \
        -e SECCOMP \
        -e SECCOMP_FILTER \
        -e CGROUPS \
        -e CGROUP_DEVICE \
        -e CGROUP_SCHED \
        -e FAIR_GROUP_SCHED \
        -e CGROUP_FREEZER \
        -e CGROUP_NET_PRIO \
        -e MEMCG \
        -e MEMCG_SWAP \
        -e MEMCG_SWAP_ENABLED \
        -e CFS_BANDWIDTH \
        -e CGROUP_PIDS \
        -e CGROUP_CPUACCT \
        -e DEVTMPFS \
        -e OVERLAY_FS \
        -e TMPFS_POSIX_ACL \
        -e TMPFS_XATTR \
        -e FW_LOADER \
        -e FW_LOADER_USER_HELPER \
        -e NET_NS \
        -e VETH \
        -e MACVLAN \
        -e MACVTAP \
        -e IPVLAN \
        -e IPVTAP \
        -e BRIDGE \
        -e NETFILTER \
        -e BRIDGE_NETFILTER \
        -e NETFILTER_ADVANCED \
        -e NF_CONNTRACK \
        -e IP_NF_IPTABLES \
        -e IP_NF_FILTER \
        -e NF_NAT \
        -e NF_TABLES \
        -e IP_NF_TARGET_MASQUERADE \
        -e NETFILTER_XT_TARGET_MASQUERADE \
        -e NETFILTER_XT_TARGET_TCPMSS \
        -e NETFILTER_XT_MATCH_ADDRTYPE \
        -e NF_CONNTRACK_NETLINK \
        -e NF_NAT_REDIRECT \
        -e IP_ADVANCED_ROUTER \
        -e IP_MULTIPLE_TABLES \
        -e NF_CONNTRACK_IPV4 \
        -e NF_NAT_IPV4 \
        -e IP_NF_NAT \
        -e IPV6 \
        -e IPV6_MULTIPLE_TABLES \
        -e IP6_NF_IPTABLES \
        -e IP6_NF_FILTER \
        -e IP6_NF_MANGLE \
        -e IP6_NF_NAT \
        -e IP6_NF_TARGET_MASQUERADE \
        -e NF_CONNTRACK_IPV6 \
        -e NF_NAT_IPV6 \
        -e NETFILTER_XT_MATCH_COMMENT \
        -e NETFILTER_XT_MATCH_STATE \
        -e NETFILTER_XT_MATCH_CONNTRACK \
        -e NETFILTER_XT_MATCH_MULTIPORT \
        -e NETFILTER_XT_MATCH_HL \
        -e NETFILTER_XT_TARGET_REJECT \
        -e IP_NF_TARGET_REJECT \
        -e NETFILTER_XT_TARGET_LOG \
        -e IP_NF_TARGET_ULOG \
        -e NETFILTER_XT_MATCH_RECENT \
        -e NETFILTER_XT_MATCH_LIMIT \
        -e NETFILTER_XT_MATCH_HASHLIMIT \
        -e NETFILTER_XT_MATCH_OWNER \
        -e NETFILTER_XT_MATCH_PKTTYPE \
        -e NETFILTER_XT_MATCH_MARK \
        -e NETFILTER_XT_TARGET_MARK \
        -e IP_SET \
        -e IP_SET_HASH_IP \
        -e IP_SET_HASH_NET \
        -e NETFILTER_XT_SET \
        -e NETFILTER_NETLINK_QUEUE \
        -e NETFILTER_NETLINK_LOG \
        -e NETFILTER_XT_TARGET_NFLOG \
        -e NETFILTER_XT_TARGET_CHECKSUM \
        -e USB_CONFIGFS_RNDIS \
        -e USB_CONFIGFS_ECM \
        --set-val BLK_DEV_LOOP_MIN_COUNT 32 \
        -d ANDROID_PARANOID_NETWORK
}

# Full-debug kernel for hunting bugs: slow and heavy on purpose, never for daily use.
DEBUG_CONFIG_ON=(
    # Readable backtraces, and vmlinux to decode them
    LTO_NONE DEBUG_KERNEL DEBUG_INFO DEBUG_FS
    # Every log level in dmesg, pr_debug included
    DYNAMIC_DEBUG
    # Logs that survive a crash or a forced reboot
    PSTORE_CONSOLE PSTORE_PMSG PSTORE_RAM
    # Hangs and deadlocks
    DETECT_HUNG_TASK BOOTPARAM_HUNG_TASK_PANIC LOCKUP_DETECTOR SOFTLOCKUP_DETECTOR
    PROVE_LOCKING DEBUG_ATOMIC_SLEEP PANIC_ON_OOPS
    # Memory leaks and corruption
    DEBUG_KMEMLEAK SLUB_DEBUG SLUB_DEBUG_ON PAGE_OWNER DEBUG_VM DEBUG_LIST
    DEBUG_STACK_USAGE SCHED_STACK_END_CHECK
)
# Separate profile: KASAN is the likeliest option to stop vendor drivers from booting.
KASAN_CONFIG_ON=(KASAN KASAN_GENERIC KASAN_OUTLINE)

# ignore_loglevel and dyndbg=+p: all levels. no_console_suspend: logs up to the moment of an idle death.
DEBUG_CMDLINE="ramoops_memreserve=4M ignore_loglevel printk.devkmsg=on dyndbg=+p no_console_suspend page_owner=on"

debug_symbols() {
    echo "${DEBUG_CONFIG_ON[@]}"
    [ "$BUILD_PROFILE" = "debug-kasan" ] && echo "${KASAN_CONFIG_ON[@]}"
    return 0
}

apply_debug_config() {
    [ "$BUILD_PROFILE" != "release" ] || return 0
    echo "Enabling $BUILD_PROFILE profile..."
    for symbol in $(debug_symbols); do
        scripts/config --file out/.config -e "$symbol"
    done
    # A debug kernel is slow enough to trip the default 120s limit on healthy tasks.
    # No panic on soft lockup: the pr_debug flood alone could cause one and bootloop the phone.
    scripts/config --file out/.config \
        -d LTO_CLANG \
        -d THINLTO \
        -d BOOTPARAM_SOFTLOCKUP_PANIC \
        --set-val DEFAULT_HUNG_TASK_TIMEOUT 240 \
        --set-val LOG_BUF_SHIFT 25 \
        --set-val CONSOLE_LOGLEVEL_DEFAULT 8 \
        --set-val DEBUG_KMEMLEAK_EARLY_LOG_SIZE 40000 \
        --set-str CMDLINE "$DEBUG_CMDLINE"
}

# scripts/config sets symbols blindly and olddefconfig drops any with unmet
# dependencies, so check here rather than ship a debug kernel missing a detector.
check_debug_config() {
    [ "$BUILD_PROFILE" != "release" ] || return 0
    for symbol in $(debug_symbols); do
        if ! grep -q "^CONFIG_$symbol=y" out/.config; then
            echo "Error: CONFIG_$symbol did not survive olddefconfig"
            exit 1
        fi
    done
}

echo "Cleaning build directories..."
rm -rf out/ anykernel/
rm -rf include/config include/generated arch/*/include/generated .config 2>/dev/null || true
rm -rf build_artifacts 2>/dev/null || true
mkdir -p build_artifacts/aosp build_artifacts/miui

echo "Cloning AnyKernel3..."
git clone https://github.com/AstideLabs/AnyKernel3 -b kona --single-branch --depth=1 anykernel

local_version_date_str="-${KERNEL_NAME}-${KERNEL_VERSION}"
sed -i "s/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"${local_version_date_str}\"/" arch/arm64/configs/${TARGET_DEVICE}_defconfig

# Pre-generate SELinux headers so KernelSU never races with parallel make
if [ ! -f "security/selinux/flask.h" ]; then
    echo "Pre-generating SELinux flask.h..."
    gcc -Iinclude/uapi -Iinclude -Isecurity/selinux/include scripts/selinux/genheaders/genheaders.c -o /tmp/genheaders
    /tmp/genheaders security/selinux/flask.h security/selinux/av_permissions.h
fi

# ------------------------------------------------------------
# BUILD AOSP
# ------------------------------------------------------------
if [ "$TARGET_OS" == "aosp" ] || [ "$TARGET_OS" == "both" ] || [ "$TARGET_OS" == "all" ]; then
    echo ""
    echo ">>> Compiling Kernel for AOSP / Custom ROM <<<"
    rm -rf out/
    make $MAKE_ARGS ${TARGET_DEVICE}_defconfig
    apply_ksu_config
    apply_droidspaces_config
    apply_debug_config
    make $MAKE_ARGS olddefconfig
    check_debug_config
    make $MAKE_ARGS KCFLAGS="-O2" -j$(nproc)

    if [ ! -f "out/arch/arm64/boot/Image" ]; then
        echo "Error: AOSP Image compilation failed."
        exit 1
    fi

    echo "Compiling DTBs (Extreme UV + OC 683 MHz)..."
    cp -f arch/arm64/boot/dts/gpu_profiles/kona-v2-gpu-extreme.dtsi arch/arm64/boot/dts/vendor/qcom/kona-v2-gpu.dtsi
    rm -rf out/arch/arm64/boot/dts
    make $MAKE_ARGS dtbs -j$(nproc)
    if [ -f "out/arch/arm64/boot/dts/vendor/qcom/kona-v2.1.dtb" ]; then
        cp out/arch/arm64/boot/dts/vendor/qcom/kona-v2.1.dtb build_artifacts/aosp/dtb_oc
    else
        find out/arch/arm64/boot/dts -name '*.dtb' | sort | head -n 1 | xargs cat > build_artifacts/aosp/dtb_oc
    fi

    echo "Compiling DTBs (Stock 670 MHz + Safe Voltage)..."
    cp -f arch/arm64/boot/dts/gpu_profiles/kona-v2-gpu-stock.dtsi arch/arm64/boot/dts/vendor/qcom/kona-v2-gpu.dtsi
    rm -rf out/arch/arm64/boot/dts
    make $MAKE_ARGS dtbs -j$(nproc)
    if [ -f "out/arch/arm64/boot/dts/vendor/qcom/kona-v2.1.dtb" ]; then
        cp out/arch/arm64/boot/dts/vendor/qcom/kona-v2.1.dtb build_artifacts/aosp/dtb_stock
    else
        find out/arch/arm64/boot/dts -name '*.dtb' | sort | head -n 1 | xargs cat > build_artifacts/aosp/dtb_stock
    fi
    cp build_artifacts/aosp/dtb_oc build_artifacts/aosp/dtb
    cp -f arch/arm64/boot/dts/gpu_profiles/kona-v2-gpu-extreme.dtsi arch/arm64/boot/dts/vendor/qcom/kona-v2-gpu.dtsi

    cp out/arch/arm64/boot/Image build_artifacts/aosp/Image
    echo ">>> AOSP Build Done! <<<"
fi

# ------------------------------------------------------------
# BUILD MIUI / HyperOS
# ------------------------------------------------------------
if [ "$TARGET_OS" == "miui" ] || [ "$TARGET_OS" == "coloros" ] || [ "$TARGET_OS" == "both" ] || [ "$TARGET_OS" == "all" ]; then
    echo ""
    if [ "$TARGET_OS" == "coloros" ]; then
        echo ">>> Compiling Kernel for ColorOS / OxygenOS / RealmeUI <<<"
    else
        echo ">>> Compiling Kernel for MIUI / HyperOS <<<"
    fi
    rm -rf out/
    rm -rf include/config include/generated arch/*/include/generated .config 2>/dev/null || true
    make $MAKE_ARGS ${TARGET_DEVICE}_defconfig
    apply_ksu_config
    apply_droidspaces_config

    # Enable MIUI hardware drivers, disable obsolete/hanging daemons
    scripts/config --file out/.config \
        -e EROFS_FS \
        -e EROFS_FS_XATTR \
        -e EROFS_FS_POSIX_ACL \
        -e EROFS_FS_SECURITY \
        -e EROFS_FS_ZIP \
        -e EROFS_FS_PCPU_KTHREAD \
        -e EROFS_FS_PCPU_KTHREAD_HIPRI \
        -d PSTORE_COMPRESS \
        --set-str STATIC_USERMODEHELPER_PATH "" \
        -d SF_BINDER \
        -d MILLET \
        -d MIGT \
        -d MIGT_ENERGY_MODEL \
        -d BOOTUP_RECLAIM \
        -d MI_RECLAIM \
        -d RTMM \
        -e XIAOMI_MIUI \
        -e TECHPACK_CAMERA_XIAOMI \
        -e OVERLAY_FS \
        -d DEBUG_FS \
        -e LTO_NONE \
        -d LTO_CLANG \
        -d LOCALVERSION_AUTO \
        -d MODULE_SIG_SHA512 \
        -d MODULE_SIG_HASH \
        -d CORESIGHT \
        -d IPC_LOGGING \
        -d SCHEDSTATS \
        -d DEBUG_INFO

    apply_debug_config
    make $MAKE_ARGS olddefconfig
    check_debug_config
    make $MAKE_ARGS KCFLAGS="-O2" -j$(nproc)

    if [ ! -f "out/arch/arm64/boot/Image" ]; then
        echo "Error: Image compilation failed."
        exit 1
    fi

    echo "Compiling DTBs (Extreme UV + OC 683 MHz)..."
    cp -f arch/arm64/boot/dts/gpu_profiles/kona-v2-gpu-extreme.dtsi arch/arm64/boot/dts/vendor/qcom/kona-v2-gpu.dtsi
    rm -rf out/arch/arm64/boot/dts
    make $MAKE_ARGS dtbs -j$(nproc)
    if [ -f "out/arch/arm64/boot/dts/vendor/qcom/kona-v2.1.dtb" ]; then
        cp out/arch/arm64/boot/dts/vendor/qcom/kona-v2.1.dtb build_artifacts/miui/dtb_oc
    else
        find out/arch/arm64/boot/dts -name '*.dtb' | sort | head -n 1 | xargs cat > build_artifacts/miui/dtb_oc
    fi

    echo "Compiling DTBs (Stock 670 MHz + Safe Voltage)..."
    cp -f arch/arm64/boot/dts/gpu_profiles/kona-v2-gpu-stock.dtsi arch/arm64/boot/dts/vendor/qcom/kona-v2-gpu.dtsi
    rm -rf out/arch/arm64/boot/dts
    make $MAKE_ARGS dtbs -j$(nproc)
    if [ -f "out/arch/arm64/boot/dts/vendor/qcom/kona-v2.1.dtb" ]; then
        cp out/arch/arm64/boot/dts/vendor/qcom/kona-v2.1.dtb build_artifacts/miui/dtb_stock
    else
        find out/arch/arm64/boot/dts -name '*.dtb' | sort | head -n 1 | xargs cat > build_artifacts/miui/dtb_stock
    fi
    cp build_artifacts/miui/dtb_oc build_artifacts/miui/dtb
    cp -f arch/arm64/boot/dts/gpu_profiles/kona-v2-gpu-extreme.dtsi arch/arm64/boot/dts/vendor/qcom/kona-v2-gpu.dtsi

    cp out/arch/arm64/boot/Image build_artifacts/miui/Image
    if [ "$TARGET_OS" == "coloros" ]; then
        echo ">>> ColorOS / OxygenOS Build Done! <<<"
    else
        echo ">>> MIUI / HyperOS Build Done! <<<"
    fi
fi

# ------------------------------------------------------------
# PACKAGING ANYKERNEL3
# ------------------------------------------------------------
echo ""
echo ">>> Packaging AnyKernel3 Flashable Zip <<<"
rm -rf anykernel/kernels/ anykernel/dtbs/ anykernel/Image anykernel/dtb anykernel/dtb_oc anykernel/dtb_stock anykernel/dtbo.img 2>/dev/null

if [ "$TARGET_OS" == "aosp" ]; then
    mkdir -p anykernel/kernels/aosp/
    cp build_artifacts/aosp/Image anykernel/kernels/aosp/Image
    cp build_artifacts/aosp/dtb anykernel/kernels/aosp/dtb
    cp build_artifacts/aosp/dtb_oc anykernel/dtb_oc
    cp build_artifacts/aosp/dtb_stock anykernel/dtb_stock
    cp build_artifacts/aosp/dtb anykernel/dtb
elif [ "$TARGET_OS" == "miui" ]; then
    mkdir -p anykernel/kernels/miui/
    cp build_artifacts/miui/Image anykernel/kernels/miui/Image
    cp build_artifacts/miui/dtb anykernel/kernels/miui/dtb
    cp build_artifacts/miui/dtb_oc anykernel/dtb_oc
    cp build_artifacts/miui/dtb_stock anykernel/dtb_stock
    cp build_artifacts/miui/dtb anykernel/dtb
elif [ "$TARGET_OS" == "coloros" ]; then
    mkdir -p anykernel/kernels/coloros/
    cp build_artifacts/miui/Image anykernel/kernels/coloros/Image
    cp build_artifacts/miui/dtb anykernel/kernels/coloros/dtb
    cp build_artifacts/miui/Image anykernel/Image
    cp build_artifacts/miui/dtb_oc anykernel/dtb_oc
    cp build_artifacts/miui/dtb_stock anykernel/dtb_stock
    cp build_artifacts/miui/dtb anykernel/dtb
else
    mkdir -p anykernel/kernels/aosp/ anykernel/kernels/miui/ anykernel/kernels/coloros/
    cp build_artifacts/aosp/Image anykernel/kernels/aosp/Image
    cp build_artifacts/aosp/dtb anykernel/kernels/aosp/dtb
    cp build_artifacts/miui/Image anykernel/kernels/miui/Image
    cp build_artifacts/miui/dtb anykernel/kernels/miui/dtb
    cp build_artifacts/miui/Image anykernel/kernels/coloros/Image
    cp build_artifacts/miui/dtb anykernel/kernels/coloros/dtb
    cp build_artifacts/miui/dtb_oc anykernel/dtb_oc
    cp build_artifacts/miui/dtb_stock anykernel/dtb_stock
    cp build_artifacts/miui/dtb anykernel/dtb
fi

# DO NOT include dtbo (preserve panel/touch drivers from ROM)
rm -f anykernel/dtbo.img anykernel/kernels/dtbo.img anykernel/kernels/*/*.img 2>/dev/null
cp -f anykernel_template/anykernel.sh anykernel/anykernel.sh
[ -d anykernel_template/tools ] && cp -rf anykernel_template/tools/* anykernel/tools/ 2>/dev/null || true

cd anykernel

if [ "$TARGET_OS" == "aosp" ]; then
    ZIP_FILENAME="${VARIANT_TAG}_Ki-kernel-AOSP-${KERNEL_VERSION}_${TARGET_DEVICE}_${BUILD_DATETIME}_${GIT_HASH}.zip"
elif [ "$TARGET_OS" == "miui" ]; then
    ZIP_FILENAME="${VARIANT_TAG}_Ki-kernel-MIUI-${KERNEL_VERSION}_${TARGET_DEVICE}_${BUILD_DATETIME}_${GIT_HASH}.zip"
elif [ "$TARGET_OS" == "coloros" ]; then
    ZIP_FILENAME="${VARIANT_TAG}_Ki-kernel-ColorOS-${KERNEL_VERSION}_${TARGET_DEVICE}_${BUILD_DATETIME}_${GIT_HASH}.zip"
else
    ZIP_FILENAME="${VARIANT_TAG}_Ki-kernel-Universal-${KERNEL_VERSION}_${TARGET_DEVICE}_${BUILD_DATETIME}_${GIT_HASH}.zip"
fi

zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip
mkdir -p ../release
cp -f "$ZIP_FILENAME" ../release/
mkdir -p ../../release 2>/dev/null || true
cp -f "$ZIP_FILENAME" ../../release/ 2>/dev/null || true
cp -f "$ZIP_FILENAME" /home/kiki/Downloads/ 2>/dev/null || true
mv "$ZIP_FILENAME" ../
cd ..

rm -rf build_artifacts 2>/dev/null || true

echo "=========================================================="
echo "Build Finished Successfully!"
echo "Flashable Zip: [./$ZIP_FILENAME]"
echo "=========================================================="
