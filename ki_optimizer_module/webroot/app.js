/**
 * Ki-Optimizer WebUI Controller
 * Native JavaScript Bridge for KernelSU WebView
 * Clean, Emoticon-free, Ultra-Responsive UI
 */

let callbackCounter = 0;
function getUniqueCallbackName(prefix) {
  return `${prefix}_cb_${Date.now()}_${callbackCounter++}`;
}

// Execute Shell Command via KernelSU Bridge
// Package names come from a config file on shared storage: never let the shell expand them.
function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function exec(command, options = {}) {
  if (typeof ksu === "undefined") {
    console.log("[Dev Mode] Shell Exec:", command);
    return Promise.resolve({ errno: 0, stdout: "", stderr: "" });
  }

  return new Promise((resolve, reject) => {
    const callbackFuncName = getUniqueCallbackName("exec");
    window[callbackFuncName] = (errno, stdout, stderr) => {
      resolve({ errno, stdout, stderr });
      delete window[callbackFuncName];
    };

    try {
      ksu.exec(command, JSON.stringify(options), callbackFuncName);
    } catch (error) {
      delete window[callbackFuncName];
      reject(error);
    }
  });
}

// Minimalist Toast notification helper
let toastTimeout = null;
function showToast(message, isError = false) {
  if (typeof ksu !== "undefined" && ksu.toast) {
    ksu.toast(message);
  }
  
  const toastEl = document.getElementById("toast");
  const toastText = document.getElementById("toast-text");
  if (toastEl && toastText) {
    toastText.textContent = message;
    toastEl.classList.toggle("toast-error", !!isError);
    toastEl.classList.add("show");
    
    if (toastTimeout) clearTimeout(toastTimeout);
    toastTimeout = setTimeout(() => {
      toastEl.classList.remove("show");
    }, 2200);
  }
}

// UI Elements - Tabs
const tabKernel = document.getElementById("tab-kernel");
const tabDaemon = document.getElementById("tab-daemon");
const panelKernel = document.getElementById("panel-kernel");
const panelDaemon = document.getElementById("panel-daemon");

// Header Telemetry
const elUnsupportedModal = document.getElementById("unsupported-modal");
const elModalKernelVer = document.getElementById("modal-kernel-ver");

const elCurProfile = document.getElementById("cur-profile");
const elCurBattery = document.getElementById("cur-battery");
const elCurTemp = document.getElementById("cur-temp");
const elDeviceModel = document.getElementById("device-model");

// Profiles
const cardProf0 = document.getElementById("card-prof-0");
const cardProf1 = document.getElementById("card-prof-1");
const cardProf2 = document.getElementById("card-prof-2");

// Kernel Feature Rows
const rowMglru = document.getElementById("row-mglru");
const badgeMglru = document.getElementById("badge-mglru");
const mglruBtns = [
  document.getElementById("btn-mglru-0"),
  document.getElementById("btn-mglru-1"),
  document.getElementById("btn-mglru-7")
];
let currentMglruMode = 1;

const rowSwappiness = document.getElementById("row-swappiness");
const rangeSwappiness = document.getElementById("range-swappiness");
const valSwappiness = document.getElementById("val-swappiness");

const rowBypass = document.getElementById("row-bypass");
const toggleBypass = document.getElementById("toggle-bypass");
const badgeBypass = document.getElementById("badge-bypass");

const rowFastCharge = document.getElementById("row-fastcharge");
const toggleFastCharge = document.getElementById("toggle-fastcharge");
const badgeFastCharge = document.getElementById("badge-fastcharge");

const rowScreenOff = document.getElementById("row-screenoff");
const toggleScreenOff = document.getElementById("toggle-screenoff");
const badgeScreenOff = document.getElementById("badge-screenoff");

const rowWakelock = document.getElementById("row-wakelock");
const toggleWakelock = document.getElementById("toggle-wakelock");
const badgeWakelock = document.getElementById("badge-wakelock");

const rowDynFsync = document.getElementById("row-dynfsync");
const toggleDynFsync = document.getElementById("toggle-dynfsync");
const badgeDynFsync = document.getElementById("badge-dynfsync");

const rowThermal = document.getElementById("row-thermal");
const toggleThermal = document.getElementById("toggle-thermal");
const badgeThermal = document.getElementById("badge-thermal");

const rowTcp = document.getElementById("row-tcp");
const selectTcp = document.getElementById("select-tcp");
const badgeTcp = document.getElementById("badge-tcp");

const btnApply = document.getElementById("btn-apply");

