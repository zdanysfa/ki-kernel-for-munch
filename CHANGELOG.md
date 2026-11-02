# Ki-kernel for POCO F4 / Redmi K40S (munch)

**Build Date:** 2026-10-31  
**Kernel Version:** Linux 4.19.325  
**Variant:** MIUI/HyperOS, AOSP, And ColorOS/OxygenOS (Universal & Single Variants)  
**Toolchain:** ZyCromerZ Clang 16.0.6 (LLVM 16.0.6 + GNU Binutils 2.47)  

---

## Ki-kernel v1.6.1 (Beta-Test) :
- Crash recovery: crash-dump mode (`download_mode`) is now off by default, so a panic or watchdog bite reboots the phone instead of leaving it dark until a forced reset. Panic reboots stay warm so the pstore log survives.
- Display: restored the stock commit/cleanup order in `msm_atomic.c`, which again runs plane cleanup before the power vote drops, and removed the `PAGE_OFFSET` pointer checks because they cannot catch a freed pointer. Added a NULL check for the old CRTC state in `_sde_kms_drm_check_dpms`.
- Binder: fixed a use-after-free write to `timesRecord` on oneway transactions (MIUI/ColorOS builds), fixed freeze stat accounting, and stopped advertising `oneway_spam_detection`, which is not implemented.
- SELinux: SID lookups for the graphics sysfs rule no longer run on the RCU-walk or atomic paths, and run once per policy load.
- Ki-Profile: cluster limits that hit a busy cpufreq lock are now retried instead of being silently lost. Thermal Guard now replays dropped cooling requests when it re-arms throttling. Reading `thermal_guard_active` no longer changes state.
- cpu-boost: releasing the input boost no longer clears the Performance profile's sched boost. Boost works are serialized, release frames no longer boost, and a 4-byte write into a `bool` sysfs value is fixed.
- Charging: the bypass filter now protects only a bypass armed by root, so other services can release their own `input_suspend`. It also covers `/proc/bypass_charging`.
- Permissions: kernel control nodes are root-only, including the boot script AnyKernel installs. `/dev/ntsync` and display/touch feature nodes stay open for apps.
- Memory: kswapd can give up again under MGLRU when reclaim makes no progress, so allocations no longer wait on it without a timeout.
- Battery: real overheating is reported up to 90°C and an unreadable fuel gauge is no longer hidden behind the last good temperature.
- Wi-Fi: restored the driver's wakelocks, so it cannot be suspended in the middle of its work.
- Suspend: the filesystem is synced before sleep again (`SUSPEND_SKIP_SYNC` off), and the autosleep retry and workqueue are back to stock.
- WebUI and Ki-Daemon: package names are validated and shell-quoted (root command injection fix). Fixed a zombie per Game Turbo change, a hang on stuck `dumpsys`, and config loss on read errors.
- Modern Binder Freeze API & Frozen Notification Subsystem (ColorOS 17 / Android 17): Backported full Google CAF / Android 17 Binder Freezer subsystem to resolve boot-loop / stuck logo on ColorOS 17 and next-gen Android. Added `/dev/binderfs/features/freeze_notification` and `oneway_spam_detection` in `binderfs.c`, added `BC_REQUEST_FREEZE_NOTIFICATION`, `BC_CLEAR_FREEZE_NOTIFICATION`, `BC_FREEZE_NOTIFICATION_DONE`, `BR_FROZEN_REPLY`, `BR_TRANSACTION_PENDING_FROZEN`, `BR_FROZEN_BINDER`, and `struct binder_frozen_state_info` in `binder.h`, and implemented fast-path freeze/thaw, safe notification cleanup, automatic rollback on timeout, frozen state inheritance on `binder_open`, and lockless freeze work delivery in `binder.c`.
- Fix HyperOS / MIUI Home Screen Freeze & Deadlock: Replaced blocking `cancel_delayed_work_sync(&input_boost_rem)` with asynchronous `cancel_delayed_work` in `drivers/cpufreq/cpu-boost.c` to prevent workqueue deadlock on consecutive touch inputs, optimized `update_policy_online()` with visited CPU mask to update policy once per cluster instead of looping all 8 cores (eliminates 62.5% of `policy->rwsem` lock contention), calibrated touch IRQ debounce to 80ms to prevent interrupt storm deadlocks with HyperOS `mi_thermald`/`perfd`, and protected userspace sched boost refcounts.
- Upgraded Compiler Optimization to -O3 (`CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=y`) for aggressive loop unrolling, SIMD auto-vectorization, and superior instruction per clock (IPC) execution
- Enabled Native ARMv8.2-A Architecture Extensions (`-march=armv8.2-a+crypto+dotprod`) to leverage hardware crypto engines and dot-product vector computation units on Snapdragon 870
- Optimized Kryo 585 / Cortex-A77 Instruction Pipeline (`-mtune=cortex-a77`) for lower CPU execution latency and smoother 120 FPS frame pacing
- Added Zero-Overhead Fast-Path Flags (`-fno-builtin-bcmp` and `-fomit-frame-pointer`) to free up general-purpose arm64 registers for active computation
- Fixed OLED power rail regulator cleanup and early Sleep of Death: Hardened `drivers/regulator/core.c` (`regulator_late_cleanup`) to permanently exempt display, OLED, and panel power rails (`display_panel_vci`, `disp_vddio_vreg`, `oled_dvdd_ldo`) from late-init power disabling, protecting the display across suspend/resume even when ROM dtbo.img lacks `regulator-always-on`, and restored display/touch power rails in munch device tree.
- Restored Full 40W QC3.5 / 15W Type-C Laptop Fast Charging with Smart Progressive Thermal Stepping: Re-enabled default Force Fast Charge (3000mA / 15W) and Screen-on Fast Charge in SMB5 driver, boosted HVDCP2/SW_ICL_MAX target current to 3.5A (up to 40W peak on 33W charger), and replaced blunt thermal bypass with intelligent 4-tier progressive thermal curve (<42°C: Level 0 [max turbo], 42–44°C: Level 1, 44–46°C: Level 2, 46–48°C: Level 3, >=48°C: hardware fallback) to eliminate persistent 50W thermal lock while maintaining lightning-fast charging on laptop Type-C and wall adapters.
- Restored AnyKernel3 v1.4 Rock-Solid ROM Detection Logic: Multi-stage detection for MIUI/HyperOS, AOSP, and ColorOS/OxygenOS/RealmeUI ports with automatic OEM display variant selection.
- AnyKernel3 GPU Selector (683 MHz OC vs 670 MHz Stock) & Native Keycheck: Volume button selection prompted before flashing boot/vendor_boot to allow choosing between OC + Undervolt (683 MHz GPU) via Vol(+) or Stock Safe Voltage (670 MHz) via Vol(-).

