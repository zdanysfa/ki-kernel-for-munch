use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, ErrorKind};
use std::path::Path;
use std::process::{exit, Command};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, sleep};
use std::time::{Duration, Instant};

use signal_hook::consts::{SIGINT, SIGTERM};
use signal_hook::iterator::Signals;

const CONF_SDCARD: &str = "/sdcard/ki_daemon.conf";
const CONF_MODULE: &str = "/data/adb/modules/ki_optimizer/ki_daemon.conf";
const PID_FILE: &str = "/data/adb/modules/ki_optimizer/daemon.pid";
const STATUS_FILE: &str = "/data/adb/modules/ki_optimizer/daemon.status";
// Sengaja di tmpfs: hilang saat reboot, jadi tidak ada "recovery" basi setelah boot.
const ENGAGED_FILE: &str = "/dev/ki_daemon.engaged";

const PROFILE_NODES: [&str; 2] = ["/proc/ki_profile", "/sys/kernel/ki_profile/mode"];
const BYPASS_NODES: [&str; 2] = [
    "/proc/bypass_charging",
    "/sys/class/power_supply/battery/bypass_charging",
];
const MGLRU_NODES: [&str; 2] = ["/proc/mglru", "/sys/kernel/mm/lru_gen/enabled"];

/// lru_gen caps adalah bitmask 3 bit (0x0001 | 0x0002 | 0x0004).
const MAX_MGLRU: u32 = 7;
/// Berapa poll berturut-turut "bukan game" sebelum dianggap keluar dari game.
const EXIT_DEBOUNCE_POLLS: u32 = 2;
/// Berapa poll berturut-turut status charger harus konsisten sebelum bypass diubah (3 poll = 3s).
const PLUG_DEBOUNCE_POLLS: u32 = 3;
/// Layar harus mati selama ini sebelum Turbo/bypass dilepas.
const SCREEN_OFF_GRACE: Duration = Duration::from_secs(30);
/// Jarak minimum antar pemanggilan `dumpsys` (fork mahal).
const DUMPSYS_MIN_INTERVAL: Duration = Duration::from_secs(5);
/// Charging transient hold: delay after charger plug/unplug before allowing bypass changes.
/// SMB5 fires IRQ storms for 1-3 seconds during plug events; this prevents profile thrashing.
const CHARGE_SETTLE: Duration = Duration::from_secs(2);

const DEFAULT_GAMES: &[&str] = &[
    "com.mobile.legends",
    "com.miHoYo.GenshinImpact",
    "com.nexon.bluearchive",
    "com.YoStar.AetherGazer",
    "com.YoStarEN.Arknights",
    "com.YoStarEN.AzurLane",
    "com.hypergryph.arknights",
    "com.kurogame.haru.google",
    "com.HoYoverse.nap",
    "com.miHoYo.nap",
    "com.dts.freefireth",
    "com.dts.freefiremax",
    "com.tgc.sky.android",
    "com.roblox.client",
    "com.mojang.minecraftpe",
    "jp.konami.pesam",
    "com.ea.gp.fifamobile",
    "com.netease.bloodstrike",
    "com.carxtech.sr",
    "com.levelinfinite.sgameGlobal",
    "com.tencent.tmgp.sgame",
    "com.tencent.ig",
    "com.vng.pubgmobile",
    "com.pubg.krmobile",
    "com.rekoo.pubgm",
    "com.activision.callofduty.shooter",
    "com.garena.game.codm",
    "com.riotgames.league.wildrift",
    "com.pubg.imobile",
    "com.epicgames.fortnite",
    "com.proximabeta.mf.uamo",
    "com.levelinfinite.hotta.gp",
    "com.kurogame.wutheringwaves.global",
    "com.HoYoverse.hkrpgoversea",
    "com.miHoYo.hkrpgoversea",
    "com.miHoYo.Yuanshen",
    "com.garena.game.kgid",
    "com.garena.game.kgvn",
    "com.garena.game.kgtw",
    "com.miHoYo.bh3oversea",
    "com.miHoYo.bh3global",
    "com.netease.idv.googleplay",
    "com.kitkagames.fallbuddies",
    "it.rortos.realflightsimulator",
    "org.citra.citra_emu",
    "org.yuzu.yuzu_emu",
    "skyline.emu",
    "org.dolphinemu.dolphinemu",
    "xyz.aethersx2.android",
    "com.retroarch.aarch64",
];

const IGNORED_PACKAGES: &[&str] = &[
    "system_server",
    "surfaceflinger",
    "zygote",
    "zygote64",
    "webview_zygote",
    "com.android.systemui",
    "com.android.launcher",
    "com.android.launcher3",
    "com.miui.home",
    "com.mi.android.globallauncher",
    "com.google.android.apps.nexuslauncher",
    "com.google.android.inputmethod.latin",
    "com.touchtype.swiftkey",
    "com.google.android.gms",
    "com.android.settings",
    "android.process.media",
    "android.process.acore",
];

fn parse_bool(v: &str) -> bool {
    v == "1" || v.eq_ignore_ascii_case("true")
}