// Daemon Elements (Tab 2)
const elDaemonIndicator = document.getElementById("daemon-indicator");
const elDaemonStatusBadge = document.getElementById("daemon-status-badge");
const elDaemonPidBadge = document.getElementById("daemon-pid-badge");
const elDaemonFgBadge = document.getElementById("daemon-fg-badge");
const toggleDaemonMaster = document.getElementById("toggle-daemon-master");
const selectGameProf = document.getElementById("select-game-prof");
const selectExitProf = document.getElementById("select-exit-prof");
const badgeGameProf = document.getElementById("badge-game-prof");
const badgeExitProf = document.getElementById("badge-exit-prof");
const toggleAutoBypass = document.getElementById("toggle-auto-bypass");
const badgeAutoBypass = document.getElementById("badge-auto-bypass");
const toggleAutoMglru = document.getElementById("toggle-auto-mglru");
const badgeAutoMglru = document.getElementById("badge-auto-mglru");
const gamesCountEl = document.getElementById("games-count");
const inputNewGame = document.getElementById("input-new-game");
const btnAddGame = document.getElementById("btn-add-game");
const gamesChipsList = document.getElementById("games-chips-list");

let currentProfile = 1;
let isKiKernelActive = true;
let activeTab = "panel-kernel";

// Interaction tracking to prevent background telemetry stutter
let isUserInteracting = false;
let interactTimer = null;
function flagUserInteraction() {
  isUserInteracting = true;
  if (interactTimer) clearTimeout(interactTimer);
  interactTimer = setTimeout(() => {
    isUserInteracting = false;
  }, 1000);
}

document.addEventListener("touchstart", flagUserInteraction, { passive: true });
document.addEventListener("touchmove", flagUserInteraction, { passive: true });
document.addEventListener("pointerdown", flagUserInteraction, { passive: true });

// Tab Switcher
function switchTab(target) {
  activeTab = target;
  if (target === "panel-daemon") {
    tabKernel?.classList.remove("active");
    tabKernel?.setAttribute("aria-selected", "false");
    tabDaemon?.classList.add("active");
    tabDaemon?.setAttribute("aria-selected", "true");
    panelKernel?.classList.add("hidden");
    panelDaemon?.classList.remove("hidden");
    refreshDaemonState();
  } else {
    tabDaemon?.classList.remove("active");
    tabDaemon?.setAttribute("aria-selected", "false");
    tabKernel?.classList.add("active");
    tabKernel?.setAttribute("aria-selected", "true");
    panelDaemon?.classList.add("hidden");
    panelKernel?.classList.remove("hidden");
  }
}

// Helper to configure feature row support
function updateFeatureRow(row, input, badge, isSupported, isEnabled, labelOn, labelOff) {
  if (!row) return;
  if (!isSupported) {
    row.classList.add("is-unsupported");
    if (input) input.disabled = true;
    if (badge) {
      badge.textContent = "Unsupported";
      badge.classList.add("is-unsupported");
      badge.classList.remove("is-off");
    }
  } else {
    row.classList.remove("is-unsupported");
    if (input) {
      input.disabled = false;
      input.checked = isEnabled;
    }
    if (badge) {
      badge.classList.remove("is-unsupported");
      badge.textContent = isEnabled ? labelOn : labelOff;
      badge.classList.toggle("is-off", !isEnabled);
    }
  }
}

// Update Active Profile UI
function setActiveProfileUI(profileId) {
  currentProfile = parseInt(profileId, 10);
  [cardProf0, cardProf1, cardProf2].forEach(card => {
    if (card) {
      card.classList.remove("active");
      card.setAttribute("aria-pressed", "false");
    }
  });
  
  if (currentProfile === 0) {
    cardProf0?.classList.add("active");
    cardProf0?.setAttribute("aria-pressed", "true");
    if (elCurProfile) {
      elCurProfile.textContent = "BATTERY";
      elCurProfile.style.color = "var(--accent)";
    }
  } else if (currentProfile === 2) {
    cardProf2?.classList.add("active");
    cardProf2?.setAttribute("aria-pressed", "true");
    if (elCurProfile) {
      elCurProfile.textContent = "TURBO";
      elCurProfile.style.color = "var(--accent)";
    }
  } else {
    cardProf1?.classList.add("active");
    cardProf1?.setAttribute("aria-pressed", "true");
    if (elCurProfile) {
      elCurProfile.textContent = "BALANCED";
      elCurProfile.style.color = "var(--accent)";
    }
  }
}

// Instant Optimistic Profile Switcher
async function setProfileInstant(profileId) {
  if (!isKiKernelActive) return;
  const id = parseInt(profileId, 10);
  
  // Instant visual update (0ms latency feedback)
  setActiveProfileUI(id);
  const names = ["Battery Saver", "Balanced", "Turbo Gaming"];
  showToast(`Switched to ${names[id]} profile`);

  try {
    await exec(`
      echo ${id} > /proc/ki_profile 2>/dev/null
      echo ${id} > /sys/kernel/ki_profile/mode 2>/dev/null
      CONF="/sdcard/ki_optimizer.conf"
      if [ -f "$CONF" ]; then
        sed -i -E "s/^KI_PROFILE=.*/KI_PROFILE=${id}/" "$CONF" 2>/dev/null
      fi
    `);
  } catch (err) {
    console.error("setProfileInstant error:", err);
    showToast("Failed to switch profile", true);
  }
}

