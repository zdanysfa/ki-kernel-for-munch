### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## Ki-kernel AOSP for SM8250 (munch)

### AnyKernel setup
properties() { '
kernel.string=Ki-kernel
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=munch
device.name2=munchin
device.name3=alioth
device.name4=aliothin
device.name5=apollo
device.name6=apolloin
device.name7=lmi
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
patch_vbmeta_flag=auto;
NO_BLOCK_DISPLAY=1;

. tools/ak3-core.sh;

ui_print " ";
ui_print "  ===========================================";
ui_print "  |         Ki-Kernel v1.6.0 | munch        |";
ui_print "  |                                         |";
ui_print "  ===========================================";
ui_print " ";

# Pick kernel Image (Advanced Multi-Stage ROM Detection)
if [ -f "$AKHOME/kernels/miui/Image" ] && [ -f "$AKHOME/kernels/aosp/Image" ]; then
    IS_MIUI=0;
    IS_AOSP=0;
    IS_OPLUS=0;
    ROM_TYPE="";
    ROM_DETAIL="";

    # 1. Check for manual override flags
    if [ -f /tmp/aosp ] || [ -f /sdcard/aosp ] || [ -f /data/aosp ]; then
        IS_AOSP=1;
        ROM_TYPE="AOSP (Manual Override)";
    elif [ -f /tmp/miui ] || [ -f /sdcard/miui ] || [ -f /data/miui ] || [ -f /tmp/hyperos ] || [ -f /sdcard/hyperos ]; then
        IS_MIUI=1;
        ROM_TYPE="MIUI / HyperOS (Manual Override)";
    elif [ -f /tmp/oplus ] || [ -f /sdcard/oplus ] || [ -f /data/oplus ] || \
         [ -f /tmp/oos ] || [ -f /sdcard/oos ] || [ -f /data/oos ] || \
         [ -f /tmp/coloros ] || [ -f /sdcard/coloros ] || [ -f /data/coloros ] || \
         [ -f /tmp/realme ] || [ -f /sdcard/realme ] || [ -f /data/realme ] || \
         [ -f /tmp/realmeui ] || [ -f /sdcard/realmeui ] || [ -f /data/realmeui ]; then
        IS_OPLUS=1;
        ROM_TYPE="ColorOS / OxygenOS / RealmeUI Port (Manual Override)";
    fi;

    # 2. Check live getprop if available (flashed from booted Android via ksud / FK Kernel Manager / TWRP)
    if [ "$IS_AOSP" -eq 0 ] && [ "$IS_MIUI" -eq 0 ] && [ "$IS_OPLUS" -eq 0 ]; then
        if command -v getprop >/dev/null 2>&1; then
            OPLUS_PROP=$(getprop ro.build.version.oplusrom 2>/dev/null);
            [ -z "$OPLUS_PROP" ] && OPLUS_PROP=$(getprop ro.coloros.version 2>/dev/null);
            [ -z "$OPLUS_PROP" ] && OPLUS_PROP=$(getprop ro.oxygen.version 2>/dev/null);
            [ -z "$OPLUS_PROP" ] && OPLUS_PROP=$(getprop ro.build.version.opporom 2>/dev/null);
            [ -z "$OPLUS_PROP" ] && OPLUS_PROP=$(getprop ro.realme.version 2>/dev/null);
            [ -z "$OPLUS_PROP" ] && OPLUS_PROP=$(getprop ro.oplus.image.my_product.version 2>/dev/null);
            [ -z "$OPLUS_PROP" ] && OPLUS_PROP=$(getprop ro.build.oplus_version 2>/dev/null);

            BRAND=$(getprop ro.product.system.brand 2>/dev/null);
            [ -z "$BRAND" ] && BRAND=$(getprop ro.product.brand 2>/dev/null);
            [ -z "$BRAND" ] && BRAND=$(getprop ro.product.vendor.brand 2>/dev/null);

            MANUF=$(getprop ro.product.system.manufacturer 2>/dev/null);
            [ -z "$MANUF" ] && MANUF=$(getprop ro.product.manufacturer 2>/dev/null);

            DISP_ID=$(getprop ro.build.display.id 2>/dev/null);

            OS_NAME=$(getprop ro.mi.os.version.name 2>/dev/null);
            MIUI_NAME=$(getprop ro.miui.ui.version.name 2>/dev/null);
            BUILD_INC=$(getprop ro.build.version.incremental 2>/dev/null);
            SYS_NAME=$(getprop ro.product.system.name 2>/dev/null);
            SYS_MODEL=$(getprop ro.product.system.model 2>/dev/null);

            # Check OPlus first (ColorOS / OxygenOS / RealmeUI)
            if [ -n "$OPLUS_PROP" ]; then
                IS_OPLUS=1;
                ROM_TYPE="OPlus Port (ColorOS / OxygenOS / RealmeUI)";
                ROM_DETAIL="$OPLUS_PROP";
            elif echo "$BRAND $MANUF $DISP_ID" | grep -i -q -E "oneplus|oppo|realme|coloros|oxygenos|realmeui"; then
                IS_OPLUS=1;
                ROM_TYPE="OPlus Port (ColorOS / OxygenOS / RealmeUI)";
                ROM_DETAIL="${DISP_ID:-$BRAND}";
            elif [ -n "$OS_NAME" ] || echo "$BUILD_INC" | grep -q -E "^OS[0-9]"; then
                IS_MIUI=1;
                ROM_TYPE="Xiaomi HyperOS";
                ROM_DETAIL="${OS_NAME:-$BUILD_INC}";
            elif [ -n "$MIUI_NAME" ] || echo "$BUILD_INC" | grep -q -E "^V[0-9]"; then
                IS_MIUI=1;
                ROM_TYPE="Xiaomi MIUI";
                ROM_DETAIL="${MIUI_NAME:-$BUILD_INC}";
            elif [ -n "$SYS_NAME" ] || [ -n "$SYS_MODEL" ]; then
                IS_AOSP=1;
                ROM_TYPE="AOSP / Custom ROM";
                ROM_DETAIL="${SYS_NAME:-$SYS_MODEL}";
            fi;
        fi;
    fi;

    # 3. Recovery inspection with dynamic partition & A/B slot resolution
    if [ "$IS_AOSP" -eq 0 ] && [ "$IS_MIUI" -eq 0 ] && [ "$IS_OPLUS" -eq 0 ]; then
        # Detect active slot
        SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null);
        [ -z "$SLOT" ] && SLOT=$(grep -o 'androidboot\.slot_suffix=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2);

        # Mount system partition if not already mounted
        SYSTEM_MOUNTED=0;
        if [ ! -f /system/build.prop ] && [ ! -f /system/system/build.prop ] && [ ! -f /system_root/system/build.prop ]; then
            mkdir -p /s_chk 2>/dev/null;
            for dev in "/dev/block/mapper/system$SLOT" "/dev/block/mapper/system" \
                       "/dev/block/bootdevice/by-name/system$SLOT" "/dev/block/bootdevice/by-name/system"; do
                if [ -b "$dev" ]; then
                    mount -o ro "$dev" /s_chk 2>/dev/null && { SYSTEM_MOUNTED=1; break; };
                fi;
            done;
        fi;

        # Mount product partition if available
        PRODUCT_MOUNTED=0;
        if [ ! -f /product/build.prop ] && [ ! -f /product/etc/build.prop ]; then
            mkdir -p /p_chk 2>/dev/null;
            for dev in "/dev/block/mapper/product$SLOT" "/dev/block/mapper/product" \
                       "/dev/block/bootdevice/by-name/product$SLOT" "/dev/block/bootdevice/by-name/product"; do
                if [ -b "$dev" ]; then
                    mount -o ro "$dev" /p_chk 2>/dev/null && { PRODUCT_MOUNTED=1; break; };
                fi;
            done;
        fi;

        # Mount my_product partition if present (Universal hallmark of OPlus / ColorOS / OxygenOS)
        MY_PRODUCT_MOUNTED=0;
        if [ ! -d /my_product ] || [ ! -f /my_product/build.prop ]; then
            mkdir -p /m_chk 2>/dev/null;
            for dev in "/dev/block/mapper/my_product$SLOT" "/dev/block/mapper/my_product" \
                       "/dev/block/bootdevice/by-name/my_product$SLOT" "/dev/block/bootdevice/by-name/my_product"; do
                if [ -b "$dev" ]; then
                    mount -o ro "$dev" /m_chk 2>/dev/null && { MY_PRODUCT_MOUNTED=1; break; };
                fi;
            done;
        fi;

        # 3a. Universal check for ALL ColorOS / OxygenOS / RealmeUI ports:
        # Check OPlus proprietary partitions, mount points, framework, and vendor port files
        OPLUS_INDICATORS="/my_product/build.prop /my_product/etc/build.prop /m_chk/build.prop /m_chk/etc/build.prop \
                          /s_chk/my_product /s_chk/system/my_product /s_chk/system/framework/oplus-framework.jar \
                          /s_chk/system/framework/coloros-framework.jar /system/framework/oplus-framework.jar \
                          /system/framework/coloros-framework.jar /s_chk/system/priv-app/OplusSystemUI \
                          /s_chk/priv-app/OplusSystemUI /system/priv-app/OplusSystemUI \
                          /s_chk/system/priv-app/ColorOSSystemUI /system/priv-app/ColorOSSystemUI \
                          /s_chk/system/etc/oplusVersion /s_chk/etc/oplusVersion /system/etc/oplusVersion \
                          /s_chk/system/etc/oppoVersion /s_chk/etc/oppoVersion /system/etc/oppoVersion \
                          /vendor/euclid /s_chk/vendor/euclid /p_chk/vendor/euclid";

        for f in $OPLUS_INDICATORS; do
            if [ -e "$f" ]; then
                IS_OPLUS=1;
                ROM_TYPE="OPlus Port (ColorOS / OxygenOS / RealmeUI)";
                ROM_DETAIL="$(basename "$f")";
                break;
            fi;
        done;

        # Check vendor port files across all porters (e.g. Danda's OemPorts, SGSI, etc.)
        if [ "$IS_OPLUS" -eq 0 ]; then
            if ls /vendor/OemPorts*.prop >/dev/null 2>&1 || \
               ls /vendor/etc/init/OemPorts*.rc >/dev/null 2>&1 || \
               ls /system/etc/OemPorts*.prop >/dev/null 2>&1 || \
               ls /s_chk/system/etc/OemPorts*.prop >/dev/null 2>&1; then
                IS_OPLUS=1;
                ROM_TYPE="OPlus Port (OemPorts signatures verified)";
            fi;
        fi;

        # Parse build.prop files across all standard & vendor/product partitions
        PROP_LIST="/system_root/system/build.prop /system/system/build.prop /system/build.prop /system/etc/build.prop \
                   /s_chk/system/build.prop /s_chk/build.prop /s_chk/etc/build.prop \
                   /p_chk/etc/build.prop /p_chk/build.prop /product/etc/build.prop /product/build.prop \
                   /m_chk/etc/build.prop /m_chk/build.prop /my_product/etc/build.prop /my_product/build.prop \
                   /vendor/build.prop /vendor/etc/build.prop /vendor/euclid/euclid.prop";

        # Check OPlus props in files
        if [ "$IS_OPLUS" -eq 0 ]; then
            for prop in $PROP_LIST; do
                if [ -f "$prop" ]; then
                    OPLUS_FIND=$(grep -E "^(ro\.build\.version\.(oplus|oppo)rom|ro\.(coloros|oxygen|realme)\.version|ro\.oplus\.image\.my_product\.version)=" "$prop" 2>/dev/null | head -n 1 | cut -d= -f2);
                    if [ -n "$OPLUS_FIND" ]; then
                        IS_OPLUS=1;
                        ROM_TYPE="OPlus Port (ColorOS / OxygenOS / RealmeUI)";
                        ROM_DETAIL="$OPLUS_FIND";
                        break;
                    fi;
                    OPLUS_BRAND_FIND=$(grep -E "^ro\.product\.(system\.)?(brand|manufacturer)=(OnePlus|OPPO|realme)" "$prop" 2>/dev/null | head -n 1);
                    if [ -n "$OPLUS_BRAND_FIND" ]; then
                        IS_OPLUS=1;
                        ROM_TYPE="OPlus Port (ColorOS / OxygenOS / RealmeUI)";
                        ROM_DETAIL="$(echo "$OPLUS_BRAND_FIND" | cut -d= -f2)";
                        break;
                    fi;
                fi;
            done;
        fi;

        # 3b. Check distinctive Xiaomi-exclusive hardware feature files (100% reliable for MIUI/HyperOS)
        if [ "$IS_OPLUS" -eq 0 ]; then
            FEATURE_FILES="/s_chk/system/etc/device_features/munch.xml /s_chk/etc/device_features/munch.xml \
                           /system_root/system/etc/device_features/munch.xml /system/etc/device_features/munch.xml \
                           /p_chk/etc/device_features/munch.xml /product/etc/device_features/munch.xml";
            for f in $FEATURE_FILES; do
                if [ -f "$f" ]; then
                    IS_MIUI=1;
                    ROM_TYPE="Xiaomi MIUI / HyperOS (device_features verified)";
                    break;
                fi;
            done;
        fi;

        # Check Xiaomi proprietary app structures
        if [ "$IS_OPLUS" -eq 0 ] && [ "$IS_MIUI" -eq 0 ]; then
            MIUI_DIRS="/s_chk/system/priv-app/MiuiSystemUI /s_chk/priv-app/MiuiSystemUI \
                       /system_root/system/priv-app/MiuiSystemUI /system/priv-app/MiuiSystemUI \
                       /p_chk/priv-app/MiuiSystemUI /product/priv-app/MiuiSystemUI \
                       /s_chk/system/framework/miui.jar /system_root/system/framework/miui.jar";
            for d in $MIUI_DIRS; do
                if [ -e "$d" ]; then
                    IS_MIUI=1;
                    ROM_TYPE="Xiaomi MIUI / HyperOS (framework verified)";
                    break;
                fi;
            done;
        fi;

        # Check HyperOS / MIUI signature props (including E404 region detection)
        if [ "$IS_OPLUS" -eq 0 ] && [ "$IS_MIUI" -eq 0 ]; then
            for prop in $PROP_LIST; do
                if [ -f "$prop" ]; then
                    HOS_VAL=$(grep -E "^ro\.mi\.os\.version\.name=" "$prop" 2>/dev/null | head -n 1 | cut -d= -f2);
                    MIUI_VAL=$(grep -E "^ro\.miui\.ui\.version\.name=" "$prop" 2>/dev/null | head -n 1 | cut -d= -f2);
                    INC_VAL=$(grep -E "^ro\.build\.version\.incremental=" "$prop" 2>/dev/null | head -n 1 | cut -d= -f2);
                    REGION_VAL=$(grep -E "^ro\.(vendor\.)?miui\.build\.region=" "$prop" 2>/dev/null | head -n 1 | cut -d= -f2);

                    if [ -n "$HOS_VAL" ] || echo "$INC_VAL" | grep -q -E "^OS[0-9]"; then
                        IS_MIUI=1;
                        ROM_TYPE="Xiaomi HyperOS";
                        ROM_DETAIL="${HOS_VAL:-$INC_VAL}";
                        break;
                    elif [ -n "$MIUI_VAL" ] || echo "$INC_VAL" | grep -q -E "^V[0-9]"; then
                        IS_MIUI=1;
                        ROM_TYPE="Xiaomi MIUI";
                        ROM_DETAIL="${MIUI_VAL:-$INC_VAL}";
                        break;
                    elif case "$REGION_VAL" in cn|in|ru|id|eu|tr|tw|gb|global|mx|jp|kr|lm|cl|mi) true;; *) false;; esac; then
                        IS_MIUI=1;
                        ROM_TYPE="Xiaomi MIUI / HyperOS";
                        ROM_DETAIL="Region: $REGION_VAL";
                        break;
                    fi;
                fi;
            done;
        fi;

        # Check distinctive AOSP / Custom ROM signature props
        if [ "$IS_OPLUS" -eq 0 ] && [ "$IS_MIUI" -eq 0 ]; then
            for prop in $PROP_LIST; do
                if [ -f "$prop" ]; then
                    AOSP_MATCH=$(grep -i -E "lineage|crdroid|evolution|pixel|arrow|havoc|aosp|corvus|spark|matrixx|rising|cherish|derp|paranoid|hentai|superior|axion|yaap|voltage|elixir" "$prop" 2>/dev/null | head -n 1);
                    if [ -n "$AOSP_MATCH" ]; then
                        IS_AOSP=1;
                        ROM_TYPE="AOSP / Custom ROM";
                        break;
                    fi;
                fi;
            done;
        fi;

        # Clean up temporary inspection mounts
        [ "$SYSTEM_MOUNTED" -eq 1 ] && { umount /s_chk 2>/dev/null; rm -rf /s_chk 2>/dev/null; };
        [ "$PRODUCT_MOUNTED" -eq 1 ] && { umount /p_chk 2>/dev/null; rm -rf /p_chk 2>/dev/null; };
        [ "$MY_PRODUCT_MOUNTED" -eq 1 ] && { umount /m_chk 2>/dev/null; rm -rf /m_chk 2>/dev/null; };
    fi;

    # Apply selected kernel Image and matching DTB
    ui_print "--------------------------------------";
    if [ "$IS_OPLUS" -eq 1 ]; then
        if [ -n "$ROM_DETAIL" ]; then
            ui_print "  -> ROM Detected : ${ROM_TYPE:-ColorOS / OxygenOS / RealmeUI Port} ($ROM_DETAIL)";
        else
            ui_print "  -> ROM Detected : ${ROM_TYPE:-ColorOS / OxygenOS / RealmeUI Port}";
        fi;
        ui_print "  -> Compatibility: Universal OPlus Port Mode";
        ui_print "  -> Kernel Target: OEM Display variant (Xiaomi DSI timings)";
        ui_print "  -> Stub Drivers : OPlus Watchdog & Daemons Bypass active";
        rom_arg="rom_port";
        if [ -f "$AKHOME/kernels/coloros/Image" ]; then
            cp -f "$AKHOME/kernels/coloros/Image" "$AKHOME/Image";
            [ -f "$AKHOME/kernels/coloros/dtb" ] && cp -f "$AKHOME/kernels/coloros/dtb" "$AKHOME/dtb_vendor";
        else
            cp -f "$AKHOME/kernels/miui/Image" "$AKHOME/Image";
            [ -f "$AKHOME/kernels/miui/dtb" ] && cp -f "$AKHOME/kernels/miui/dtb" "$AKHOME/dtb_vendor";
        fi;
    elif [ "$IS_MIUI" -eq 1 ] && [ "$IS_AOSP" -eq 0 ]; then
        rom_arg="rom_oem";
        if [ -n "$ROM_DETAIL" ]; then
            ui_print "  -> ROM Detected : $ROM_TYPE ($ROM_DETAIL)";
        else
            ui_print "  -> ROM Detected : ${ROM_TYPE:-Xiaomi MIUI / HyperOS}";
        fi;
        ui_print "  -> Kernel Target: MIUI / HyperOS variant";
        cp -f "$AKHOME/kernels/miui/Image" "$AKHOME/Image";
        [ -f "$AKHOME/kernels/miui/dtb" ] && cp -f "$AKHOME/kernels/miui/dtb" "$AKHOME/dtb_vendor";
    else
        rom_arg="rom_aosp";
        if [ -n "$ROM_DETAIL" ]; then
            ui_print "  -> ROM Detected : ${ROM_TYPE:-AOSP / Custom ROM} ($ROM_DETAIL)";
        else
            ui_print "  -> ROM Detected : ${ROM_TYPE:-AOSP / Custom ROM}";
        fi;
        ui_print "  -> Kernel Target: AOSP variant";
        cp -f "$AKHOME/kernels/aosp/Image" "$AKHOME/Image";
        [ -f "$AKHOME/kernels/aosp/dtb" ] && cp -f "$AKHOME/kernels/aosp/dtb" "$AKHOME/dtb_vendor";
    fi;
    ui_print "--------------------------------------";