/// Config ada di shared storage dan bisa ditulis app lain: hanya terima nama paket Android.
fn is_valid_package(pkg: &str) -> bool {
    !pkg.is_empty()
        && pkg.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_')
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct DaemonConfig {
    pub enabled: bool,
    pub poll_interval_ms: u64,
    pub default_profile: u32,
    pub game_profile: u32,
    pub auto_bypass_charging: bool,
    pub auto_mglru: bool,
    pub game_mglru: u32,
    pub default_mglru: u32,
    pub games: HashSet<String>,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        let games = DEFAULT_GAMES.iter().map(|g| (*g).to_string()).collect();
        Self {
            enabled: true,
            poll_interval_ms: 1500,
            default_profile: 1, // Balanced
            game_profile: 2,    // Turbo Gaming
            auto_bypass_charging: true,
            auto_mglru: true,
            game_mglru: 1,    // 0x0001 Standard (Core LRU - no page table walk lockup)
            default_mglru: 1, // 0x0001 Standard
            games,
        }
    }
}

impl DaemonConfig {
    pub fn get_conf_path() -> &'static str {
        if Path::new(CONF_SDCARD).exists() {
            CONF_SDCARD
        } else if Path::new(CONF_MODULE).exists() {
            CONF_MODULE
        } else {
            CONF_SDCARD
        }
    }

    /// Terapkan satu pasangan key=value. Mengembalikan false kalau key tidak dikenal.
    fn apply(&mut self, key: &str, v: &str) -> bool {
        match key {
            "DAEMON_ENABLED" => self.enabled = parse_bool(v),
            "POLL_INTERVAL_MS" => {
                if let Ok(n) = v.parse::<u64>() {
                    self.poll_interval_ms = n.max(500);
                }
            }
            "DEFAULT_PROFILE" => {
                if let Ok(n) = v.parse::<u32>() {
                    self.default_profile = n;
                }
            }
            "GAME_PROFILE" => {
                if let Ok(n) = v.parse::<u32>() {
                    self.game_profile = n;
                }
            }
            "AUTO_BYPASS" | "AUTO_BYPASS_CHARGING" => self.auto_bypass_charging = parse_bool(v),
            "AUTO_MGLRU" => self.auto_mglru = parse_bool(v),
            "GAME_MGLRU" => {
                if let Ok(n) = v.parse::<u32>() {
                    if n <= MAX_MGLRU {
                        self.game_mglru = n;
                    }
                }
            }
            "DEFAULT_MGLRU" => {
                if let Ok(n) = v.parse::<u32>() {
                    if n <= MAX_MGLRU {
                        self.default_mglru = n;
                    }
                }
            }
            "GAMES" => {
                self.games.clear();
                for item in v.split(',') {
                    let pkg = item.trim();
                    if is_valid_package(pkg) {
                        self.games.insert(pkg.to_string());
                    }
                }
            }
            _ => return false,
        }
        true
    }

    pub fn load() -> Self {
        let mut cfg = DaemonConfig::default();
        let path = Self::get_conf_path();

        match File::open(path) {
            Ok(file) => {
                for line in BufReader::new(file).lines().map_while(Result::ok) {
                    let trimmed = line.trim();
                    if trimmed.is_empty() || trimmed.starts_with('#') {
                        continue;
                    }
                    if let Some((key, val)) = trimmed.split_once('=') {
                        cfg.apply(key.trim(), val.trim().trim_matches('"'));
                    }
                }
            }
            // Hanya buat file baru kalau memang belum ada; gagal baca sementara tidak boleh menimpa config user.
            Err(e) if e.kind() == ErrorKind::NotFound => cfg.save(),
            Err(e) => eprintln!("[Ki-Daemon] WARN: gagal membaca {path}: {e}"),
        }

        cfg
    }

    pub fn save(&self) {
        let path = Self::get_conf_path();
        let mut games_vec: Vec<_> = self.games.iter().cloned().collect();
        games_vec.sort();
        let games_str = games_vec.join(",");

        let content = format!(
            "# Ki-Daemon Auto Game Turbo Configuration\n\
             # Location: {path}\n\
             DAEMON_ENABLED={}\n\
             POLL_INTERVAL_MS={}\n\
             DEFAULT_PROFILE={}\n\
             GAME_PROFILE={}\n\
             AUTO_BYPASS_CHARGING={}\n\
             AUTO_MGLRU={}\n\
             GAME_MGLRU={}\n\
             DEFAULT_MGLRU={}\n\
             GAMES=\"{}\"\n",
            u8::from(self.enabled),
            self.poll_interval_ms,
            self.default_profile,
            self.game_profile,
            u8::from(self.auto_bypass_charging),
            u8::from(self.auto_mglru),
            self.game_mglru,
            self.default_mglru,
            games_str
        );

        // Lewat file sementara: pembaca lain tidak pernah melihat config yang setengah tertulis.
        let tmp = format!("{path}.tmp");
        if fs::write(&tmp, content).is_ok() && fs::rename(&tmp, path).is_ok() {
            let _ = Command::new("chmod").args(["666", path]).status();
        }
    }
}

// ---------------------------------------------------------------------------
// Low-overhead sysfs / procfs helpers
// ---------------------------------------------------------------------------

fn write_node(path: &str, val: &str) -> bool {
    fs::write(path, val).is_ok()
}

fn read_node_trimmed<P: AsRef<Path>>(path: P) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