// Update MGLRU Segmented UI
function setMglruUI(mode, isSupported = true) {
  currentMglruMode = parseInt(mode, 10);
  if (!isSupported) {
    rowMglru?.classList.add("is-unsupported");
    mglruBtns.forEach(btn => { if (btn) btn.disabled = true; });
    if (badgeMglru) {
      badgeMglru.textContent = "Unsupported";
      badgeMglru.classList.add("is-unsupported");
    }
    return;
  }

  rowMglru?.classList.remove("is-unsupported");
  mglruBtns.forEach(btn => {
    if (btn) {
      btn.disabled = false;
      const bMode = parseInt(btn.dataset.mode, 10);
      btn.classList.toggle("active", bMode === currentMglruMode);
    }
  });

  if (badgeMglru) {
    badgeMglru.classList.remove("is-unsupported");
    if (currentMglruMode === 7) {
      badgeMglru.textContent = "Gaming Turbo (0x0007)";
      badgeMglru.classList.remove("is-off");
    } else if (currentMglruMode === 1) {
      badgeMglru.textContent = "Standard (0x0001)";
      badgeMglru.classList.remove("is-off");
    } else {
      badgeMglru.textContent = "Disabled";
      badgeMglru.classList.add("is-off");
    }
  }
}

// Live Battery & Temp Telemetry (Adaptive & Non-blocking)
async function updateTelemetry() {
  if (!isKiKernelActive || isUserInteracting) return;
  try {
    const { stdout } = await exec(`
      cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo ""
      cat /sys/class/power_supply/battery/temp 2>/dev/null || echo ""
      cat /sys/kernel/ki_profile/mode 2>/dev/null || cut -d' ' -f1 /proc/ki_profile 2>/dev/null || echo ""
    `);
    const lines = stdout.trim().split("\n");
    if (lines[0] && elCurBattery) {
      elCurBattery.textContent = `${lines[0].trim()}%`;
    }
    if (lines[1] && elCurTemp) {
      const rawTemp = parseInt(lines[1].trim(), 10);
      if (!isNaN(rawTemp)) {
        elCurTemp.textContent = `${(rawTemp / 10).toFixed(1)}°C`;
      }
    }
    if (lines[2]) {
      const liveProf = parseInt(lines[2].trim(), 10);
      if (!isNaN(liveProf) && liveProf !== currentProfile) {
        setActiveProfileUI(liveProf);
      }
    }

    if (activeTab === "panel-daemon") {
      refreshDaemonState();
    }
  } catch (err) {
    console.warn("updateTelemetry failed:", err);
  }
}