elif [ -f "$AKHOME/kernels/coloros/Image" ]; then
    rom_arg="rom_port";
    ui_print "--------------------------------------";
    ui_print "  -> Kernel Target: ColorOS / OxygenOS / RealmeUI";
    ui_print "  -> Compatibility: Universal OPlus Port Mode";
    ui_print "  -> Stub Drivers : OPlus Watchdog & Daemons Bypass active";
    ui_print "--------------------------------------";
    cp -f "$AKHOME/kernels/coloros/Image" "$AKHOME/Image";
    [ -f "$AKHOME/kernels/coloros/dtb" ] && cp -f "$AKHOME/kernels/coloros/dtb" "$AKHOME/dtb_vendor";
elif [ -f "$AKHOME/kernels/miui/Image" ]; then
    rom_arg="rom_oem";
    ui_print "  -> Target: MIUI / HyperOS";
    cp -f "$AKHOME/kernels/miui/Image" "$AKHOME/Image";
    [ -f "$AKHOME/kernels/miui/dtb" ] && cp -f "$AKHOME/kernels/miui/dtb" "$AKHOME/dtb_vendor";
elif [ -f "$AKHOME/kernels/aosp/Image" ]; then
    rom_arg="rom_aosp";
    ui_print "  -> Target: AOSP";
    cp -f "$AKHOME/kernels/aosp/Image" "$AKHOME/Image";
    [ -f "$AKHOME/kernels/aosp/dtb" ] && cp -f "$AKHOME/kernels/aosp/dtb" "$AKHOME/dtb_vendor";