/// Baca angka dari node pertama yang bisa dibaca. Mendukung "0x0007" maupun desimal.
fn read_u32_node(paths: &[&str]) -> Option<u32> {
    for p in paths {
        if let Some(s) = read_node_trimmed(p) {
            let parsed = match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
                Some(hex) => u32::from_str_radix(hex, 16).ok(),
                None => s.parse::<u32>().ok(),
            };
            if parsed.is_some() {
                return parsed;
            }
        }
    }
    None
}

/// Tulis ke node pertama yang berhasil; log kalau semuanya gagal.
fn write_any(nodes: &[&str], val: &str, what: &str) -> bool {
    if nodes.iter().any(|n| write_node(n, val)) {
        return true;
    }
    eprintln!("[Ki-Daemon] WARN: gagal menulis {what}={val} (node: {nodes:?})");
    false
}

fn set_kernel_profile(mode: u32) -> bool {
    let ok = write_any(&PROFILE_NODES, &mode.to_string(), "profile");
    if ok {
        // Verify write-back: read the profile to confirm kernel accepted the change
        if let Some(actual) = read_u32_node(&PROFILE_NODES) {
            if actual != mode {
                eprintln!("[Ki-Daemon] WARN: profile write mismatch! wrote {mode}, kernel has {actual}");
                // Retry once
                write_any(&PROFILE_NODES, &mode.to_string(), "profile_retry");
            }
        }
    }
    ok
}

fn set_bypass_charging(enabled: bool) -> bool {
    write_any(&BYPASS_NODES, if enabled { "1" } else { "0" }, "bypass_charging")
}

fn set_mglru(mode: u32) -> bool {
    write_any(&MGLRU_NODES, &mode.to_string(), "mglru")
}

/// Ada charger eksternal terhubung?
/// Diperiksa dari beberapa sumber berlapis:
/// 1. Semua power_supply non-baterai/non-BMS:
///    a. `online == "1"` (standar kernel power_supply)
///    b. `typec_mode` berisi kata "source" (misal "Source attached (high current)")
///    c. `present == "1"` (pada Qualcomm SMB5 / POCO F4 munch, saat bypass aktif kernel
///       secara sengaja memaksa usb/online = 0 dan battery/status = Discharging, namun
///       node `present` pada USB tetap "1" selama kabel fisik terpasang)
///    d. `voltage_now` >= 4.0V (4_000_000 uV) pada port input daya (charger/PC terpasang)
/// 2. Status baterai "Charging" atau "Full":
///    HANYA dipercaya kalau bypass sedang TIDAK aktif, karena saat bypass aktif driver
///    kernel secara sengaja melaporkan "Not charging" atau "Discharging".
fn is_charger_connected(bypass_on: bool) -> bool {
    if let Ok(dir) = fs::read_dir("/sys/class/power_supply") {
        for entry in dir.flatten() {
            let p = entry.path();
            let name = entry.file_name();
            let name_str = name.to_string_lossy();

            // Lewati baterai internal dan fuel gauge (BMS)
            if name_str.eq_ignore_ascii_case("battery") || name_str.eq_ignore_ascii_case("bms") {
                continue;
            }

            let kind = read_node_trimmed(p.join("type")).unwrap_or_default();
            if kind.eq_ignore_ascii_case("Battery") || kind.eq_ignore_ascii_case("BMS") {
                continue;
            }

            // 1a. Node `online` == "1"
            if read_node_trimmed(p.join("online")).as_deref() == Some("1") {
                return true;
            }

            // 1b. Node `typec_mode`: jika sumber daya eksternal terdeteksi
            if let Some(mode) = read_node_trimmed(p.join("typec_mode")) {
                let m = mode.to_ascii_lowercase();
                if m.contains("source") {
                    return true;
                }
                // Jika ponsel berperan sebagai power source untuk aksesoris (OTG sink), abaikan supply ini
                if m.contains("sink") && !m.contains("source") {
                    continue;
                }
            }

            // 1c. Node `present` == "1" pada USB/Mains/Wireless/AC
            if read_node_trimmed(p.join("present")).as_deref() == Some("1") {
                return true;
            }

            // 1d. Tegangan input VBUS (voltage_now) >= 4.0V (4_000_000 uV)
            if let Some(v_str) = read_node_trimmed(p.join("voltage_now")) {
                if let Ok(v) = v_str.parse::<u64>() {
                    if v >= 4_000_000 {
                        return true;
                    }
                }
            }
        }
    }

    // 2. Fallback status baterai internal: HANYA jika bypass sedang tidak aktif.
    if !bypass_on {
        if matches!(
            read_node_trimmed("/sys/class/power_supply/battery/status"),
            Some(s) if s.eq_ignore_ascii_case("Charging") || s.eq_ignore_ascii_case("Full")
        ) {
            return true;
        }
    }

    false
}

fn is_screen_on() -> bool {
    // 1. Direct in-kernel display notifier state
    if let Some(val) = read_node_trimmed("/sys/kernel/ki_profile/screen_state") {
        return val == "1";
    }
    // 2. Hardware panel backlight brightness
    if let Some(val) = read_node_trimmed("/sys/class/backlight/panel0-backlight/brightness") {
        if let Ok(b) = val.parse::<u32>() {
            return b > 0;
        }
    }
    // 3. Fallback: DRM runtime status
    if let Some(val) = read_node_trimmed("/sys/class/drm/card0/device/power/runtime_status") {
        return val == "active";
    }
    true
}