## Ki-kernel v1.6.0 :
- Fixed Binder Page Allocation Failure & Overnight Sleep of Death (SoD): Increased default `watermark_scale_factor` from 20 to 100 to ensure an ~80MB safety buffer between MIN and LOW watermarks, unlocked sysctl clamping so ROMs can configure safe memory margins, and allowed `kswapd` across all online CPUs during sleep so background maintenance (dexopt, backup, sync) does not cause direct reclaim failure or freeze Binder IPC
- Fixed Sysfs Invalid Permissions Warning: Corrected `ki_profile` group attribute permissions from 0666 to 0664 to eliminate kernel call trace warnings on boot
- Added Interactive Volume Key Profile Selector in AnyKernel3: Prompted before flashing boot/vendor_boot to allow users to choose between OC + Undervolt (683 MHz GPU) via Vol(+) or Stock (670 MHz) via Vol(-) with reliable key event parsing (defaults to OC+UV after 15s or when flashed via app)
- Fixed Bypass Charging on ColorOS / OxygenOS: Ignored non-root / charger-hal-pol polling writes of '0' to bypass_charging and input_suspend in SMB5 driver, keeping bypass charging persistently active during gaming
- Fixed Sleep of Death (SoD) & ADB Offline on Screen Deep Eco (screen_off_battery): Replaced blocking down_write with down_write_trylock on cpufreq policy rwsem to eliminate deadlocks with secondary CPU offlining during system suspend
- Fixed Screen-Off Requeue Storm: Silenced highpri_wq 50ms requeue loops in ki_profile when display is asleep and secondary cores are offline, eliminating timer wakeups and deep sleep aborts
- Fixed Sleep of Death & PCIe Wi-Fi Crash on Weekclock (Boeffla Wakelock Blocker): Removed wlan_pno_wl and wlan_extscan_wl from default blocked wakelocks and whitelisted wlan, pno, dwc3, and usb in is_critical_wakelock() to protect active PCIe Wi-Fi PNO scans and prevent ADB going offline during idle
- Fixed Dynamic Fsync Screen-Off Suspend Hang: Protected ksys_sync() with a kernel wakeup_source (dyn_fsync_ws) so the device cannot enter deep suspend while storage flush is executing, eliminating UFS I/O state D hangs
- Ported task_is_critical() (oom_score_adj <= -900) to mm/vmscan.c to skip direct reclaim throttling on SurfaceFlinger, display composer, and camera (eliminates video stuttering, camera lag, and UI rendering stalls)
- Optimized OPlus Enforcing Spoofing in selinuxfs.c targeting Play Integrity / GMS and user apps while preserving permissive state for system service daemons to prevent hardware service denials (URCC, RIL, camera, audio, sensors)
- Fixed AnyKernel3 auto-detection order: Checks recovery system fingerprint (ro.system.build.fingerprint), /system_root/my_product, and system build.prop before checking vendor region to guarantee ColorOS / OxygenOS / RealmeUI ports are never misdetected as MIUI
- Added 2000ms debounce (KI_PSY_SETTLE_MS) in power supply notifier to eliminate SMB5 IRQ storms and severe thermal/profile throttling lag when connecting a charger
- Added 2-second debounce in ki_daemon bypass charging controller to eliminate charger flapping during plug-in
- Removed kernel-side vm_swappiness overrides in ki_profile to let ROM defaults manage swap behavior
- Disabled CONFIG_PROC_CHILDREN in defconfig to eliminate useless task traversal overhead
- Completely eliminated redundant ki_profile dmesg log spam by tracking last applied profile mode
- Fixed screen-off suspend aborts (alarmtimer.0.auto error -16) by lengthening daemon poll interval to 10s when display is asleep (fixes heavy battery drain)
- Optimized daemon polling lifecycle (1.5s during gaming, 3.0s during regular usage, 10.0s when screen is off)
- Corrected MGLRU presets in WebUI (Mode 1: Safe/Gaming vs Mode 7: Aggressive/Multitasking) to prevent page-table lock stalls while gaming
- Added Fast Reboot (Zygote restart) in WebUI for AOSP with automatic detection and safe reboot on HyperOS/MIUI
- Added Android system notifications when Game Turbo activates and deactivates