elif [ -f "$AKHOME/kernels/Image" ]; then
    rom_arg="rom_port";
    cp -f "$AKHOME/kernels/Image" "$AKHOME/Image";
    [ -f "$AKHOME/kernels/dtb" ] && cp -f "$AKHOME/kernels/dtb" "$AKHOME/dtb_vendor";
elif [ -f "$AKHOME/Image" ]; then
    rom_arg="${rom_arg:-rom_port}";
    [ -f "$AKHOME/kernels/dtb" ] && cp -f "$AKHOME/kernels/dtb" "$AKHOME/dtb_vendor";
fi;


# ----------------------------------------------------
# Interactive GPU & Voltage Profile Selector
# (Runs BEFORE flashing boot or vendor_boot)
# ----------------------------------------------------
CHOSEN_DTB="";

if [ -f "$AKHOME/dtb_oc" ] && [ -f "$AKHOME/dtb_stock" ]; then
    IS_RECOVERY=0;
    if [ "$BOOTMODE" = "false" ] || [ -z "$BOOTMODE" ] || [ -d /twres ] || [ -d /sbin ] || [ -f /sbin/recovery ] || grep -q "recovery" /proc/cmdline 2>/dev/null; then
        IS_RECOVERY=1;
    fi;

    TIMEOUT_CMD="";
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD="timeout";
    elif [ -x "$AKHOME/tools/busybox" ] && "$AKHOME/tools/busybox" timeout --help >/dev/null 2>&1; then
        TIMEOUT_CMD="$AKHOME/tools/busybox timeout";
    elif command -v busybox >/dev/null 2>&1 && busybox timeout --help >/dev/null 2>&1; then
        TIMEOUT_CMD="busybox timeout";
    fi;

    GETEVENT_CMD="";
    if command -v getevent >/dev/null 2>&1; then
        GETEVENT_CMD="getevent";
    elif [ -x /system/bin/getevent ]; then
        GETEVENT_CMD="/system/bin/getevent";
    elif [ -x /sbin/getevent ]; then
        GETEVENT_CMD="/sbin/getevent";
    fi;

    if [ "$IS_RECOVERY" -eq 1 ]; then
        ui_print " ";
        ui_print "----------------------------------------";
        ui_print " Profil GPU & Voltase:";
        ui_print "   (Vol +) OC + UV (683 MHz, Undervolt)";
        ui_print "   (Vol -) Stock   (670 MHz, Safe Volt)";
        ui_print "----------------------------------------";
        ui_print " Menunggu input tombol (timeout 15 detik, default: Stock Safe Volt)...";

        CHOSEN_DTB="stock";
        KEYCHECK_BIN="";
        if [ -x "$AKHOME/tools/keycheck" ]; then
            KEYCHECK_BIN="$AKHOME/tools/keycheck";
        elif [ -x /tmp/keycheck ]; then
            KEYCHECK_BIN="/tmp/keycheck";
        fi;

        if [ -n "$KEYCHECK_BIN" ]; then
            timeout 15 "$KEYCHECK_BIN";
            res=$?;
            if [ $res -eq 42 ]; then
                ui_print "  Selected : OC + Undervolt (683 MHz)" " ";
                CHOSEN_DTB="oc";
            elif [ $res -eq 41 ]; then
                ui_print "  Selected : Stock Default (670 MHz)" " ";
                CHOSEN_DTB="stock";
            else
                ui_print "  ! Timeout reached, memakai default: Stock Default (670 MHz)" " ";
                CHOSEN_DTB="stock";
            fi;
        else
            timeout=15;
            start=$(date +%s 2>/dev/null || echo 0);

            while :; do
                key_event=$(timeout 0.2 getevent -qlc 1 2>/dev/null);

                if [ -n "$key_event" ]; then
                    if echo "$key_event" | grep -qiE "KEY_VOLUMEUP|0073"; then
                        ui_print "  Selected : OC + Undervolt (683 MHz)" " ";
                        CHOSEN_DTB="oc";
                        break;
                    fi;

                    if echo "$key_event" | grep -qiE "KEY_VOLUMEDOWN|0072"; then
                        ui_print "  Selected : Stock Default (670 MHz)" " ";
                        CHOSEN_DTB="stock";
                        break;
                    fi;
                fi;

                now=$(date +%s 2>/dev/null || echo 0);
                if [ "$start" -gt 0 ] && [ "$now" -gt 0 ] && [ $((now - start)) -ge $timeout ]; then
                    ui_print "  ! Timeout reached, memakai default: Stock Default (670 MHz)" " ";
                    CHOSEN_DTB="stock";
                    break;
                fi;
            done;
        fi;
    else
        # Flashing dari Android menyala (KernelSU / Magisk / FKM app)
        ui_print " -> Flashing via App (non-recovery): Memakai default Stock Default (670 MHz)";
        CHOSEN_DTB="stock";
    fi;