// ---------------------------------------------------------------------------
// Toast / Notification helpers
// ---------------------------------------------------------------------------

/// Show an Android notification for game turbo state changes.
/// Uses `cmd notification post` which works without a running Activity.
fn notify_game_turbo(engaged: bool, game_pkg: &str) {
    let msg = if engaged {
        format!("🎮 Game Turbo: ON — {}", game_pkg.split('.').last().unwrap_or(game_pkg))
    } else {
        "🎮 Game Turbo: OFF — Restored".to_string()
    };
    // Don't block the main loop, but reap the child so it never stays a zombie
    let child = Command::new("cmd")
        .args(["notification", "post", "-t", "Ki-Kernel", "ki_turbo", &msg])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
    if let Ok(mut child) = child {
        thread::spawn(move || {
            let _ = child.wait();
        });
    }
}

// ---------------------------------------------------------------------------
// Foreground app detection
// ---------------------------------------------------------------------------

// Strategy 1: top-app cgroup (0 fork overhead, in-memory)
fn get_foreground_app_cgroup(cfg: &DaemonConfig) -> Option<(String, bool)> {
    const CGROUP_PATHS: [&str; 3] = [
        "/dev/cpuset/top-app/cgroup.procs",
        "/sys/fs/cgroup/cpuset/top-app/cgroup.procs",
        // `tasks` berisi thread (banyak entri), jadi hanya dipakai kalau yang lain tidak ada.
        "/dev/cpuset/top-app/tasks",
    ];

    let content = CGROUP_PATHS.iter().find_map(|p| fs::read_to_string(p).ok())?;
    let mut candidate_app: Option<String> = None;

    for pid in content.lines().map(str::trim).filter(|s| !s.is_empty()) {
        let Ok(cmd_bytes) = fs::read(format!("/proc/{pid}/cmdline")) else {
            continue;
        };
        if cmd_bytes.is_empty() {
            continue;
        }
        // First null-terminated string
        let end = cmd_bytes.iter().position(|&b| b == 0).unwrap_or(cmd_bytes.len());
        let raw_pkg = String::from_utf8_lossy(&cmd_bytes[..end]).trim().to_string();
        if raw_pkg.is_empty() || raw_pkg.starts_with('/') {
            continue;
        }

        // "com.mobile.legends:UnityKillsMe" -> "com.mobile.legends"
        let base_pkg = raw_pkg.split(':').next().unwrap_or(&raw_pkg).trim();

        // Android apps must have a dot '.' and not be a CLI tool like 'ping' or 'sh'
        if base_pkg.contains('.') && base_pkg.len() >= 4 {
            if cfg.games.contains(base_pkg) {
                return Some((base_pkg.to_string(), true));
            }
            if candidate_app.is_none() && !IGNORED_PACKAGES.iter().any(|&ig| base_pkg.starts_with(ig)) {
                candidate_app = Some(base_pkg.to_string());
            }
        }
    }

    candidate_app.map(|app| {
        let is_game = cfg.games.contains(&app);
        (app, is_game)
    })
}