## Ki-kernel v1.5.1 :
- Tuned Balanced profile WALT migration margins to 90/82 (fixed severe FPS drop & stutter in 120Hz/90Hz)
- Raised Balanced profile down-rate hold duration (down_us) to 5000us (5ms) to eliminate mid-frame dips
- Accelerated Balanced profile ramp-up (up_us) to 850us / 2850us / 3850us for smooth touch response
- Optimized Balanced hispeed load thresholds to 82% / 82% / 84% for responsive mid-load transitions
- Added modest I/O wait boost (iowait_boost_max = 5) in Balanced mode to eliminate storage lag
- Retained 1.80GHz / 2.05GHz / 2.36GHz frequency ceilings in Balanced profile for maximum thermal comfort
- Fixed Auto Game Turbo toggle lifecycle bug in WebUI & Ki-Daemon (prevented toggling back ON)
- Added native 'ki_daemon start' command to spawn detached background processes without external nohup dependency
- Implemented graceful pause state (DAEMON_ENABLED=0) in Ki-Daemon instead of abrupt SIGKILL/stale PID traps
- Added instant status file generation with 0666 permissions on Ki-Daemon startup to prevent WebUI race conditions
- Expanded built-in Auto Game Turbo game detections (Sky: Children of the Light, Free Fire MAX, Roblox, Minecraft, eFootball, CarX Street, Blood Strike, Honor of Kings, Honkai Impact 3, etc.)
- Hardened kernel Universal Thermal Auto-Guard with persistent user override and pocket safety