fi;

# Apply chosen DTB to vendor_boot
if [ "$CHOSEN_DTB" = "stock" ] && [ -f "$AKHOME/dtb_stock" ]; then
    cp -f "$AKHOME/dtb_stock" "$AKHOME/dtb_vendor";
elif [ -f "$AKHOME/dtb_oc" ]; then
    cp -f "$AKHOME/dtb_oc" "$AKHOME/dtb_vendor";
elif [ -f "$AKHOME/dtb_stock" ]; then
    cp -f "$AKHOME/dtb_stock" "$AKHOME/dtb_vendor";
fi;

# Preserve existing single-kernel dtb for vendor_boot before clearing boot dtb
if [ ! -f "$AKHOME/dtb_vendor" ] && [ -f "$AKHOME/dtb" ]; then
    cp -f "$AKHOME/dtb" "$AKHOME/dtb_vendor";
fi;

# DO NOT touch DTBO (preserve panel/touch drivers from ROM)
# Remove dtb from boot flashing stage (DTB on SM8250 belongs in vendor_boot)
rm -f "$AKHOME/dtb" "$AKHOME/dtbo.img" "$AKHOME/dtbo" 2>/dev/null;

# Verify that target Image exists before proceeding with flash
[ -f "$AKHOME/Image" ] || abort "  ! Image tidak ditemukan di $AKHOME (cek folder kernels/ dan paket AnyKernel3)";