// Fetch Full Initial State from Device
async function refreshState() {
  try {
    const { stdout } = await exec(`
      KERNEL="$(uname -r)"
      IS_KI=0
      if echo "$KERNEL" | grep -qi "ki-kernel" || [ -f /proc/ki_profile ] || [ -d /sys/kernel/ki_profile ]; then
        IS_KI=1
      fi

      MODEL="$(getprop ro.product.model 2>/dev/null || echo 'POCO F4')"
      BATT="$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo '--')"
      TEMP="$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo '--')"
      
      PROF="$(cat /sys/kernel/ki_profile/mode 2>/dev/null || cut -d' ' -f1 /proc/ki_profile 2>/dev/null || echo '1')"

      # Check feature availability
      HAS_MGLRU=0
      RAW_MGLRU="0"
      if [ -f /sys/kernel/mm/lru_gen/enabled ] || [ -f /proc/mglru ]; then
        HAS_MGLRU=1
        RAW_MGLRU="$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || cat /proc/mglru 2>/dev/null || echo '0')"
      fi

      HAS_BYPASS=0
      VAL_BYPASS=0
      if [ -f /proc/bypass_charging ] || [ -f /sys/class/power_supply/battery/bypass_charging ]; then
        HAS_BYPASS=1
        VAL_BYPASS="$(cat /proc/bypass_charging 2>/dev/null || cat /sys/class/power_supply/battery/bypass_charging 2>/dev/null || echo '0')"
      fi

      HAS_FC=0
      VAL_FC=0
      if [ -f /sys/kernel/fast_charge/force_fast_charge ] || [ -f /sys/kernel/fast_charge/screen_on_fast_charge ]; then
        HAS_FC=1
        VAL_FC="$(cat /sys/kernel/fast_charge/force_fast_charge 2>/dev/null || echo '0')"
      fi

      HAS_SCREENOFF=0
      VAL_SCREENOFF=0
      if [ -f /sys/kernel/ki_profile/screen_off_battery ]; then
        HAS_SCREENOFF=1
        VAL_SCREENOFF="$(cat /sys/kernel/ki_profile/screen_off_battery 2>/dev/null || echo '0')"
      fi

      HAS_WAKELOCK=0
      VAL_WAKELOCK=0
      if [ -f /sys/kernel/wakelock_blocker/enabled ] || [ -f /sys/devices/virtual/misc/boeffla_wakelock_blocker/wakelock_blocker ]; then
        HAS_WAKELOCK=1
        VAL_WAKELOCK="$(cat /sys/kernel/wakelock_blocker/enabled 2>/dev/null || cat /sys/devices/virtual/misc/boeffla_wakelock_blocker/wakelock_blocker 2>/dev/null || echo '0')"
      fi

      HAS_DYNSYNC=0
      VAL_DYNSYNC=0
      if [ -f /sys/kernel/dyn_fsync/Dyn_fsync_active ] || [ -f /sys/kernel/dyn_fsync/dyn_fsync_active ]; then
        HAS_DYNSYNC=1
        VAL_DYNSYNC="$(cat /sys/kernel/dyn_fsync/Dyn_fsync_active 2>/dev/null || cat /sys/kernel/dyn_fsync/dyn_fsync_active 2>/dev/null || echo '0')"
      fi

      HAS_THERMAL=0
      VAL_THERMAL=1
      if [ -f /sys/kernel/ki_profile/thermal_throttle ]; then
        HAS_THERMAL=1
        VAL_THERMAL="$(cat /sys/kernel/ki_profile/thermal_throttle 2>/dev/null || echo '1')"
      fi

      VAL_SWAP="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '130')"
      VAL_TCP="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo 'cubic')"

      echo "IS_KI=$IS_KI"
      echo "KERNEL=$KERNEL"
      echo "MODEL=$MODEL"
      echo "BATT=$BATT"
      echo "TEMP=$TEMP"
      echo "PROF=$PROF"
      echo "HAS_MGLRU=$HAS_MGLRU"
      echo "RAW_MGLRU=$RAW_MGLRU"
      echo "HAS_BYPASS=$HAS_BYPASS"
      echo "VAL_BYPASS=$VAL_BYPASS"
      echo "HAS_FC=$HAS_FC"
      echo "VAL_FC=$VAL_FC"
      echo "HAS_SCREENOFF=$HAS_SCREENOFF"
      echo "VAL_SCREENOFF=$VAL_SCREENOFF"
      echo "HAS_WAKELOCK=$HAS_WAKELOCK"
      echo "VAL_WAKELOCK=$VAL_WAKELOCK"
      echo "HAS_DYNSYNC=$HAS_DYNSYNC"
      echo "VAL_DYNSYNC=$VAL_DYNSYNC"
      echo "HAS_THERMAL=$HAS_THERMAL"
      echo "VAL_THERMAL=$VAL_THERMAL"
      echo "VAL_SWAP=$VAL_SWAP"
      echo "VAL_TCP=$VAL_TCP"
    `);

    const props = {};
    stdout.trim().split("\n").forEach(line => {
      const idx = line.indexOf("=");
      if (idx > -1) {
        props[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
      }
    });

    if (props["IS_KI"] === "0") {
      isKiKernelActive = false;
      if (elUnsupportedModal) {
        elUnsupportedModal.classList.remove("hidden");
        if (elModalKernelVer) elModalKernelVer.textContent = props["KERNEL"] || "Unknown";
      }
      return;
    }

    if (elDeviceModel && props["MODEL"]) elDeviceModel.textContent = props["MODEL"];
    if (elCurBattery && props["BATT"]) elCurBattery.textContent = `${props["BATT"]}%`;
    if (elCurTemp && props["TEMP"] && props["TEMP"] !== "--") {
      const t = parseInt(props["TEMP"], 10);
      if (!isNaN(t)) elCurTemp.textContent = `${(t / 10).toFixed(1)}°C`;
    }

    setActiveProfileUI(props["PROF"] || 1);

    if (props["HAS_MGLRU"] === "1") {
      let mMode = 0;
      const raw = props["RAW_MGLRU"] || "0";
      if (raw.includes("7") || raw.includes("0x0007")) mMode = 7;
      else if (raw.includes("1") || raw.includes("0x0001")) mMode = 1;
      setMglruUI(mMode, true);
    } else {
      setMglruUI(0, false);
    }

    updateFeatureRow(rowBypass, toggleBypass, badgeBypass, props["HAS_BYPASS"] === "1", props["VAL_BYPASS"] === "1", "Active", "Off");
    updateFeatureRow(rowFastCharge, toggleFastCharge, badgeFastCharge, props["HAS_FC"] === "1", props["VAL_FC"] === "1", "Active", "Off");
    updateFeatureRow(rowScreenOff, toggleScreenOff, badgeScreenOff, props["HAS_SCREENOFF"] === "1", props["VAL_SCREENOFF"] === "1", "Active", "Off");
    updateFeatureRow(rowWakelock, toggleWakelock, badgeWakelock, props["HAS_WAKELOCK"] === "1", props["VAL_WAKELOCK"] === "1", "Active", "Off");
    updateFeatureRow(rowDynFsync, toggleDynFsync, badgeDynFsync, props["HAS_DYNSYNC"] === "1", props["VAL_DYNSYNC"] === "1", "Active", "Off");
    updateFeatureRow(rowThermal, toggleThermal, badgeThermal, props["HAS_THERMAL"] === "1", props["VAL_THERMAL"] === "1", "Active", "Bypass");

    if (badgeSwappiness && props["VAL_SWAP"]) {
      badgeSwappiness.textContent = `Default (${props["VAL_SWAP"]})`;
    }

    if (selectTcp && props["VAL_TCP"]) {
      selectTcp.value = props["VAL_TCP"];
      if (badgeTcp) badgeTcp.textContent = props["VAL_TCP"];
    }

    refreshDaemonState();
  } catch (err) {
    console.error("refreshState error:", err);
  }
}

// Apply & Persist Kernel Settings (Tab 1)
async function applyChanges(silent = false) {
  if (!isKiKernelActive) return;

  const prof = currentProfile;
  const mglru = currentMglruMode;
  const bypass = toggleBypass?.checked ? 1 : 0;
  const fastcharge = toggleFastCharge?.checked ? 1 : 0;
  const screenoff = toggleScreenOff?.checked ? 1 : 0;
  const wakelock = toggleWakelock?.checked ? 1 : 0;
  const dynfsync = toggleDynFsync?.checked ? 1 : 0;
  const thermal = toggleThermal?.checked ? 1 : 0;
  const tcp = selectTcp ? selectTcp.value : "cubic";

  const script = `
    # 1. Apply Profile
    echo ${prof} > /proc/ki_profile 2>/dev/null
    echo ${prof} > /sys/kernel/ki_profile/mode 2>/dev/null

    # 2. Apply MGLRU
    echo ${mglru} > /proc/mglru 2>/dev/null
    echo ${mglru} > /sys/kernel/mm/lru_gen/enabled 2>/dev/null

    # 3. Apply Bypass Charging
    echo ${bypass} > /proc/bypass_charging 2>/dev/null
    echo ${bypass} > /sys/class/power_supply/battery/bypass_charging 2>/dev/null

    # 4. Apply Fast Charge
    echo ${fastcharge} > /sys/kernel/fast_charge/force_fast_charge 2>/dev/null
    echo ${fastcharge} > /sys/kernel/fast_charge/screen_on_fast_charge 2>/dev/null

    # 5. Apply Screen-Off Eco
    echo ${screenoff} > /sys/kernel/ki_profile/screen_off_battery 2>/dev/null

    # 6. Apply Wakelock Blocker
    if [ "${wakelock}" = "1" ]; then
      echo 1 > /sys/kernel/wakelock_blocker/enabled 2>/dev/null
      echo 1 > /sys/devices/virtual/misc/boeffla_wakelock_blocker/wakelock_blocker 2>/dev/null
    else
      echo 0 > /sys/kernel/wakelock_blocker/enabled 2>/dev/null
      echo 0 > /sys/devices/virtual/misc/boeffla_wakelock_blocker/wakelock_blocker 2>/dev/null
    fi

    # 7. Apply Dynamic Fsync
    echo ${dynfsync} > /sys/kernel/dyn_fsync/Dyn_fsync_active 2>/dev/null
    echo ${dynfsync} > /sys/kernel/dyn_fsync/dyn_fsync_active 2>/dev/null

    # 8. Apply Thermal Throttle Guard
    if [ "${thermal}" = "0" ]; then
      echo 0 > /sys/kernel/ki_profile/thermal_throttle 2>/dev/null
    else
      echo 1 > /sys/kernel/ki_profile/thermal_throttle 2>/dev/null
    fi

    # 9. Apply TCP Congestion
    echo "${tcp}" > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null

    # 10. Persist to /sdcard/ki_optimizer.conf (Swappiness left at ROM default)
    CONF="/sdcard/ki_optimizer.conf"
    if [ -f "$CONF" ]; then
      sed -i -E "s/^KI_PROFILE=.*/KI_PROFILE=${prof}/" "$CONF" 2>/dev/null
      sed -i -E "s/^MGLRU_MODE=.*/MGLRU_MODE=${mglru}/" "$CONF" 2>/dev/null
      sed -i -E "s/^MGLRU_ENABLED=.*/MGLRU_ENABLED=${mglru}/" "$CONF" 2>/dev/null
      sed -i -E "s/^BYPASS_CHARGING=.*/BYPASS_CHARGING=${bypass}/" "$CONF" 2>/dev/null
      sed -i -E "s/^SCREEN_ON_FAST_CHARGE=.*/SCREEN_ON_FAST_CHARGE=${fastcharge}/" "$CONF" 2>/dev/null
      sed -i -E "s/^FORCE_FAST_CHARGE=.*/FORCE_FAST_CHARGE=${fastcharge}/" "$CONF" 2>/dev/null
      sed -i -E "s/^SCREEN_OFF_BATTERY=.*/SCREEN_OFF_BATTERY=${screenoff}/" "$CONF" 2>/dev/null
      sed -i -E "s/^WAKELOCK_BLOCKER=.*/WAKELOCK_BLOCKER=${wakelock}/" "$CONF" 2>/dev/null
      sed -i -E "s/^THERMAL_THROTTLE=.*/THERMAL_THROTTLE=${thermal}/" "$CONF" 2>/dev/null
      sed -i -E "s/^DYNAMIC_FSYNC=.*/DYNAMIC_FSYNC=${dynfsync}/" "$CONF" 2>/dev/null
      sed -i -E "s/^TCP_CONGESTION=.*/TCP_CONGESTION=\\"${tcp}\\"/" "$CONF" 2>/dev/null
    fi
  `;

  try {
    await exec(script);
    if (!silent) {
      const profName = prof === 0 ? "Battery Saver" : prof === 2 ? "Turbo Gaming" : "Balanced";
      showToast(`${profName} profile & tweaks applied`);
    }
  } catch (err) {
    console.error("applyChanges error:", err);
    showToast("Failed to apply settings. Check kernel support", true);
  }
}

// ==========================================
// KI-DAEMON CONTROLLER FUNCTIONS (TAB 2)
// ==========================================

async function refreshDaemonState() {
  try {
    const { stdout } = await exec(`
      OUT=""
      if command -v ki_daemon >/dev/null 2>&1; then
        OUT="$(ki_daemon status 2>/dev/null)"
      elif [ -x "/data/adb/modules/ki_optimizer/bin/ki_daemon" ]; then
        OUT="$(/data/adb/modules/ki_optimizer/bin/ki_daemon status 2>/dev/null)"
      fi
      if echo "$OUT" | grep -q '"games"'; then
        echo "$OUT"
      else
        CONF="/sdcard/ki_daemon.conf"
        [ ! -f "$CONF" ] && CONF="/data/adb/modules/ki_optimizer/ki_daemon.conf"
        ENABLED=1
        DEF_PROF=1
        GAME_PROF=2
        AUTO_BYPASS=1
        AUTO_MGLRU=1
        GAMES_JSON="[]"
        if [ -f "$CONF" ]; then
          [ "$(grep -E '^DAEMON_ENABLED=' "$CONF" | cut -d'=' -f2 | tr -d ' \"\r')" = "0" ] && ENABLED=0
          dp="$(grep -E '^DEFAULT_PROFILE=' "$CONF" | cut -d'=' -f2 | tr -d ' \"\r')"
          [ -n "$dp" ] && DEF_PROF=$dp
          gp="$(grep -E '^GAME_PROFILE=' "$CONF" | cut -d'=' -f2 | tr -d ' \"\r')"
          [ -n "$gp" ] && GAME_PROF=$gp
          [ "$(grep -E '^AUTO_BYPASS(_CHARGING)?=' "$CONF" | cut -d'=' -f2 | tr -d ' \"\r')" = "0" ] && AUTO_BYPASS=0
          [ "$(grep -E '^AUTO_MGLRU=' "$CONF" | cut -d'=' -f2 | tr -d ' \"\r')" = "0" ] && AUTO_MGLRU=0
          g_raw="$(grep -E '^GAMES=' "$CONF" | cut -d'=' -f2- | tr -d ' \"\r')"
          if [ -n "$g_raw" ]; then
            GAMES_JSON=$(echo "$g_raw" | awk -F',' '{for(i=1;i<=NF;i++) if($i!="") printf "\\"%s\\"%s", $i, (i<NF?",":"")}' | sed 's/^/[/' | sed 's/$/]/')
          fi
        fi
        echo "{\\"running\\":false,\\"daemon_enabled\\":$([ $ENABLED -eq 1 ] && echo true || echo false),\\"default_profile\\":$DEF_PROF,\\"game_profile\\":$GAME_PROF,\\"auto_bypass\\":$([ $AUTO_BYPASS -eq 1 ] && echo true || echo false),\\"auto_mglru\\":$([ $AUTO_MGLRU -eq 1 ] && echo true || echo false),\\"games\\":$GAMES_JSON}"
      fi
    `);

    let data;
    try {
      data = JSON.parse(stdout);
    } catch {
      data = { running: false };
    }

    updateDaemonUI(data);
  } catch (err) {
    console.error("refreshDaemonState error:", err);
  }
}

function updateDaemonUI(data) {
  const isRunning = !!data.running;

  if (elDaemonIndicator) {
    elDaemonIndicator.classList.toggle("is-active", isRunning && data.daemon_enabled);
  }

  if (elDaemonStatusBadge) {
    if (!isRunning) {
      elDaemonStatusBadge.textContent = "Stopped";
      elDaemonStatusBadge.style.color = "var(--danger)";
    } else if (!data.daemon_enabled) {
      elDaemonStatusBadge.textContent = "Paused";
      elDaemonStatusBadge.style.color = "var(--warning)";
    } else {
      elDaemonStatusBadge.textContent = "Active";
      elDaemonStatusBadge.style.color = "var(--accent)";
    }
  }

  if (elDaemonPidBadge) {
    elDaemonPidBadge.textContent = `PID: ${data.pid || "--"}`;
  }

  if (elDaemonFgBadge) {
    if (data.is_game) {
      elDaemonFgBadge.textContent = `GAME: ${data.foreground_pkg || "Running"}`;
      elDaemonFgBadge.classList.add("is-game");
    } else {
      elDaemonFgBadge.textContent = `App: ${data.foreground_pkg || "None"}`;
      elDaemonFgBadge.classList.remove("is-game");
    }
  }

  if (toggleDaemonMaster && typeof data.daemon_enabled !== "undefined") {
    toggleDaemonMaster.checked = data.daemon_enabled;
  }

  if (toggleAutoBypass && typeof data.auto_bypass !== "undefined") {
    toggleAutoBypass.checked = data.auto_bypass;
    if (badgeAutoBypass) {
      badgeAutoBypass.textContent = data.auto_bypass ? "Active" : "Off";
      badgeAutoBypass.classList.toggle("is-off", !data.auto_bypass);
    }
  }

  if (toggleAutoMglru && typeof data.auto_mglru !== "undefined") {
    toggleAutoMglru.checked = data.auto_mglru;
    if (badgeAutoMglru) {
      badgeAutoMglru.textContent = data.auto_mglru ? "Active" : "Off";
      badgeAutoMglru.classList.toggle("is-off", !data.auto_mglru);
    }
  }

  if (selectGameProf && typeof data.game_profile !== "undefined") {
    selectGameProf.value = data.game_profile.toString();
    if (badgeGameProf) {
      badgeGameProf.textContent = data.game_profile === 2 ? "Turbo Gaming" : "Balanced";
    }
  }

  if (selectExitProf && typeof data.default_profile !== "undefined") {
    selectExitProf.value = data.default_profile.toString();
    if (badgeExitProf) {
      badgeExitProf.textContent = data.default_profile === 0 ? "Battery Saver" : "Balanced";
    }
  }

  if (Array.isArray(data.games)) {
    renderGameChips(data.games);
  }
}

function escapeHtml(str) {
  return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function renderGameChips(games) {
  if (!gamesChipsList) return;
  if (gamesCountEl) gamesCountEl.textContent = games.length;

  gamesChipsList.innerHTML = "";
  games.forEach(pkg => {
    const chip = document.createElement("div");
    chip.className = "game-chip";
    chip.innerHTML = `
      <span>${escapeHtml(pkg)}</span>
      <button type="button" class="btn-chip-del" data-pkg="${escapeHtml(pkg)}" title="Remove game" aria-label="Remove game">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <line x1="18" y1="6" x2="6" y2="18"></line>
          <line x1="6" y1="6" x2="18" y2="18"></line>
        </svg>
      </button>
    `;
    gamesChipsList.appendChild(chip);
  });

  gamesChipsList.querySelectorAll(".btn-chip-del").forEach(btn => {
    btn.addEventListener("click", async (e) => {
      e.stopPropagation();
      const pkg = btn.dataset.pkg;
      await removeGame(pkg);
    });
  });
}

async function addGame(pkg) {
  const clean = pkg.trim();
  if (!clean) return;
  try {
    await exec(`
      if command -v ki_daemon >/dev/null 2>&1; then
        ki_daemon add-game ${shellQuote(clean)}
      elif [ -x "/data/adb/modules/ki_optimizer/bin/ki_daemon" ]; then
        /data/adb/modules/ki_optimizer/bin/ki_daemon add-game ${shellQuote(clean)}
      fi
    `);
    showToast(`Added ${clean} to Auto Game Turbo`);
    if (inputNewGame) inputNewGame.value = "";
    refreshDaemonState();
  } catch (err) {
    showToast("Failed to add game", true);
  }
}

async function removeGame(pkg) {
  try {
    await exec(`
      if command -v ki_daemon >/dev/null 2>&1; then
        ki_daemon remove-game ${shellQuote(pkg)}
      elif [ -x "/data/adb/modules/ki_optimizer/bin/ki_daemon" ]; then
        /data/adb/modules/ki_optimizer/bin/ki_daemon remove-game ${shellQuote(pkg)}
      fi
    `);
    showToast(`Removed ${pkg}`);
    refreshDaemonState();
  } catch (err) {
    showToast("Failed to remove game", true);
  }
}

async function setDaemonConfig(key, val) {
  try {
    await exec(`
      if command -v ki_daemon >/dev/null 2>&1; then
        ki_daemon set ${shellQuote(key)} ${shellQuote(val)}
      elif [ -x "/data/adb/modules/ki_optimizer/bin/ki_daemon" ]; then
        /data/adb/modules/ki_optimizer/bin/ki_daemon set ${shellQuote(key)} ${shellQuote(val)}
      fi
    `);
    showToast(`Updated ${key}`);
    refreshDaemonState();
  } catch (err) {
    showToast(`Failed to update ${key}`, true);
  }
}

// Event Listeners with Immediate Optimistic Feedback
tabKernel?.addEventListener("click", () => switchTab("panel-kernel"));
tabDaemon?.addEventListener("click", () => switchTab("panel-daemon"));

cardProf0?.addEventListener("click", () => {
  setProfileInstant(0);
});

cardProf1?.addEventListener("click", () => {
  setProfileInstant(1);
});

cardProf2?.addEventListener("click", () => {
  setProfileInstant(2);
});

mglruBtns.forEach(btn => {
  if (btn) {
    btn.addEventListener("click", () => {
      const mode = parseInt(btn.dataset.mode, 10);
      setMglruUI(mode, true);
    });
  }
});

// Instant Slider Value Reflection
rangeSwappiness?.addEventListener("input", (e) => {
  if (valSwappiness) valSwappiness.textContent = e.target.value;
});

// Optimistic Switch Status Badge Updates
toggleBypass?.addEventListener("change", (e) => {
  if (badgeBypass) {
    badgeBypass.textContent = e.target.checked ? "Active" : "Off";
    badgeBypass.classList.toggle("is-off", !e.target.checked);
  }
});

toggleFastCharge?.addEventListener("change", (e) => {
  if (badgeFastCharge) {
    badgeFastCharge.textContent = e.target.checked ? "Active" : "Off";
    badgeFastCharge.classList.toggle("is-off", !e.target.checked);
  }
});

toggleScreenOff?.addEventListener("change", (e) => {
  if (badgeScreenOff) {
    badgeScreenOff.textContent = e.target.checked ? "Active" : "Off";
    badgeScreenOff.classList.toggle("is-off", !e.target.checked);
  }
});

toggleWakelock?.addEventListener("change", (e) => {
  if (badgeWakelock) {
    badgeWakelock.textContent = e.target.checked ? "Active" : "Off";
    badgeWakelock.classList.toggle("is-off", !e.target.checked);
  }
});

toggleDynFsync?.addEventListener("change", (e) => {
  if (badgeDynFsync) {
    badgeDynFsync.textContent = e.target.checked ? "Active" : "Off";
    badgeDynFsync.classList.toggle("is-off", !e.target.checked);
  }
});

toggleThermal?.addEventListener("change", (e) => {
  if (badgeThermal) {
    badgeThermal.textContent = e.target.checked ? "Active" : "Bypass";
    badgeThermal.classList.toggle("is-off", !e.target.checked);
  }
});

selectTcp?.addEventListener("change", (e) => {
  if (badgeTcp) badgeTcp.textContent = e.target.value;
});

btnApply?.addEventListener("click", () => {
  applyChanges(false);
});

const btnSoftReboot = document.getElementById("btn-soft-reboot");
btnSoftReboot?.addEventListener("click", async () => {
  try {
    const { stdout } = await exec(`
      if grep -qiE "hyper|miui" /system/build.prop 2>/dev/null || [ -n "$(getprop ro.miui.ui.version.name)" ] || [ -n "$(getprop ro.mi.os.version.name)" ]; then
        echo "miui"
      else
        echo "aosp"
      fi
    `);
    const isMiui = stdout.trim() === "miui";
    if (isMiui) {
      showToast("Fast reboot dinonaktifkan di HyperOS/MIUI (hindari bootloop). Gunakan reboot sistem bila perlu.", true);
      return;
    }
    showToast("Memulai Fast Reboot (Restart Zygote AOSP)...");
    setTimeout(async () => {
      await exec("setprop ctl.restart zygote || svc power reboot userspace");
    }, 700);
  } catch (err) {
    showToast("Gagal melakukan Fast Reboot", true);
  }
});

// Daemon Listeners
toggleDaemonMaster?.addEventListener("change", async (e) => {
  const enabled = e.target.checked ? "1" : "0";
  try {
    if (e.target.checked) {
      await exec(`
        if command -v ki_daemon >/dev/null 2>&1; then
          ki_daemon set DAEMON_ENABLED 1
          ki_daemon start
        elif [ -x "/data/adb/modules/ki_optimizer/bin/ki_daemon" ]; then
          /data/adb/modules/ki_optimizer/bin/ki_daemon set DAEMON_ENABLED 1
          /data/adb/modules/ki_optimizer/bin/ki_daemon start
        fi
      `);
      showToast("Auto Game Turbo activated");
    } else {
      await exec(`
        if command -v ki_daemon >/dev/null 2>&1; then
          ki_daemon set DAEMON_ENABLED 0
        elif [ -x "/data/adb/modules/ki_optimizer/bin/ki_daemon" ]; then
          /data/adb/modules/ki_optimizer/bin/ki_daemon set DAEMON_ENABLED 0
        fi
      `);
      showToast("Auto Game Turbo paused");
    }
  } catch (err) {
    showToast("Failed to toggle Auto Game Turbo", true);
  }
  setTimeout(refreshDaemonState, 350);
});

toggleAutoBypass?.addEventListener("change", (e) => {
  setDaemonConfig("AUTO_BYPASS", e.target.checked ? "1" : "0");
});

toggleAutoMglru?.addEventListener("change", (e) => {
  setDaemonConfig("AUTO_MGLRU", e.target.checked ? "1" : "0");
});

selectGameProf?.addEventListener("change", (e) => {
  setDaemonConfig("GAME_PROFILE", e.target.value);
});

selectExitProf?.addEventListener("change", (e) => {
  setDaemonConfig("DEFAULT_PROFILE", e.target.value);
});

btnAddGame?.addEventListener("click", () => {
  if (inputNewGame) addGame(inputNewGame.value);
});

inputNewGame?.addEventListener("keypress", (e) => {
  if (e.key === "Enter") {
    addGame(inputNewGame.value);
  }
});

// Periodic telemetry poll (Non-blocking, paused during touch/gestures)
setInterval(updateTelemetry, 3500);

// Initialize on Load
document.addEventListener("DOMContentLoaded", () => {
  refreshState();
});