// Strategy 2: dumpsys window (mahal: fork + output besar)
fn get_foreground_app_dumpsys(cfg: &DaemonConfig) -> Option<(String, bool)> {
    // dumpsys ikut macet kalau system_server macet; jangan biarkan itu menahan main loop.
    let output = Command::new("timeout")
        .args(["3", "dumpsys", "window", "displays"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);

    for line in text.lines() {
        if line.contains("mCurrentFocus") || line.contains("mFocusedApp") {
            // mCurrentFocus=Window{... u0 com.mobile.legends/com.xxx.MainActivity}
            if let Some(start) = line.find(" u0 ") {
                let sub = &line[start + 4..];
                let pkg_part = sub.split(&['/', ' ', '}', ':'][..]).next().unwrap_or("");
                let clean = pkg_part.trim();
                if clean.contains('.') && clean.len() >= 4 && !IGNORED_PACKAGES.iter().any(|&ig| clean == ig) {
                    return Some((clean.to_string(), cfg.games.contains(clean)));
                }
            }
        }
    }
    None
}

/// cgroup dulu (gratis). `dumpsys` HANYA kalau cgroup kosong, dan dibatasi frekuensinya.
#[derive(Default)]
struct Detector {
    last_dumpsys: Option<Instant>,
    cached: Option<String>,
}

impl Detector {
    fn detect(&mut self, cfg: &DaemonConfig) -> (String, bool) {
        if let Some(r) = get_foreground_app_cgroup(cfg) {
            return r;
        }
        let due = self.last_dumpsys.map_or(true, |t| t.elapsed() >= DUMPSYS_MIN_INTERVAL);
        if due {
            self.last_dumpsys = Some(Instant::now());
            self.cached = get_foreground_app_dumpsys(cfg).map(|(p, _)| p);
        }
        match &self.cached {
            Some(pkg) => (pkg.clone(), cfg.games.contains(pkg)),
            None => ("unknown".to_string(), false),
        }
    }
}

// ---------------------------------------------------------------------------
// Game-mode state + restore
// ---------------------------------------------------------------------------

/// Debounce boolean: nilai baru baru dipakai setelah `needed` sampel berturut-turut.
#[derive(Clone, Copy, Debug, Default)]
struct Debounce {
    stable: bool,
    streak: u32,
}

impl Debounce {
    fn new(v: bool) -> Self {
        Self { stable: v, streak: 0 }
    }

    fn feed(&mut self, sample: bool, needed: u32) -> bool {
        if sample == self.stable {
            self.streak = 0;
        } else {
            self.streak += 1;
            if self.streak >= needed {
                self.stable = sample;
                self.streak = 0;
            }
        }
        self.stable
    }
}

/// Apa saja yang diubah daemon, supaya bisa dikembalikan persis seperti semula.
/// Empat field pertama disimpan ke ENGAGED_FILE untuk recovery setelah crash/SIGKILL.
#[derive(Clone, Debug, Default)]
struct Engaged {
    prev_profile: Option<u32>,
    mglru_touched: bool,
    prev_mglru: Option<u32>,
    bypass_owned: bool,
    // runtime-only
    last_mglru: Option<u32>,
    plug: Debounce,
    last_plug_change: Option<Instant>,
}

fn fmt_opt(v: Option<u32>) -> String {
    v.map(|n| n.to_string()).unwrap_or_default()
}

fn save_marker(st: &Engaged) {
    let content = format!(
        "PREV_PROFILE={}\nMGLRU_TOUCHED={}\nPREV_MGLRU={}\nBYPASS_OWNED={}\n",
        fmt_opt(st.prev_profile),
        u8::from(st.mglru_touched),
        fmt_opt(st.prev_mglru),
        u8::from(st.bypass_owned),
    );
    let _ = fs::write(ENGAGED_FILE, content);
}

fn load_marker() -> Option<Engaged> {
    let text = fs::read_to_string(ENGAGED_FILE).ok()?;
    let mut st = Engaged::default();
    for line in text.lines() {
        if let Some((k, v)) = line.split_once('=') {
            let v = v.trim();
            match k.trim() {
                "PREV_PROFILE" => st.prev_profile = v.parse().ok(),
                "MGLRU_TOUCHED" => st.mglru_touched = v == "1",
                "PREV_MGLRU" => st.prev_mglru = v.parse().ok(),
                "BYPASS_OWNED" => st.bypass_owned = v == "1",
                _ => {}
            }
        }
    }
    Some(st)
}

fn clear_marker() {
    let _ = fs::remove_file(ENGAGED_FILE);
}

/// Kembalikan semua yang kita ubah. Mengembalikan profile yang aktif sesudahnya.
fn restore(st: &Engaged, cfg: &DaemonConfig) -> u32 {
    let profile = st.prev_profile.unwrap_or(cfg.default_profile);
    set_kernel_profile(profile);
    if st.bypass_owned {
        set_bypass_charging(false);
    }
    if st.mglru_touched {
        set_mglru(st.prev_mglru.unwrap_or(cfg.default_mglru));
    }
    clear_marker();
    profile
}

/// Hidupkan bypass hanya kalau memang belum menyala (jangan ambil alih pilihan user).
fn claim_bypass(st: &mut Engaged) {
    if st.bypass_owned || read_u32_node(&BYPASS_NODES) == Some(1) {
        return;
    }
    // Tandai kepemilikan dulu; kalau crash di tengah, recovery tetap melepasnya.
    st.bypass_owned = true;
    save_marker(st);
    set_bypass_charging(true);
    println!("[Ki-Daemon] Charger connected -> Auto Bypass Charging engaged!");
}

fn release_bypass(st: &mut Engaged) {
    if st.bypass_owned {
        set_bypass_charging(false);
        st.bypass_owned = false;
        save_marker(st);
        println!("[Ki-Daemon] Bypass Charging disarmed.");
    }
}

fn begin_game(cfg: &DaemonConfig) -> Engaged {
    let mut st = Engaged {
        prev_profile: read_u32_node(&PROFILE_NODES),
        ..Default::default()
    };
    if cfg.auto_mglru {
        st.mglru_touched = true;
        st.prev_mglru = read_u32_node(&MGLRU_NODES);
    }
    // Simpan state asli SEBELUM menyentuh kernel.
    save_marker(&st);

    set_kernel_profile(cfg.game_profile);
    if cfg.auto_mglru {
        set_mglru(cfg.game_mglru);
        st.last_mglru = Some(cfg.game_mglru);
        println!("[Ki-Daemon] Auto MGLRU set to Gaming Turbo ({})", cfg.game_mglru);
    }

    let cur_bypass = read_u32_node(&BYPASS_NODES) == Some(1);
    st.plug = Debounce::new(is_charger_connected(cur_bypass));
    if cfg.auto_bypass_charging && st.plug.stable {
        claim_bypass(&mut st);
    }
    st
}

fn tick_game(st: &mut Engaged, cfg: &DaemonConfig, current_profile: &mut u32) {
    // Profile sync verification: read kernel's actual profile and fix mismatch
    let kernel_profile = read_u32_node(&PROFILE_NODES).unwrap_or(cfg.game_profile);
    if kernel_profile != cfg.game_profile {
        set_kernel_profile(cfg.game_profile);
        *current_profile = cfg.game_profile;
        println!("[Ki-Daemon] Profile sync corrected: kernel had {kernel_profile}, forced to {}", cfg.game_profile);
    } else if *current_profile != cfg.game_profile {
        *current_profile = cfg.game_profile;
    }

    // Tulis MGLRU hanya saat nilainya memang berubah.
    if cfg.auto_mglru && st.last_mglru != Some(cfg.game_mglru) {
        if !st.mglru_touched {
            st.mglru_touched = true;
            st.prev_mglru = read_u32_node(&MGLRU_NODES);
            save_marker(st);
        }
        set_mglru(cfg.game_mglru);
        st.last_mglru = Some(cfg.game_mglru);
    }

    if cfg.auto_bypass_charging {
        let is_bypass = st.bypass_owned || read_u32_node(&BYPASS_NODES) == Some(1);
        let sample = is_charger_connected(is_bypass);
        let prev_stable = st.plug.stable;
        let new_stable = st.plug.feed(sample, PLUG_DEBOUNCE_POLLS);
        if prev_stable != new_stable {
            st.last_plug_change = Some(Instant::now());
        }
        // Pastikan transien PMIC/SMB5 telah stabil selama CHARGE_SETTLE sebelum claim/release
        let settled = st.last_plug_change.map_or(true, |t| t.elapsed() >= CHARGE_SETTLE);
        if settled {
            if new_stable {
                claim_bypass(st);
            } else {
                release_bypass(st);
            }
        }
    } else {
        release_bypass(st); // dimatikan lewat config saat sedang aktif
    }
}

// ---------------------------------------------------------------------------
// Status file (hanya ditulis saat isinya berubah)
// ---------------------------------------------------------------------------

fn build_status(
    fg_pkg: &str,
    is_game: bool,
    active_profile: u32,
    bypass_active: bool,
    cfg: &DaemonConfig,
) -> String {
    format!(
        "RUNNING=1\n\
         PID={}\n\
         FOREGROUND_PKG={}\n\
         IS_GAME={}\n\
         ACTIVE_PROFILE={}\n\
         BYPASS_CHARGING={}\n\
         DAEMON_ENABLED={}\n\
         AUTO_BYPASS={}\n\
         AUTO_MGLRU={}\n\
         GAMES_COUNT={}\n",
        std::process::id(),
        fg_pkg,
        u8::from(is_game),
        active_profile,
        u8::from(bypass_active),
        u8::from(cfg.enabled),
        u8::from(cfg.auto_bypass_charging),
        u8::from(cfg.auto_mglru),
        cfg.games.len()
    )
}

#[derive(Default)]
struct StatusWriter {
    last: String,
}

impl StatusWriter {
    fn write(&mut self, content: String) {
        if content != self.last && fs::write(STATUS_FILE, &content).is_ok() {
            self.last = content;
        }
    }
}

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

fn read_pid_file() -> Option<String> {
    fs::read_to_string(PID_FILE)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
}

/// Pastikan PID memang proses ki_daemon (PID bisa dipakai ulang oleh proses lain).
fn is_ki_daemon_pid(pid: &str) -> bool {
    fs::read(format!("/proc/{pid}/cmdline"))
        .map(|b| String::from_utf8_lossy(&b).contains("ki_daemon"))
        .unwrap_or(false)
}

/// Tidur yang langsung terbangun lewat unpark() saat ada sinyal stop. Tanpa wakeup periodik.
fn nap(total: Duration, stop: &AtomicBool) {
    let end = Instant::now() + total;
    loop {
        if stop.load(Ordering::Relaxed) {
            return;
        }
        let now = Instant::now();
        if now >= end {
            return;
        }
        thread::park_timeout(end - now);
    }
}

// ---------------------------------------------------------------------------
// Daemon
// ---------------------------------------------------------------------------

fn run_daemon() {
    let me = std::process::id();
    if let Some(other) = read_pid_file() {
        if other != me.to_string() && is_ki_daemon_pid(&other) {
            eprintln!("[Ki-Daemon] Sudah berjalan (PID {other}), keluar.");
            exit(0);
        }
    }
    let _ = fs::write(PID_FILE, me.to_string());
    let _ = Command::new("chmod").args(["666", PID_FILE]).status();

    // SIGTERM/SIGINT -> set flag + bangunkan main thread.
    let stop = Arc::new(AtomicBool::new(false));
    match Signals::new([SIGTERM, SIGINT]) {
        Ok(mut signals) => {
            let stop = Arc::clone(&stop);
            let main_thread = thread::current();
            thread::spawn(move || {
                for _ in signals.forever() {
                    stop.store(true, Ordering::SeqCst);
                    main_thread.unpark();
                }
            });
        }
        Err(e) => eprintln!("[Ki-Daemon] WARN: gagal memasang signal handler: {e}"),
    }

    println!("[Ki-Daemon] Started successfully with PID: {me}");

    let mut cfg = DaemonConfig::load();

    // Recovery: daemon sebelumnya mati (crash/SIGKILL) saat game mode aktif.
    if let Some(stale) = load_marker() {
        let p = restore(&stale, &cfg);
        println!("[Ki-Daemon] Recovered state from previous run (profile -> {p}).");
    }

    let mut last_cfg_check = Instant::now();
    let mut engaged: Option<Engaged> = None;
    let mut current_profile = read_u32_node(&PROFILE_NODES).unwrap_or(cfg.default_profile);
    let mut detector = Detector::default();
    let mut status = StatusWriter::default();
    let mut exit_misses = 0u32;
    let mut screen_off_since: Option<Instant> = None;
    let mut last_game_pkg = String::new();

    // Tulis status inisial seawal mungkin agar WebUI langsung mendeteksi daemon berjalan
    let cur_bypass = read_u32_node(&BYPASS_NODES) == Some(1);
    let init_fg = if cfg.enabled { "initializing" } else { "disabled" };
    status.write(build_status(init_fg, false, current_profile, cur_bypass, &cfg));
    let _ = Command::new("chmod").args(["666", STATUS_FILE]).status();

    while !stop.load(Ordering::Relaxed) {
        // Reload config every 3 seconds
        if last_cfg_check.elapsed() >= Duration::from_secs(3) {
            cfg = DaemonConfig::load();
            last_cfg_check = Instant::now();
        }

        if !cfg.enabled {
            if let Some(st) = engaged.take() {
                current_profile = restore(&st, &cfg);
                println!("[Ki-Daemon] Disabled -> state restored.");
            }
            status.write(build_status("disabled", false, current_profile, false, &cfg));
            nap(Duration::from_secs(4), &stop);
            continue;
        }

        // Layar mati: tidur lebih lama, dan lepas Turbo/bypass setelah masa tenggang.
        if !is_screen_on() {
            let since = *screen_off_since.get_or_insert_with(Instant::now);
            if since.elapsed() >= SCREEN_OFF_GRACE {
                if let Some(st) = engaged.take() {
                    current_profile = restore(&st, &cfg);
                    println!("[Ki-Daemon] Screen off -> state restored.");
                }
            }
            let bypass = read_u32_node(&BYPASS_NODES) == Some(1);
            status.write(build_status("screen_off", engaged.is_some(), current_profile, bypass, &cfg));
            nap(Duration::from_secs(10), &stop);
            continue;
        }
        screen_off_since = None;

        let (fg_pkg, is_game) = detector.detect(&cfg);

        if is_game {
            exit_misses = 0;
            last_game_pkg.clone_from(&fg_pkg);
            match engaged.as_mut() {
                None => {
                    println!("[Ki-Daemon] Game detected: {fg_pkg} -> Engaging Game Turbo!");
                    notify_game_turbo(true, &fg_pkg);
                    engaged = Some(begin_game(&cfg));
                    current_profile = cfg.game_profile;
                }
                Some(st) => tick_game(st, &cfg, &mut current_profile),
            }
        } else if engaged.is_some() {
            // Debounce: satu poll "bukan game" bisa saja glitch pembacaan cgroup.
            exit_misses += 1;
            if exit_misses >= EXIT_DEBOUNCE_POLLS {
                if let Some(st) = engaged.take() {
                    current_profile = restore(&st, &cfg);
                    println!("[Ki-Daemon] Game exited: {last_game_pkg} -> Restored (profile {current_profile})");
                    notify_game_turbo(false, &last_game_pkg);
                }
                exit_misses = 0;
            } else if let Some(st) = engaged.as_mut() {
                tick_game(st, &cfg, &mut current_profile);
            }
        }

        let bypass = read_u32_node(&BYPASS_NODES) == Some(1);
        status.write(build_status(&fg_pkg, engaged.is_some(), current_profile, bypass, &cfg));

        // Saat main game: pakai poll_interval_ms (1.5s) agar reaksi cepat.
        // Saat buka sosmed/idle: perlambat ke 3s untuk menghemat baterai secara drastis.
        let sleep_ms = if engaged.is_some() {
            cfg.poll_interval_ms
        } else {
            (cfg.poll_interval_ms * 2).max(3000)
        };
        nap(Duration::from_millis(sleep_ms), &stop);
    }

    println!("[Ki-Daemon] Stop signal received, cleaning up...");
    if let Some(st) = engaged.take() {
        restore(&st, &cfg);
    }
    let _ = fs::remove_file(PID_FILE);
    let _ = fs::remove_file(STATUS_FILE);
    println!("[Ki-Daemon] Bye.");
}

// ---------------------------------------------------------------------------
// CLI commands
// ---------------------------------------------------------------------------

fn print_status() {
    let is_running = read_pid_file().map_or(false, |pid| is_ki_daemon_pid(&pid));

    if !is_running {
        println!("{{\"running\": false}}");
        return;
    }

    if let Ok(content) = fs::read_to_string(STATUS_FILE) {
        let mut map = std::collections::HashMap::new();
        for line in content.lines() {
            if let Some((k, v)) = line.split_once('=') {
                map.insert(k.trim(), v.trim());
            }
        }

        let cfg = DaemonConfig::load();
        let mut games_vec: Vec<_> = cfg.games.iter().cloned().collect();
        games_vec.sort();

        println!("{{");
        println!("  \"running\": true,");
        println!("  \"pid\": {},", map.get("PID").unwrap_or(&"0"));
        println!("  \"foreground_pkg\": {:?},", map.get("FOREGROUND_PKG").unwrap_or(&"unknown"));
        println!("  \"is_game\": {},", map.get("IS_GAME").unwrap_or(&"0") == &"1");
        println!("  \"active_profile\": {},", map.get("ACTIVE_PROFILE").unwrap_or(&"1"));
        println!("  \"bypass_charging\": {},", map.get("BYPASS_CHARGING").unwrap_or(&"0") == &"1");
        println!("  \"daemon_enabled\": {},", cfg.enabled);
        println!("  \"default_profile\": {},", cfg.default_profile);
        println!("  \"game_profile\": {},", cfg.game_profile);
        println!("  \"auto_bypass\": {},", cfg.auto_bypass_charging);
        println!("  \"auto_mglru\": {},", cfg.auto_mglru);
        println!("  \"games\": {:?}", games_vec);
        println!("}}");
    } else {
        let cfg = DaemonConfig::load();
        let mut games_vec: Vec<_> = cfg.games.iter().cloned().collect();
        games_vec.sort();
        println!("{{\"running\": true, \"status\": \"initializing\", \"daemon_enabled\": {}, \"games\": {:?}}}", cfg.enabled, games_vec);
    }
}

fn start_daemon() {
    let me = std::process::id();
    if let Some(pid) = read_pid_file() {
        if pid != me.to_string() && is_ki_daemon_pid(&pid) {
            println!("Ki-Daemon already running (PID {pid}).");
            return;
        }
    }

    let _ = fs::remove_file(PID_FILE);
    let _ = fs::remove_file(STATUS_FILE);

    let exe_path = std::env::current_exe()
        .unwrap_or_else(|_| std::path::PathBuf::from("/data/adb/modules/ki_optimizer/bin/ki_daemon"));

    match Command::new(exe_path)
        .arg("run")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        Ok(child) => {
            let pid = child.id();
            println!("Ki-Daemon started in background (PID {pid}).");
            sleep(Duration::from_millis(50));
        }
        Err(e) => {
            eprintln!("Failed to spawn Ki-Daemon in background: {e}");
            exit(1);
        }
    }
}