# 1. Flash Kernel Image to boot partition with e404 dynamic cmdline
ui_print "- Flashing kernel (boot)...";
split_boot;
patch_cmdline "e404_args" "e404_args=${rom_arg:-rom_oem},dtbo_oem,dtb_def,batt_def";
flash_boot;

# 2. Flash DTB to vendor_boot partition
if [ -f "$AKHOME/dtb_vendor" ]; then
    ui_print "- Flashing DTB (vendor_boot)...";
    BLOCK=vendor_boot;
    reset_ak;
    rm -f "$AKHOME/Image";
    cp -f "$AKHOME/dtb_vendor" "$AKHOME/dtb";
    split_boot;
    flash_boot;
    rm -f "$AKHOME/dtb" "$AKHOME/dtb_vendor" "$AKHOME/dtb_oc" "$AKHOME/dtb_stock" 2>/dev/null;
fi;

# Setup NKM Bypass permissions and profiles on boot (if Magisk / KernelSU exists)
if [ -d /data/adb ]; then
    mkdir -p /data/adb/service.d /data/adb/post-fs-data.d;
    rm -f /data/adb/post-fs-data.d/00_early_adb.sh /data/adb/post-fs-data.d/00_maple.sh 2>/dev/null;

    cat << 'EOF' > /data/adb/service.d/00_nkm_bypass.sh