## Ki-kernel v1.5 :
- Updated BakaSU and ReSukiSU to UAPI v6
- Added full FinaSU Manager support
- Added 32-bit userspace KernelSU compatibility
- Added kernel-side per-app network isolation
- Synced SuSFS v2.3.0 inline hooks and bugfixes
- Added automated SuSFS early-boot spoofing
- Added SuSFS priority UID filter protection
- Updated NoMount kernel integration to v2.2.0
- Fixed Kernel Manager sysfs SELinux denials
- Ported hardware AOSP DC Dimming support
- Fixed display sysfs SELinux permission issues
- Improved SDE KCAL hardware color calibration
- Fixed Force Fast Charge on wall adapters
- Restored full 67W PPS turbo charging
- Fixed random thermal shutdowns while charging
- Fixed duplicate charger sysfs registration warnings
- Tuned Battery, Balanced, and Performance profiles
- Tuned CPU scheduling and gaming frame pacing
- Fixed screen-off wakeup freezes and AOD issues
- Hardened Ki-Profile sysfs and worker stability
- Fixed Adreno GPU freezes and Sleep of Death
- Fixed MGLRU lock contention and app freezes
- Set BFQ and Maple as default I/O schedulers
- Improved BBRv3 network congestion control
- Fixed USB tethering and DHCP connection issues
- Improved Droidspaces and Linux container support
- Added OPlus Frame Boost and SchedAssist support
- Fixed OPlus port netlink and driver issues
- Improved AnyKernel3 universal Multi-ROM detection

## Ki-kernel v1.4.1:
• Backported modern eBPF features for Android 16 and 17
• Cherry-picked selected commits from re-noroi/FD and e404
• Fixed BPF loader bootloops on newer Android ROMs
• Added dynamic kernel version reporting for BPF loaders
• Added OPlus subsystem support for ColorOS, OxygenOS and RealmeUI ports
• Added OPlus NANDswap and charging subsystem compatibility
• Improved AnyKernel3 ROM detection for AOSP, MIUI, HyperOS and OPlus ports
• Fixed Sleep of Death and screen-off hangs
• Fixed CPU governor switch kernel panics and use-after-free crashes
• Restored 300MHz CPU idle frequency
• Tuned schedutil, WALT, CPU migration and hispeed thresholds
• Added per-cluster CPU frequency controls in Ki-Profile
• Improved Battery Saver and Balanced profile tuning
• Improved screen-off battery life and dynamic refresh rate handling
• Added thermal auto-guard with temperature-based protection
• Improved CPU and GPU stability under heavy loads
• Improved bypass charging safety and charger disconnect handling
• Fixed fast charging cutoff, thermal limits and charging state handling
• Set Force Fast Charge and Screen-On Fast Charge to OFF by default
• Added non-root controls for Ki-Profile and charging features
• Expanded KernelSU manager compatibility
• Fixed KernelSU root detection and restored SuSFS inline hooks
• Added Boeffla Wakelock Blocker with a configurable toggle
• Fixed background music playback stopping when the screen is off
• Improved memory management with MGLRU and LMKD tuning
• Fixed excessive kswapd activity under heavy ZRAM usage
• Improved app retention and reduced unnecessary background app kills
• Added Adreno 650 GPU idle frequency reporting
• Retained Adreno 650 GPU undervolt and overclock profiles
• Fixed DC Dimming support on AOSP and compatible AMOLED panels
• Fixed Night Light and LiveDisplay on supported custom ROMs
• Added KCAL hardware color calibration support
• Added Dynamic Fsync control
• Added ADIOS multi-queue I/O scheduler
• Added NoMount kernel integration
• Added native Linux container support for Droidspaces, LXC and Docker
• Added BINFMT_MISC binary emulation support
• Backported Futex2 multi-wait support
• Added EROFS compression and security xattr support
• Improved block I/O and asynchronous bio submission
• Improved CPU locking and memory mapping performance
• Tuned real-time timer handling for SurfaceFlinger, audio and GPU workers
• Fixed touchscreen sleep errors and display-related issues
• Fixed IR blaster transmission issues
• Improved boot image ramdisk decompression and AOSP boot compatibility
• Added a lockless per-CPU Blake2s random number generator
• Updated Clang ThinLTO and fixed vendor module loading
• Added multi-stage thermal, charging and screen-off profile handling
• Improved container networking and systemd cgroup compatibility