fn stop_daemon() {
    let cfg = DaemonConfig::load();

    match read_pid_file() {
        Some(pid) if pid != std::process::id().to_string() && is_ki_daemon_pid(&pid) => {
            let _ = Command::new("kill").args(["-TERM", &pid]).status();
            let proc_dir = format!("/proc/{pid}");
            let deadline = Instant::now() + Duration::from_secs(3);
            while Path::new(&proc_dir).exists() && Instant::now() < deadline {
                sleep(Duration::from_millis(100));
            }
            if Path::new(&proc_dir).exists() {
                let _ = Command::new("kill").args(["-KILL", &pid]).status();
                sleep(Duration::from_millis(100));
            }
            println!("Ki-Daemon stopped.");
        }
        Some(_) => println!("Stale PID file (process is not ki_daemon)."),
        None => {
            // Jangan pakai `killall ki_daemon`: itu ikut membunuh proses `stop` ini sendiri.
            let _ = Command::new("pkill").args(["-f", "ki_daemon run"]).status();
            println!("Ki-Daemon stop signal sent.");
        }
    }

    // Kalau daemon mati paksa, marker masih ada -> kembalikan state dari sini.
    if let Some(st) = load_marker() {
        let p = restore(&st, &cfg);
        println!("Restored kernel state (profile -> {p}).");
    }

    let _ = fs::remove_file(PID_FILE);
    let _ = fs::remove_file(STATUS_FILE);
}