#!/system/bin/sh
SEPOLICY_CMD=""
if [ -x /data/adb/ksud ]; then
    SEPOLICY_CMD="/data/adb/ksud sepolicy patch"
elif [ -x /data/adb/ksu/bin/ksud ]; then
    SEPOLICY_CMD="/data/adb/ksu/bin/ksud sepolicy patch"
elif [ -x /data/adb/magisk/magiskpolicy ]; then
    SEPOLICY_CMD="/data/adb/magisk/magiskpolicy --live"
elif command -v magiskpolicy >/dev/null 2>&1; then
    SEPOLICY_CMD="magiskpolicy --live"
fi

if [ -n "$SEPOLICY_CMD" ]; then
    $SEPOLICY_CMD "allow untrusted_app vendor_sysfs_battery_supply dir { search read getattr open }" 2>/dev/null
    $SEPOLICY_CMD "allow untrusted_app vendor_sysfs_battery_supply file { read getattr open }" 2>/dev/null
    $SEPOLICY_CMD "allow untrusted_app_all vendor_sysfs_battery_supply dir { search read getattr open }" 2>/dev/null
    $SEPOLICY_CMD "allow untrusted_app_all vendor_sysfs_battery_supply file { read getattr open }" 2>/dev/null
    $SEPOLICY_CMD "allow system_app sysfs_ro file { read open getattr }" 2>/dev/null
    $SEPOLICY_CMD "allow hal_displayfeature_xiaomi_default vendor_default_prop property_service set" 2>/dev/null
    $SEPOLICY_CMD "allow platform_app vendor_display_prop file { read open getattr }" 2>/dev/null
    $SEPOLICY_CMD "allow vendor_hal_perf_default system_server dir search" 2>/dev/null