---

## Ki-kernel v1.4

Changelog:
• Backported modern eBPF support for Android 16 and 17
• Fixed BPF loader boot issues on newer Android ROMs
• Added dynamic kernel version reporting for BPF loaders
• Added Adreno 650 GPU idle frequency reporting
• Retained custom GPU undervolt and overclock profiles
• Updated BakaSU and ReSukiSU integration
• Fixed KernelSU Manager root detection
• Synced SuSFS v2.3.0 inline hooks
• Added non-root Ki-Profile controls
• Added non-root bypass charging controls
• Added Force Fast Charge controls
• Added universal DC Dimming support
• Added KCAL hardware color calibration
• Added Dynamic Fsync controls
• Tuned CPU scheduling and gaming frame pacing
• Improved RAM reclaim and multitasking behavior
• Improved Deep Sleep and background power consumption
• Fixed screen-off charging freezes and Sleep of Death
• Fixed AOSP boot freezes and kernel panic issues
• Fixed lockscreen and display refresh-rate issues
• Improved battery protection and bypass charging handling
• Added native Linux container support
• Added NoMount kernel integration
• Added ADIOS I/O scheduler
• Added CAKE queue management support
• Added PS5 DualSense controller support
• Improved touchscreen and haptic driver handling
• Fixed background music playback during screen-off
• Improved AnyKernel3 flashing and DTB handling
• Unified support for Android 13–17 ROM builds

---

## v1.4
• Switched default ZRAM compression to LZ4
• Fixed hardware DC Dimming
• Tuned Ki-Profile for higher gaming performance
• Improved CPU migration and schedutil response
• Tuned RAM, VM and kswapd behavior
• Improved Force Fast Charge and Screen-On Fast Charge
• Set ZRAM and system swappiness to 90
• Backported Binder TF_CLEAR_BUF support
• Added USB UAS support
• Added NTFS filesystem support
• Fixed CPU idle frequency and wake-from-idle issues
• Fixed MIUI and AnyKernel3 flashing issues
• Backported epoll_pwait2 and improved TCP Westwood
• Optimized CFS load balancing
• Optimized Focaltech touch and aw86927 haptic handling
• Removed Adreno POPP throttling and Wi-Fi debug wakelocks
• Added Boeffla Wakelock Blocker
• Improved Deep Sleep and suspend behavior
• Added Virtual A/B snapshot support
• Tuned F2FS background GC
• Improved GPU and touchscreen thread scheduling
• Enabled Clang ThinLTO
---

## v1.3
• Added in-kernel ki_profile switcher (Battery / Balanced / Performance)
• Added Dynamic Fsync
• Migrated to ReSukiSU v4.2.0
• Backported NTSYNC driver
• Upstream SUSFS v2.3.0
• Improved CPU idle frequency handling
• Added I/O wait boost limits
• Fixed Wi-Fi hotspot and tethering
• Improved bypass charging handling
• Migrated to ZyCromerZ Clang 16.0.6

---
  <a href="https://t.me/+i7NfuXZA6mZjOWJl">
    <img src="https://img.shields.io/badge/Telegram-26A5E4?style=for-the-badge&logo=telegram&logoColor=white" alt="Telegram">
  </a>

