#!/system/bin/sh
# Ki-Optimizer Boot Service

MODDIR="/data/adb/modules/ki_optimizer"
CONF_PATH="/sdcard/ki_optimizer.conf"

# Verify Ki-Kernel Support
KERNEL_VER="$(uname -r)"
if ! echo "$KERNEL_VER" | grep -qi "ki-kernel" && [ ! -f /proc/ki_profile ] && [ ! -d /sys/kernel/ki_profile ]; then
    exit 0
fi

# Wait until boot process is fully completed
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 3
done

# Ensure ki CLI and ki_daemon are linked in root PATH without touching /system
for bin_dir in /data/adb/ksu/bin /data/adb/ap/bin /data/adb/magisk; do
    if [ -d "$bin_dir" ]; then
        [ ! -e "$bin_dir/ki" ] && ln -sf "$MODDIR/bin/ki" "$bin_dir/ki" 2>/dev/null
        [ ! -e "$bin_dir/ki_daemon" ] && ln -sf "$MODDIR/bin/ki_daemon" "$bin_dir/ki_daemon" 2>/dev/null
    fi
done

# Sleep 4 seconds to ensure system settlement
sleep 4

# Ensure /sdcard/ki_optimizer.conf exists
if [ ! -f "$CONF_PATH" ]; then
    cp -f "$MODDIR/ki_optimizer.conf" "$CONF_PATH" 2>/dev/null
    chmod 666 "$CONF_PATH" 2>/dev/null
fi

# Control nodes keep their kernel permissions: ki, ki_daemon and the WebUI all run as root.

# Apply configured tweaks
if [ -x "$MODDIR/bin/ki" ]; then
    "$MODDIR/bin/ki" reload >/dev/null 2>&1
fi

# Launch Ki-Daemon (Rust Auto Game Turbo & Background Controller)
if [ -x "$MODDIR/bin/ki_daemon" ]; then
    killall ki_daemon 2>/dev/null
    rm -f /data/adb/modules/ki_optimizer/daemon.pid /data/adb/modules/ki_optimizer/daemon.status 2>/dev/null
    "$MODDIR/bin/ki_daemon" start >/dev/null 2>&1 || ( "$MODDIR/bin/ki_daemon" run >/dev/null 2>&1 & )
fi