fi

# Battery & charging sysfs permissions
chmod 664 /sys/class/power_supply/battery/input_suspend 2>/dev/null
chmod 664 /sys/class/power_supply/battery/bypass_charging 2>/dev/null
chmod 664 /sys/class/power_supply/battery/charging_limit_current 2>/dev/null
chmod 644 /sys/class/power_supply/battery/battery_health 2>/dev/null
chmod 644 /sys/class/power_supply/battery/battery_cycle_count 2>/dev/null
chmod 664 /sys/class/power_supply/battery/battery_charging_enabled 2>/dev/null
chmod 664 /sys/class/power_supply/battery/charging_enabled 2>/dev/null

# Kernel control nodes stay root-only; only feature nodes used by apps are opened here
chmod 666 /dev/ntsync 2>/dev/null
chmod 666 /sys/devices/platform/kcal_ctrl.0/* 2>/dev/null
chmod 664 /proc/bypass_charging 2>/dev/null
chmod 664 /sys/kernel/dyn_fsync/* 2>/dev/null
chmod 664 /sys/module/sync/parameters/fsync_enabled 2>/dev/null
chmod 666 /sys/touchpanel/double_tap 2>/dev/null
chmod 666 /sys/touchpanel/reversed_keys 2>/dev/null
chmod 666 /sys/class/drm/card0-DSI-*/dimming 2>/dev/null
chmod 666 /sys/class/drm/card0-DSI-*/dc_dimming 2>/dev/null
chmod 666 /sys/class/drm/card0-DSI-*/disp_param 2>/dev/null
chmod 666 /sys/devices/platform/soc/soc:qcom,dsi-display-primary/disp_param 2>/dev/null
chmod 666 /sys/devices/platform/soc/soc:qcom,dsi-display-primary/dimming 2>/dev/null
chmod 666 /sys/devices/platform/soc/soc:qcom,dsi-display-primary/dc_dimming 2>/dev/null
chmod 666 /sys/devices/platform/soc/soc:qcom,dsi-display-primary/hbm 2>/dev/null
chmod 666 /sys/devices/virtual/mi_display/disp_feature/disp-DSI-*/disp_param 2>/dev/null
chmod 666 /sys/devices/virtual/mi_display/disp_feature/disp-DSI-*/dimming 2>/dev/null