fn add_game(pkg: &str) {
    let mut cfg = DaemonConfig::load();
    if is_valid_package(pkg.trim()) {
        cfg.games.insert(pkg.trim().to_string());
        cfg.save();
        println!("Added game: {pkg}");
    } else {
        eprintln!("Invalid package name: {pkg}");
    }
}

fn remove_game(pkg: &str) {
    let mut cfg = DaemonConfig::load();
    if cfg.games.remove(pkg.trim()) {
        cfg.save();
        println!("Removed game: {pkg}");
    } else {
        println!("Game not found in list: {pkg}");
    }
}

fn set_config_value(key: &str, val: &str) {
    let mut cfg = DaemonConfig::load();
    let k = key.to_uppercase();
    if k == "GAMES" || !cfg.apply(&k, val) {
        eprintln!("Unknown or unsupported config key: {key}");
        return;
    }
    cfg.save();
    println!("Updated {key} = {val}");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        println!("Ki-Daemon v1.1 (Auto Game Turbo & Optimization)");
        println!("Usage: ki_daemon <start|run|status|stop|add-game|remove-game|set>");
        return;
    }

    match args[1].as_str() {
        "start" => start_daemon(),
        "run" => run_daemon(),
        "status" => print_status(),
        "stop" => stop_daemon(),
        "add-game" => {
            if args.len() >= 3 {
                add_game(&args[2]);
            } else {
                eprintln!("Usage: ki_daemon add-game <package_name>");
            }
        }
        "remove-game" => {
            if args.len() >= 3 {
                remove_game(&args[2]);
            } else {
                eprintln!("Usage: ki_daemon remove-game <package_name>");
            }
        }
        "set" => {
            if args.len() >= 4 {
                set_config_value(&args[2], &args[3]);
            } else {
                eprintln!("Usage: ki_daemon set <key> <val>");
            }
        }
        _ => {
            eprintln!("Unknown command: {}", args[1]);
            exit(1);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn games_config_rejects_shell_metacharacters() {
        let mut cfg = DaemonConfig::default();
        cfg.apply("GAMES", "com.valid.game,x$(id),a\"b,c`d`,e;f, ,com.other_game");
        let mut games: Vec<_> = cfg.games.iter().map(String::as_str).collect();
        games.sort();
        assert_eq!(games, ["com.other_game", "com.valid.game"]);
    }
}