# Fast charge nodes permission & active defaults (15W Type-C Laptop, 40W QC3.5, 67W PPS Turbo)
echo 1 > /sys/class/power_supply/battery/screen_on_fast_charge 2>/dev/null
echo 1 > /sys/kernel/fast_charge/screen_on_fast_charge 2>/dev/null
echo 1 > /sys/class/power_supply/battery/force_fast_charge 2>/dev/null
echo 1 > /sys/kernel/fast_charge/force_fast_charge 2>/dev/null
echo 1 > /proc/fast_charge 2>/dev/null
chmod 666 /sys/class/power_supply/usb/pd_authentication 2>/dev/null
echo 1 > /sys/class/power_supply/usb/pd_authentication 2>/dev/null
chmod 666 /sys/class/power_supply/battery/fastcharge_mode 2>/dev/null
echo 1 > /sys/class/power_supply/battery/fastcharge_mode 2>/dev/null
chmod 666 /sys/class/power_supply/bms/fastcharge_mode 2>/dev/null
echo 1 > /sys/class/power_supply/bms/fastcharge_mode 2>/dev/null
chmod 666 /sys/class/power_supply/bms/authentic 2>/dev/null
echo 1 > /sys/class/power_supply/bms/authentic 2>/dev/null

# Wakelock blocker permissions

# OPlus / ColorOS / OxygenOS stub nodes permissions
chmod 644 /proc/oplusVersion/* 2>/dev/null
chmod 644 /proc/oplus_charger/* 2>/dev/null
chmod 666 /proc/theiaPwkReport 2>/dev/null
chmod 666 /proc/bootprof 2>/dev/null
chmod 666 /proc/storage/buf_log 2>/dev/null
chmod 666 /proc/oplus_storage/io_metrics/forever/* 2>/dev/null
chmod 666 /proc/oplus_scheduler/sched_assist/* 2>/dev/null
chmod 666 /proc/oplus_scheduler/sched_assist/audio/* 2>/dev/null
chmod 666 /proc/oplus_frame_boost/* 2>/dev/null
chmod 666 /proc/oplus_binder/* 2>/dev/null
chmod 666 /proc/sys/fbg/* 2>/dev/null
chmod 666 /proc/oplus_afs_config/afs_config 2>/dev/null
chmod 666 /proc/oplus_mem/memory_monitor 2>/dev/null
chmod 666 /proc/devinfo/lcd* 2>/dev/null
chmod 666 /sys/class/oplus_chg/*/* 2>/dev/null

EOF
    if [ -f /data/adb/service.d/00_nkm_bypass.sh ]; then
        chmod 755 /data/adb/service.d/00_nkm_bypass.sh;
        ui_print "- Configuring security & bypass nodes...";
    fi;
fi;

ui_print " ";
ui_print "- Done! Reboot and enjoy.";
ui_print " ";
