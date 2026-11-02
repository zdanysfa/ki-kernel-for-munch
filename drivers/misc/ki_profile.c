// SPDX-License-Identifier: GPL-2.0
/*
 * Ki-Kernel CPU Profile Driver for POCO F4 (munch)
 * Exposes /sys/kernel/ki_profile/mode:
 *   0: Battery Saver
 *   1: Balanced (Default)
 *   2: Performance / Turbo Gaming
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/string.h>
#include <linux/sched.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/mm.h>
#include <linux/workqueue.h>
#include <linux/thermal.h>
#include <linux/power_supply.h>
#include <linux/notifier.h>
#include <drm/drm_notifier_mi.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/cpumask.h>
#include <linux/ki_profile.h>

/* Profile chosen by the user (sysfs "mode") */
int current_profile_mode = KI_PROFILE_BALANCED;
EXPORT_SYMBOL_GPL(current_profile_mode);
static DEFINE_MUTEX(ki_profile_mutex);
static DEFINE_SPINLOCK(ki_guard_lock);

/*
 * Profile switch debounce: prevent re-application spam.
 * Tracks last applied mode and timestamp to skip redundant applies.
 */
static int ki_last_logged_mode = -1;

/* Profile actually applied right now (differs while screen is off) */
static int ki_active_mode = -1;

int ki_get_active_profile(void)
{
	int mode = READ_ONCE(ki_active_mode);
	if (mode < 0)
		return READ_ONCE(current_profile_mode);
	return mode;
}
EXPORT_SYMBOL_GPL(ki_get_active_profile);

/*
 * Screen-off Auto Battery:
 * Screen off  -> after KI_SCREEN_OFF_DELAY_MS switch to Battery profile.
 * Screen on   -> restore the user's profile immediately (via early DRM blank).
 * The delay avoids flapping from proximity-sensor blanking during calls.
 */
#define KI_SCREEN_OFF_DELAY_MS	5000
static bool ki_screen_off_battery = false;
static bool ki_screen_on = true;
static bool ki_battery_armed;
static struct delayed_work ki_screen_work;

static const char * const profile_names[] = {
	[KI_PROFILE_BATTERY] = "battery",
	[KI_PROFILE_BALANCED] = "balanced",
	[KI_PROFILE_PERFORMANCE] = "performance",
};

extern int watermark_scale_factor;
extern int sysctl_compact_unevictable_allowed;
extern int sysctl_vfs_cache_pressure;

/* Representative CPU of each cluster: Silver, Gold, Prime */
#define KI_NR_CLUSTERS	3
static const unsigned int ki_cluster_cpu[KI_NR_CLUSTERS] = { 0, 4, 7 };

struct ki_cluster_tune {
	unsigned int up_us;		/* sugov up rate limit */
	unsigned int down_us;		/* sugov down rate limit */
	unsigned int hispeed_freq;	/* kHz, 0 = disabled */
	unsigned int hispeed_load;	/* % */
	unsigned int rtg_boost_freq;	/* kHz, 0 = disabled */
	unsigned int floor_freq;	/* kHz, 0 = disabled */
	unsigned int iowait_boost_max;	/* % (0 = disabled, 100 = full) */
	unsigned int max_freq;		/* kHz, 0 = hardware max */
};

struct ki_profile_tune {
	struct ki_cluster_tune cl[KI_NR_CLUSTERS];
	bool pl;			/* WALT PL hints */
	bool gpu_perf;			/* kgsl performance mode */
	bool thermal_throttle;
	int sched_boost;
	unsigned int up_migrate, down_migrate;
	unsigned int grp_up_migrate, grp_down_migrate;
	unsigned int window_stats_policy; /* 1 = MAX, 2 = MAX_RECENT_AVG */
	int wmark_scale;
	int vfs_cache_pressure;
};

/* User max frequency overrides (0 = follow active profile default) */
static unsigned int ki_user_max_freq[KI_NR_CLUSTERS] = { 0, 0, 0 };

/*
 * User thermal throttle override:
 *  -1: Auto / follow profile default (Balanced/Battery = throttled, Performance = bypass)
 *   0: Forced bypass (Unlocked performance)
 *   1: Forced enabled (Safe active throttling)
 */
static int ki_user_thermal_throttle = -1;
static bool ki_thermal_applied = true;	/* protected by ki_profile_mutex */

static const struct ki_profile_tune ki_tunes[KI_PROFILE_MAX] = {
	/*
	 * Battery Saver (Ultra Power Saving & Cool Efficiency):
	 * Preserves maximum battery life and icy-cool chassis under all scenarios.
	 * Tasks strictly retained on power-efficient Silver cluster (up_migrate = 98/90, grp = 98/90).
	 * Frequencies strictly bounded within high-efficiency low-voltage OPP (<0.80V):
	 *   - Silver: 1.51GHz (1516800)
	 *   - Gold:   1.65GHz (1651200)
	 *   - Prime:  1.57GHz (1574400)
	 * Down-rate 500us drops CPU to 300MHz idle in half a millisecond when finger lifts.
	 * Up-rate (Silver 2ms, Gold 5ms, Prime 15ms) prevents clock thrashing while
	 * keeping Prime core practically dormant for daily tasks.
	 * RTG boost on Silver (979MHz) & Gold (1.05GHz) ensures smooth 60/120Hz UI without black screens.
	 * Zero floor frequency (floor_freq = 0) enables full idle drop to 300MHz baseline.
	 * Zero iowait boost prevents I/O reads/downloads from waking high clock states.
	 * VFS cache pressure 60 keeps dentries cached, avoiding flash I/O wakeups.
	 */
	[KI_PROFILE_BATTERY] = {
		.cl = {
			{ .up_us = 2000, .down_us = 500, .hispeed_freq = 979200,  .hispeed_load = 92, .rtg_boost_freq = 979200,  .floor_freq = 0, .iowait_boost_max = 0, .max_freq = 1516800 },
			{ .up_us = 5000, .down_us = 500, .hispeed_freq = 1056000, .hispeed_load = 92, .rtg_boost_freq = 1056000, .floor_freq = 0, .iowait_boost_max = 0, .max_freq = 1651200 },
			{ .up_us = 15000, .down_us = 500, .hispeed_freq = 1075200, .hispeed_load = 95, .rtg_boost_freq = 0,       .floor_freq = 0, .iowait_boost_max = 0, .max_freq = 1574400 },
		},
		.thermal_throttle = true,
		.up_migrate = 98, .down_migrate = 90,
		.grp_up_migrate = 98, .grp_down_migrate = 90,
		.window_stats_policy = 2,
		.wmark_scale = 100, .vfs_cache_pressure = 60,
	},
	/*
	 * Balanced (Daily Driver - v1.3 Adem Anyem & Smooth 120Hz Efficiency):
	 * Restored v1.3 thermal comfort and battery efficiency with butter-smooth 120Hz UI.
	 * Tasks balanced on Silver cluster (up_migrate = 90/82, grp = 90/82) so casual
	 * multitasking (WhatsApp, YouTube, TikTok, Maps) stays on cool LITTLE cores,
	 * while smoothly migrating rendering threads to Big cores on heavy demand.
	 * Down-rate hold 5000us (5ms) holds clocks across consecutive frames (60Hz/90Hz/120Hz),
	 * completely eliminating mid-frame frequency dips, stutter, and dropped frames,
	 * while still enabling fast idle drop to 300MHz baseline when touch stops.
	 * Up-rate (Silver 850us, Gold 2850us, Prime 3850us) ensures smooth, rapid ramp-up.
	 * Hispeed load thresholds (Silver 82%, Gold 82%, Prime 84%) trigger power bursts when needed.
	 * Valid SM8250 OPP frequencies:
	 *   - Silver: hispeed 1.17GHz, rtg_boost 1.17GHz, floor 0, max 1.80GHz (1804800)
	 *   - Gold:   hispeed 1.47GHz, rtg_boost 1.47GHz, floor 0, max 2.05GHz (2054400)
	 *   - Prime:  hispeed 1.61GHz, rtg_boost 1.61GHz, floor 0, max 2.36GHz (2361600)
	 * Zero floor frequency (floor_freq = 0) enables full idle drop down to 300MHz baseline.
	 * Moderate I/O wait boost (iowait_boost_max = 5) prevents app launch and storage lag.
	 * Capping Gold to 2.05GHz and Prime to 2.36GHz chops off high-voltage thermal walls.
	 */
	[KI_PROFILE_BALANCED] = {
		.cl = {
			{ .up_us = 850,  .down_us = 5000, .hispeed_freq = 1171200, .hispeed_load = 82, .rtg_boost_freq = 1171200, .floor_freq = 0, .iowait_boost_max = 5, .max_freq = 1804800 },
			{ .up_us = 2850, .down_us = 5000, .hispeed_freq = 1478400, .hispeed_load = 82, .rtg_boost_freq = 1478400, .floor_freq = 0, .iowait_boost_max = 5, .max_freq = 2054400 },
			{ .up_us = 3850, .down_us = 5000, .hispeed_freq = 1612800, .hispeed_load = 84, .rtg_boost_freq = 1612800, .floor_freq = 0, .iowait_boost_max = 0, .max_freq = 2361600 },
		},
		.thermal_throttle = true,
		.up_migrate = 90, .down_migrate = 82,
		.grp_up_migrate = 90, .grp_down_migrate = 82,
		.window_stats_policy = 2,
		.wmark_scale = 100, .vfs_cache_pressure = 70,
	},
	/*
	 * Performance / Gaming Turbo (Zero Frame Drop & Rock-Solid FPS):
	 * Designed for competitive gaming (MLBB, Genshin, PUBG 90/120Hz, Wild Rift).
	 * Instantaneous ramp-up (up_us: 0), frame-synchronized down hold (20ms / 20000us)
	 * holds clocks across consecutive frames (60Hz=16.6ms, 90Hz=11.1ms, 120Hz=8.33ms),
	 * completely eliminating mid-frame frequency dips and micro-stutters.
	 * Aggressive floor frequencies prevent idle stalls during complex scenes:
	 *   - Silver: floor 806.4MHz, hispeed 1.42GHz (load 55%), rtg_boost 1.42GHz
	 *   - Gold:   floor 1.26GHz, hispeed 2.20GHz (load 55%), rtg_boost 2.20GHz
	 *   - Prime:  floor 1.34GHz, hispeed 2.84GHz (load 55%), rtg_boost 2.84GHz
	 * Sched boost enabled (.sched_boost = 1 / FULL_THROTTLE_BOOST): activates
	 * core_ctl un-isolation, enables WALT frequency aggregation, and forces
	 * placement policy to SCHED_BOOST_ON_BIG so render/audio threads are prioritized on Big cores.
	 * Window stats policy = 1 (WINDOW_STATS_MAX): responds immediately to peak load
	 * bursts without latency from averaging.
	 * Eager game thread promotion (up_migrate 55/40, grp 65/50) locks render pipelines to Big cores.
	 * Uncapped hardware burst maximums (Silver 1.80GHz, Gold 2.42GHz, Prime 3.19GHz).
	 * Memory tuning: watermark_scale 150 (prevents direct reclaim allocstall pauses),
	 * and vfs_cache_pressure 50 (keeps game asset textures cached in RAM).
	 * Thermal bypass active with Thermal Auto-Guard watching at 47°C skin / 45°C batt / 85°C die.
	 */
	[KI_PROFILE_PERFORMANCE] = {
		.cl = {
			{ .up_us = 0, .down_us = 20000, .hispeed_freq = 1420800, .hispeed_load = 55, .rtg_boost_freq = 1420800, .floor_freq = 806400,  .iowait_boost_max = 50, .max_freq = 0 },
			{ .up_us = 0, .down_us = 20000, .hispeed_freq = 2208000, .hispeed_load = 55, .rtg_boost_freq = 2208000, .floor_freq = 1267200, .iowait_boost_max = 50, .max_freq = 0 },
			{ .up_us = 0, .down_us = 20000, .hispeed_freq = 2841600, .hispeed_load = 55, .rtg_boost_freq = 2841600, .floor_freq = 1344000, .iowait_boost_max = 50, .max_freq = 0 },
		},
		.pl = true,
		.gpu_perf = true,
		.thermal_throttle = false,
		.sched_boost = 1,
		.up_migrate = 55, .down_migrate = 40,
		.grp_up_migrate = 65, .grp_down_migrate = 50,
		.window_stats_policy = 1,
		.wmark_scale = 150, .vfs_cache_pressure = 50,
	},
};

/*
 * Thermal Auto-Guard:
 * Active whenever thermal bypass is engaged (Performance mode default or user override)
 * while screen is on. Thermal bypass stays active for max FPS, but throttling is re-armed
 * when CPU/GPU die >= 85C, body (quiet_therm) >= 47C, or battery >= 45C.
 * Released again once die <= 75C, body <= 43C, and battery <= 41C.
 * Polls every 2s, parked while screen is off with throttling re-armed for pocket safety.
 */
#define KI_GUARD_POLL_MS	2000
#define KI_GUARD_DIE_HOT	85000 /* 85.0°C */
#define KI_GUARD_DIE_COOL	75000 /* 75.0°C */
#define KI_GUARD_SKIN_HOT	47000 /* 47.0°C - safe fail-safe for outdoor sunlight */
#define KI_GUARD_SKIN_COOL	43000 /* 43.0°C */
#define KI_GUARD_BATT_HOT	45000 /* 45.0°C */
#define KI_GUARD_BATT_COOL	41000 /* 41.0°C */

static const char * const ki_guard_die_zones[] = {
	"cpu-1-0-usr", "cpu-1-1-usr", "cpu-1-2-usr", "cpu-1-3-usr",
	"cpu-1-4-usr", "cpu-1-5-usr", "cpu-1-6-usr", "cpu-1-7-usr",
	"gpuss-0-usr", "gpuss-1-usr",
};

static struct thermal_zone_device *ki_guard_die_tz[ARRAY_SIZE(ki_guard_die_zones)];
static struct thermal_zone_device *ki_guard_skin_tz;
static bool ki_guard_resolved;
static bool ki_guard_tripped;
static bool ki_guard_parked;
static struct delayed_work ki_guard_work;

bool ki_thermal_throttle_enabled = true;
EXPORT_SYMBOL_GPL(ki_thermal_throttle_enabled);

static void ki_guard_resolve_zones(void)
{
	struct thermal_zone_device *tz;
	int i, valid_count = 0;
	const int total_zones = ARRAY_SIZE(ki_guard_die_zones) + 1;

	for (i = 0; i < ARRAY_SIZE(ki_guard_die_zones); i++) {
		if (!ki_guard_die_tz[i]) {
			tz = thermal_zone_get_zone_by_name(ki_guard_die_zones[i]);
			ki_guard_die_tz[i] = IS_ERR(tz) ? NULL : tz;
		}
		if (ki_guard_die_tz[i])
			valid_count++;
	}

	if (!ki_guard_skin_tz) {
		tz = thermal_zone_get_zone_by_name("quiet_therm");
		ki_guard_skin_tz = IS_ERR(tz) ? NULL : tz;
	}
	if (ki_guard_skin_tz)
		valid_count++;

	/* Only mark resolved if all expected thermal zones are found */
	if (valid_count == total_zones)
		ki_guard_resolved = true;
}

static int ki_guard_read(struct thermal_zone_device *tz)
{
	int temp;

	if (!tz || thermal_zone_get_temp(tz, &temp))
		return INT_MIN;
	return temp;
}

static int ki_guard_read_batt(void)
{
	struct power_supply *psy = power_supply_get_by_name("battery");
	union power_supply_propval val;
	int ret;

	if (!psy)
		return INT_MIN;
	ret = power_supply_get_property(psy, POWER_SUPPLY_PROP_TEMP, &val);
	power_supply_put(psy);
	if (ret)
		return INT_MIN;
	return val.intval * 100; /* convert tenths of °C to millidegrees C */
}

static unsigned int ki_guard_unresolved_polls;

static void ki_guard_log_missing_zones(void)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(ki_guard_die_zones); i++) {
		if (!ki_guard_die_tz[i])
			pr_warn("ki_profile: missing thermal die zone '%s'\n",
				ki_guard_die_zones[i]);
	}
	if (!ki_guard_skin_tz)
		pr_warn("ki_profile: missing thermal skin zone 'quiet_therm'\n");
}

/* Caller holds ki_guard_lock; returns true if thermal bypass is active */
static bool ki_guard_bypass_active_locked(void)
{
	int user_throt = READ_ONCE(ki_user_thermal_throttle);
	int mode = READ_ONCE(ki_active_mode);

	if (user_throt == 0)
		return true;
	if (user_throt == 1)
		return false;

	if (mode < 0 || mode >= KI_PROFILE_MAX)
		mode = KI_PROFILE_BALANCED;

	return !ki_tunes[mode].thermal_throttle;
}

/* Caller holds ki_guard_lock; returns true if worker must stop */
static bool ki_guard_should_stop_locked(void)
{
	if (!ki_guard_bypass_active_locked()) {
		ki_guard_tripped = false;
		return true;
	}
	if (!READ_ONCE(ki_screen_on)) {
		ki_guard_tripped = false;
		ki_guard_parked = true;
		WRITE_ONCE(ki_thermal_throttle_enabled, true);
		return true;
	}
	return false;
}

static void ki_guard_work_fn(struct work_struct *work)
{
	int i, die = INT_MIN, skin, batt;
	unsigned long flags;
	bool hot_condition = false;
	bool cool_condition = false;
	bool die_ok, skin_ok, batt_ok;
	bool stop;
	bool rearmed = false;

	spin_lock_irqsave(&ki_guard_lock, flags);
	stop = ki_guard_should_stop_locked();
	spin_unlock_irqrestore(&ki_guard_lock, flags);
	if (stop)
		return;

	if (!ki_guard_resolved) {
		ki_guard_resolve_zones();
		if (!ki_guard_resolved && ++ki_guard_unresolved_polls == 5) {
			pr_warn("ki_profile: thermal guard zones partially unresolved, running with degraded coverage\n");
			ki_guard_log_missing_zones();
		}
	} else {
		ki_guard_unresolved_polls = 0;
	}

	for (i = 0; i < ARRAY_SIZE(ki_guard_die_tz); i++)
		die = max(die, ki_guard_read(ki_guard_die_tz[i]));
	skin = ki_guard_read(ki_guard_skin_tz);
	batt = ki_guard_read_batt();

	/*
	 * Hot / Trip condition:
	 * Fail-safe: If sensors are completely blind (die == INT_MIN), assume HOT
	 * so thermal bypass is NEVER left unmonitored.
	 * Otherwise trip if ANY valid sensor crosses HOT threshold.
	 */
	if (die == INT_MIN ||
	    die >= KI_GUARD_DIE_HOT ||
	    (skin != INT_MIN && skin >= KI_GUARD_SKIN_HOT) ||
	    (batt != INT_MIN && batt >= KI_GUARD_BATT_HOT))
		hot_condition = true;

	/*
	 * Cool / Recovery condition (Fail-safe):
	 * Must have valid die readings and all available sensors <= COOL.
	 * If sensor readings are missing/INT_MIN, cool_condition is FALSE.
	 */
	die_ok = (die != INT_MIN) && (die <= KI_GUARD_DIE_COOL);
	skin_ok = (skin == INT_MIN) || (skin <= KI_GUARD_SKIN_COOL);
	batt_ok = (batt == INT_MIN) || (batt <= KI_GUARD_BATT_COOL);
	if (die_ok && skin_ok && batt_ok)
		cool_condition = true;

	spin_lock_irqsave(&ki_guard_lock, flags);
	/* Re-check active mode and screen state under spinlock to eliminate races with apply_ki_profile */
	if (ki_guard_should_stop_locked()) {
		spin_unlock_irqrestore(&ki_guard_lock, flags);
		return;
	}

	if (!ki_guard_tripped && hot_condition) {
		ki_guard_tripped = true;
		rearmed = true;
		WRITE_ONCE(ki_thermal_throttle_enabled, true);
		pr_info("ki_profile: guard tripped (die=%d skin=%d batt=%d), throttle re-armed\n",
			die, skin, batt);
	} else if (ki_guard_tripped && cool_condition) {
		ki_guard_tripped = false;
		WRITE_ONCE(ki_thermal_throttle_enabled, false);
		pr_info("ki_profile: guard cooled (die=%d skin=%d batt=%d), throttle released\n",
			die, skin, batt);
	}
	spin_unlock_irqrestore(&ki_guard_lock, flags);

	/* Flipping the flag alone clamps nothing: zones here have no polling */
	if (rearmed)
		thermal_cdev_replay_bypassed();

	queue_delayed_work(system_highpri_wq, &ki_guard_work,
			   msecs_to_jiffies(KI_GUARD_POLL_MS));
}



static bool ki_gpu_perf_applied;	/* protected by ki_profile_mutex */

static unsigned int ki_target_max(int i, int mode)
{
	unsigned int cap;
	unsigned int user;
	bool transient;

	if (mode < 0 || mode >= KI_PROFILE_MAX)
		mode = KI_PROFILE_BALANCED;

	cap = ki_tunes[mode].cl[i].max_freq;
	user = READ_ONCE(ki_user_max_freq[i]);
	transient = (mode != READ_ONCE(current_profile_mode));

	/* Override cannot relax temporary profile caps (e.g. screen-off Battery Saver) */
	if (user && (!transient || !cap || user < cap))
		return user;
	return cap;
}

static int apply_ki_profile(int mode, bool force)
{
	const struct ki_profile_tune *t;
	int i, ret, err = 0, user_throt;
	unsigned long flags;
	bool screen_on;
	bool enable_gpu_perf;
	bool enable_thermal_throttle;

	/*
	 * Prevent profile switching only if cluster policy leader CPUs (0, 4, 7) are offline.
	 * Do not lock up profile switching if secondary cores (e.g. CPU 1-3, 5-6) are offlined by power savers.
	 */
	if (!cpu_online(0) || !cpu_online(4) || !cpu_online(7)) {
		pr_debug("ki_profile: cluster policy leaders offline, profile switch deferred\n");
		return -EBUSY;
	}

	if (mode < 0 || mode >= KI_PROFILE_MAX)
		mode = KI_PROFILE_BALANCED;
	t = &ki_tunes[mode];

	for (i = 0; i < KI_NR_CLUSTERS; i++) {
		const struct ki_cluster_tune *c = &t->cl[i];
		unsigned int cpu = ki_cluster_cpu[i];
		unsigned int target_max;

		ret = sugov_set_cluster_rate_limits(cpu, c->up_us, c->down_us);
		if (ret) {
			pr_warn("ki_profile: cpu%u sugov not ready (%d), cpufreq limits skipped\n",
				cpu, ret);
			err |= BIT(i);
			continue;
		}
		sugov_set_cluster_rtg_boost(cpu, c->rtg_boost_freq);
		sugov_set_cluster_hispeed(cpu, c->hispeed_freq, c->hispeed_load);
		sugov_set_cluster_floor(cpu, c->floor_freq);
		sugov_set_cluster_iowait_boost(cpu, c->iowait_boost_max);
		sugov_set_cluster_pl(cpu, t->pl);

		target_max = ki_target_max(i, mode);
		ret = ki_cpufreq_set_limits(cpu, 0, target_max);
		if (ret) {
			pr_debug("ki_profile: cpu%u limits not applied (%d)\n", cpu, ret);
			err |= BIT(i);
		}
	}

	screen_on = READ_ONCE(ki_screen_on);
	enable_gpu_perf = t->gpu_perf && screen_on;
	if (enable_gpu_perf != ki_gpu_perf_applied || force) {
		kgsl_set_performance_mode(enable_gpu_perf);
		ki_gpu_perf_applied = enable_gpu_perf;
	}
	sched_set_updown_migrate(t->up_migrate, t->down_migrate);
	sched_set_group_updown_migrate(t->grp_up_migrate, t->grp_down_migrate);
	sched_set_boost(t->sched_boost);

	sysctl_sched_window_stats_policy = t->window_stats_policy;

	/*
	 * Determine effective thermal throttling:
	 * If user explicitly set override:
	 *   0 (bypass): Active while screen is on. Re-arm throttling when screen is off
	 *               to prevent overheating in pockets and avoid running guard polls in idle.
	 *   1 (forced): Always active.
	 * If auto (-1):
	 *   Follow profile tune (Performance = bypass with screen on, others = active).
	 */
	user_throt = READ_ONCE(ki_user_thermal_throttle);
	if (user_throt == 0)
		enable_thermal_throttle = !screen_on;
	else if (user_throt == 1)
		enable_thermal_throttle = true;
	else
		enable_thermal_throttle = t->thermal_throttle || !screen_on;

	/* Atomic thermal & active mode state switch under spinlock */
	spin_lock_irqsave(&ki_guard_lock, flags);
	WRITE_ONCE(ki_active_mode, mode);
	WRITE_ONCE(ki_thermal_throttle_enabled, enable_thermal_throttle);
	ki_guard_tripped = false;
	ki_guard_parked = false;
	spin_unlock_irqrestore(&ki_guard_lock, flags);

	ki_thermal_applied = enable_thermal_throttle;

	/* Thermal auto-guard runs only while screen is on and thermal bypass is active */
	if (!enable_thermal_throttle) {
		mod_delayed_work(system_highpri_wq, &ki_guard_work, 0);
	} else {
		cancel_delayed_work(&ki_guard_work);
		thermal_cdev_replay_bypassed();
	}

	/*
	 * Update VM watermarks & idle floors only on explicit force switch (boot or user sysfs),
	 * never during rapid screen on/off to prevent zone lock contention & SoD.
	 * Always bound to user's permanent profile selection, never transient screen-off mode.
	 */
	if (force) {
		int user_mode = READ_ONCE(current_profile_mode);
		const struct ki_profile_tune *ut;

		if (user_mode < 0 || user_mode >= KI_PROFILE_MAX)
			user_mode = KI_PROFILE_BALANCED;
		ut = &ki_tunes[user_mode];

		if (ki_cpufreq_reset_idle_floors(user_mode))
			err |= BIT(0);
		/* Swappiness left at default as requested: do not override vm_swappiness */
		watermark_scale_factor = ut->wmark_scale;
		watermark_boost_factor = 0;
		sysctl_compact_unevictable_allowed = 0;
		sysctl_vfs_cache_pressure = ut->vfs_cache_pressure;
		setup_per_zone_wmarks();
	}

	/* Only log actual profile transitions to avoid dmesg spam */
	if (mode != ki_last_logged_mode) {
		pr_info("ki_profile: %s profile active\n", profile_names[mode]);
		ki_last_logged_mode = mode;
	}
	return err;
}

/* Profile that should be applied given user choice, screen state, and power supply */
static int ki_effective_mode(void)
{
	int user_mode = READ_ONCE(current_profile_mode);

	if (user_mode < 0 || user_mode >= KI_PROFILE_MAX)
		user_mode = KI_PROFILE_BALANCED;

	/*
	 * If connected to external power / charging, do NOT throttle to Battery Saver
	 * when screen is off. Android runs background maintenance (dexopt, fstrim) while
	 * charging and needs normal CPU capacity.
	 */
	if (power_supply_is_system_supplied() > 0)
		return user_mode;

	if (READ_ONCE(ki_screen_off_battery) && !READ_ONCE(ki_screen_on) && READ_ONCE(ki_battery_armed))
		return KI_PROFILE_BATTERY;

	return user_mode;
}

static bool ki_force_pending;	/* protected by ki_profile_mutex */
static bool ki_apply_incomplete;	/* protected by ki_profile_mutex */

/*
 * A cluster can fail to apply when its policy rwsem is busy (cpu-boost, thermal).
 * Retry a bounded number of times so a governor that never comes up cannot
 * turn into a permanent wakeup source.
 */
#define KI_LIMITS_RETRY_MS	500
#define KI_LIMITS_MAX_RETRY	10
static unsigned int ki_limits_retry;

/* Caller must hold ki_profile_mutex */
static int ki_apply_effective(bool force)
{
	int mode = ki_effective_mode();
	int ret, user_throt;
	bool screen_on = READ_ONCE(ki_screen_on);
	bool expected_throttle;

	user_throt = READ_ONCE(ki_user_thermal_throttle);
	if (user_throt == 0)
		expected_throttle = !screen_on;
	else if (user_throt == 1)
		expected_throttle = true;
	else
		expected_throttle = ki_tunes[mode].thermal_throttle || !screen_on;

	force |= ki_force_pending;
	if (!force && !ki_apply_incomplete && mode == READ_ONCE(ki_active_mode) &&
	    (ki_tunes[mode].gpu_perf && screen_on) == ki_gpu_perf_applied &&
	    expected_throttle == ki_thermal_applied &&
	    !READ_ONCE(ki_guard_parked))
		return 0;

	ret = apply_ki_profile(mode, force);
	ki_force_pending = force && ret;
	ki_apply_incomplete = (ret != 0);
	if (!ret) {
		WRITE_ONCE(ki_limits_retry, 0);
	} else if (ret > 0 && READ_ONCE(ki_limits_retry) < KI_LIMITS_MAX_RETRY) {
		WRITE_ONCE(ki_limits_retry, READ_ONCE(ki_limits_retry) + 1);
		/* queue, not mod: do not pull forward 5-second screen-off timer */
		queue_delayed_work(system_power_efficient_wq, &ki_screen_work,
				   msecs_to_jiffies(KI_LIMITS_RETRY_MS));
	}
	return ret;
}

static unsigned int ki_screen_retry;	/* touched by ki_screen_work_fn and reset on unblank */

static void ki_screen_requeue(void)
{
	/* Screen on: quickly retry on highpri_wq so UI/display commit is snappily restored */
	if (READ_ONCE(ki_screen_on)) {
		if (ki_screen_retry++ < 20)
			queue_delayed_work(system_highpri_wq, &ki_screen_work,
					   msecs_to_jiffies(50));
	} else {
		/* Screen off: do NOT spam highpri_wq or wake sleeping secondary CPUs.
		 * If leaders are offline, the SoC is in deep sleep; relax or defer to next wakeup. */
		ki_screen_retry = 0;
	}
}

static void ki_screen_work_fn(struct work_struct *work)
{
	int ret;

	/*
	 * If cluster policy leaders (0, 4, 7) are still coming online during resume,
	 * re-queue ourselves so we do NOT drop the profile switch or leave the system
	 * trapped in Battery profile.
	 */
	if (!cpu_online(0) || !cpu_online(4) || !cpu_online(7)) {
		ki_screen_requeue();
		return;
	}

	if (!READ_ONCE(ki_screen_on))
		WRITE_ONCE(ki_battery_armed, true);

	mutex_lock(&ki_profile_mutex);
	ret = ki_apply_effective(false);
	mutex_unlock(&ki_profile_mutex);

	if (ret == -EBUSY) {
		ki_screen_requeue();
	} else {
		ki_screen_retry = 0;
	}
}

static int ki_display_notifier_cb(struct notifier_block *nb,
				  unsigned long val, void *data)
{
	struct mi_drm_notifier *evdata = data;
	int blank;

	if (!evdata || !evdata->data || evdata->id != MSM_DRM_PRIMARY_DISPLAY)
		return NOTIFY_OK;

	blank = *(int *)evdata->data;

	/* Early / pre unblank: restore profile before panel completes powering on */
	if ((val == MI_DRM_EARLY_EVENT_BLANK || val == MI_DRM_PRE_EVENT_BLANK) &&
	    blank == MI_DRM_BLANK_UNBLANK) {
		if (!READ_ONCE(ki_screen_on)) {
			WRITE_ONCE(ki_screen_on, true);
			WRITE_ONCE(ki_battery_armed, false);
			WRITE_ONCE(ki_screen_retry, 0);
			WRITE_ONCE(ki_limits_retry, 0);
			mod_delayed_work(system_highpri_wq, &ki_screen_work, 0);
		}
		return NOTIFY_OK;
	}

	if (val != MI_DRM_EVENT_BLANK)
		return NOTIFY_OK;

	switch (blank) {
	case MI_DRM_BLANK_UNBLANK:
		if (!READ_ONCE(ki_screen_on)) {
			WRITE_ONCE(ki_screen_on, true);
			WRITE_ONCE(ki_battery_armed, false);
			WRITE_ONCE(ki_screen_retry, 0);
			WRITE_ONCE(ki_limits_retry, 0);
			mod_delayed_work(system_highpri_wq, &ki_screen_work, 0);
		}
		break;
	case MI_DRM_BLANK_LP1:       /* Doze (AOD) */
	case MI_DRM_BLANK_LP2:       /* DozeSuspend */
	case MI_DRM_BLANK_STANDBY:
	case MI_DRM_BLANK_SUSPEND:
	case MI_DRM_BLANK_POWERDOWN:
		if (READ_ONCE(ki_screen_on)) {
			WRITE_ONCE(ki_battery_armed, false);
			WRITE_ONCE(ki_screen_on, false);
			WRITE_ONCE(ki_limits_retry, 0);
			mod_delayed_work(system_power_efficient_wq, &ki_screen_work,
					 msecs_to_jiffies(KI_SCREEN_OFF_DELAY_MS));
		}
		break;
	default:
		break;
	}

	return NOTIFY_OK;
}

static struct notifier_block ki_display_nb = {
	.notifier_call = ki_display_notifier_cb,
};

static struct delayed_work ki_psy_work;

/*
 * Charging transient suppression:
 * When charger is plugged/unplugged, the SMB5 driver fires a burst of IRQs
 * (usbin-uv, chg-state-change) over 1-3 seconds. During this transient,
 * thermals spike briefly and profile re-evaluation can cause severe lag.
 * We defer re-evaluation by 2 seconds after the last PSY event to let
 * the power path stabilize.
 */
#define KI_PSY_SETTLE_MS	2000

static void ki_psy_work_fn(struct work_struct *work)
{
	static int last_supplied = -1;
	int supplied = power_supply_is_system_supplied() > 0;
	int ret;

	if (supplied == last_supplied)
		return;

	if (READ_ONCE(ki_screen_on)) {
		last_supplied = supplied;
		return;
	}

	mutex_lock(&ki_profile_mutex);
	ret = ki_apply_effective(false);
	mutex_unlock(&ki_profile_mutex);

	if (ret != -EBUSY)
		last_supplied = supplied;
}

static int ki_psy_notifier_cb(struct notifier_block *nb,
			      unsigned long event, void *data)
{
	struct power_supply *psy = data;

	if (event != PSY_EVENT_PROP_CHANGED || !psy || !psy->desc || !psy->desc->name)
		return NOTIFY_OK;

	/*
	 * Only handle USB charger plug/unplug, ignore periodic battery gauge ADC events.
	 * Defer evaluation by KI_PSY_SETTLE_MS to let SMB5 IRQ storm and thermal
	 * transients stabilize before any profile re-evaluation.
	 * mod_delayed_work resets the timer on each new event, so the actual
	 * evaluation only fires KI_PSY_SETTLE_MS after the LAST event in the burst.
	 */
	if (strcmp(psy->desc->name, "usb") == 0)
		mod_delayed_work(system_power_efficient_wq, &ki_psy_work,
				 msecs_to_jiffies(KI_PSY_SETTLE_MS));

	return NOTIFY_OK;
}

static struct notifier_block ki_psy_nb = {
	.notifier_call = ki_psy_notifier_cb,
};

static ssize_t mode_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%d\n", READ_ONCE(current_profile_mode));
}

/* Caller must hold ki_profile_mutex */
static void ki_user_set_mode(int val)
{
	if (val == READ_ONCE(current_profile_mode))
		return;
	WRITE_ONCE(current_profile_mode, val);
	if (ki_apply_effective(true) == -EBUSY) {
		WRITE_ONCE(ki_screen_retry, 0);
		/* queue, not mod: do not pull forward 5-second screen-off timer */
		queue_delayed_work(system_highpri_wq, &ki_screen_work,
				   msecs_to_jiffies(100));
	}
}

static ssize_t mode_store(struct kobject *kobj, struct kobj_attribute *attr,
			  const char *buf, size_t count)
{
	int val;

	if (kstrtoint(buf, 10, &val))
		return -EINVAL;

	if (val < 0 || val >= KI_PROFILE_MAX)
		return -EINVAL;

	mutex_lock(&ki_profile_mutex);
	ki_user_set_mode(val);
	mutex_unlock(&ki_profile_mutex);

	return count;
}

static ssize_t current_profile_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	int mode = READ_ONCE(current_profile_mode);
	const char *name = "unknown";

	if (mode >= 0 && mode < KI_PROFILE_MAX)
		name = profile_names[mode];

	return scnprintf(buf, PAGE_SIZE, "%s\n", name);
}

static ssize_t available_modes_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "0: Battery Saver\n1: Balanced\n2: Performance/Gaming Turbo\n");
}

static ssize_t active_profile_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	int mode = READ_ONCE(ki_active_mode);

	if (mode < 0 || mode >= KI_PROFILE_MAX)
		return scnprintf(buf, PAGE_SIZE, "unknown\n");
	return scnprintf(buf, PAGE_SIZE, "%s\n", profile_names[mode]);
}

static ssize_t screen_off_battery_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%d\n", READ_ONCE(ki_screen_off_battery) ? 1 : 0);
}

static ssize_t screen_off_battery_store(struct kobject *kobj, struct kobj_attribute *attr,
					const char *buf, size_t count)
{
	bool val;

	if (kstrtobool(buf, &val))
		return -EINVAL;

	mutex_lock(&ki_profile_mutex);
	WRITE_ONCE(ki_screen_off_battery, val);
	ki_apply_effective(false);
	mutex_unlock(&ki_profile_mutex);

	return count;
}

static ssize_t screen_state_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%d\n", READ_ONCE(ki_screen_on) ? 1 : 0);
}

static ssize_t thermal_throttle_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	int user_throt = READ_ONCE(ki_user_thermal_throttle);

	if (user_throt >= 0)
		return scnprintf(buf, PAGE_SIZE, "%d\n", user_throt);

	return scnprintf(buf, PAGE_SIZE, "%d\n",
			 ki_tunes[ki_effective_mode()].thermal_throttle ? 1 : 0);
}

static ssize_t thermal_throttle_store(struct kobject *kobj, struct kobj_attribute *attr,
				      const char *buf, size_t count)
{
	bool val;
	int user_val;
	char str[16];
	char *trimmed;
	size_t len;

	len = min(count, sizeof(str) - 1);
	memcpy(str, buf, len);
	str[len] = '\0';
	trimmed = strim(str);

	if (!strcasecmp(trimmed, "auto") || !strcmp(trimmed, "-1") || !strcasecmp(trimmed, "default")) {
		user_val = -1;
	} else if (!kstrtobool(trimmed, &val)) {
		user_val = val ? 1 : 0;
	} else {
		return -EINVAL;
	}

	mutex_lock(&ki_profile_mutex);
	WRITE_ONCE(ki_user_thermal_throttle, user_val);
	ki_apply_effective(true);
	mutex_unlock(&ki_profile_mutex);

	return count;
}

static ssize_t thermal_throttle_active_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%d\n", READ_ONCE(ki_thermal_throttle_enabled) ? 1 : 0);
}

static ssize_t thermal_guard_active_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	unsigned long flags;
	bool active;

	spin_lock_irqsave(&ki_guard_lock, flags);
	active = ki_guard_bypass_active_locked() && READ_ONCE(ki_screen_on);
	spin_unlock_irqrestore(&ki_guard_lock, flags);

	return scnprintf(buf, PAGE_SIZE, "%d\n", active ? 1 : 0);
}

static ssize_t thermal_guard_tripped_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%d\n", READ_ONCE(ki_guard_tripped) ? 1 : 0);
}

static ssize_t ki_max_freq_store(int i, const char *buf, size_t count)
{
	unsigned int val;
	int ret;

	if (kstrtouint(buf, 10, &val))
		return -EINVAL;

	if (val && val < 300000)	/* below lowest valid SM8250 CPU OPP */
		return -EINVAL;

	mutex_lock(&ki_profile_mutex);
	WRITE_ONCE(ki_user_max_freq[i], val);
	ret = ki_cpufreq_set_limits(ki_cluster_cpu[i], 0,
				    ki_target_max(i, ki_effective_mode()));
	mutex_unlock(&ki_profile_mutex);
	return ret ? ret : (ssize_t)count;
}

static ssize_t max_freq_silver_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	unsigned int val = ki_cpufreq_get_max(ki_cluster_cpu[0]);
	return scnprintf(buf, PAGE_SIZE, "%u\n", val);
}

static ssize_t max_freq_silver_store(struct kobject *kobj, struct kobj_attribute *attr,
				     const char *buf, size_t count)
{
	return ki_max_freq_store(0, buf, count);
}

static ssize_t max_freq_gold_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	unsigned int val = ki_cpufreq_get_max(ki_cluster_cpu[1]);
	return scnprintf(buf, PAGE_SIZE, "%u\n", val);
}

static ssize_t max_freq_gold_store(struct kobject *kobj, struct kobj_attribute *attr,
				   const char *buf, size_t count)
{
	return ki_max_freq_store(1, buf, count);
}

static ssize_t max_freq_prime_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	unsigned int val = ki_cpufreq_get_max(ki_cluster_cpu[2]);
	return scnprintf(buf, PAGE_SIZE, "%u\n", val);
}

static ssize_t max_freq_prime_store(struct kobject *kobj, struct kobj_attribute *attr,
				    const char *buf, size_t count)
{
	return ki_max_freq_store(2, buf, count);
}

static struct kobj_attribute mode_attr = __ATTR_RW(mode);
static struct kobj_attribute current_profile_attr = __ATTR_RO(current_profile);
static struct kobj_attribute available_modes_attr = __ATTR_RO(available_modes);
static struct kobj_attribute thermal_throttle_attr = __ATTR_RW(thermal_throttle);
static struct kobj_attribute thermal_throttle_active_attr = __ATTR_RO(thermal_throttle_active);
static struct kobj_attribute thermal_guard_active_attr = __ATTR_RO(thermal_guard_active);
static struct kobj_attribute thermal_guard_tripped_attr = __ATTR_RO(thermal_guard_tripped);
static struct kobj_attribute active_profile_attr = __ATTR_RO(active_profile);
static struct kobj_attribute screen_off_battery_attr = __ATTR_RW(screen_off_battery);
static struct kobj_attribute max_freq_silver_attr = __ATTR_RW(max_freq_silver);
static struct kobj_attribute max_freq_gold_attr = __ATTR_RW(max_freq_gold);
static struct kobj_attribute max_freq_prime_attr = __ATTR_RW(max_freq_prime);
static struct kobj_attribute screen_state_attr = __ATTR_RO(screen_state);

/*
 * Userspace control interface via /proc/ki_profile (0644)
 * Allows scripts and root managers to monitor and switch profiles.
 */
static ssize_t ki_profile_proc_read(struct file *file, char __user *buf,
		size_t count, loff_t *ppos)
{
	char kbuf[32];
	int len;
	int mode = READ_ONCE(current_profile_mode);
	const char *name = "unknown";

	if (mode >= 0 && mode < KI_PROFILE_MAX)
		name = profile_names[mode];

	len = scnprintf(kbuf, sizeof(kbuf), "%d (%s)\n", mode, name);
	return simple_read_from_buffer(buf, count, ppos, kbuf, len);
}

static ssize_t ki_profile_proc_write(struct file *file, const char __user *buf,
		size_t count, loff_t *ppos)
{
	char kbuf[32];
	int val = -1;
	char *trimmed;

	if (count == 0 || count >= sizeof(kbuf))
		return -EINVAL;

	if (copy_from_user(kbuf, buf, count))
		return -EFAULT;

	kbuf[count] = '\0';
	trimmed = strim(kbuf);

	if (!strcmp(trimmed, "0") || !strcasecmp(trimmed, "battery"))
		val = KI_PROFILE_BATTERY;
	else if (!strcmp(trimmed, "1") || !strcasecmp(trimmed, "balanced"))
		val = KI_PROFILE_BALANCED;
	else if (!strcmp(trimmed, "2") || !strcasecmp(trimmed, "performance"))
		val = KI_PROFILE_PERFORMANCE;
	else if (!kstrtoint(trimmed, 10, &val)) {
		if (val < 0 || val >= KI_PROFILE_MAX)
			return -EINVAL;
	} else {
		return -EINVAL;
	}

	mutex_lock(&ki_profile_mutex);
	ki_user_set_mode(val);
	mutex_unlock(&ki_profile_mutex);

	return count;
}

static const struct file_operations ki_profile_proc_fops = {
	.owner = THIS_MODULE,
	.read = ki_profile_proc_read,
	.write = ki_profile_proc_write,
	.llseek = default_llseek,
};

static ssize_t reapply_store(struct kobject *kobj, struct kobj_attribute *attr,
			     const char *buf, size_t count)
{
	int ret;

	mutex_lock(&ki_profile_mutex);
	ret = ki_apply_effective(true);
	mutex_unlock(&ki_profile_mutex);

	if (ret > 0)		/* bitmask of failed sugov clusters, not byte count */
		ret = -EAGAIN;
	return ret < 0 ? ret : (ssize_t)count;
}

static struct kobj_attribute reapply_attr = __ATTR_WO(reapply);

static struct attribute *ki_profile_attrs[] = {
	&mode_attr.attr,
	&current_profile_attr.attr,
	&available_modes_attr.attr,
	&thermal_throttle_attr.attr,
	&thermal_throttle_active_attr.attr,
	&thermal_guard_active_attr.attr,
	&thermal_guard_tripped_attr.attr,
	&active_profile_attr.attr,
	&screen_off_battery_attr.attr,
	&max_freq_silver_attr.attr,
	&max_freq_gold_attr.attr,
	&max_freq_prime_attr.attr,
	&screen_state_attr.attr,
	&reapply_attr.attr,
	NULL,
};

static umode_t ki_profile_is_visible(struct kobject *kobj, struct attribute *attr, int n)
{
	if (attr == &mode_attr.attr ||
	    attr == &thermal_throttle_attr.attr ||
	    attr == &screen_off_battery_attr.attr ||
	    attr == &max_freq_silver_attr.attr ||
	    attr == &max_freq_gold_attr.attr ||
	    attr == &max_freq_prime_attr.attr ||
	    attr == &reapply_attr.attr)
		return 0664;

	return attr->mode;
}

static const struct attribute_group ki_profile_attr_group = {
	.attrs = ki_profile_attrs,
	.is_visible = ki_profile_is_visible,
};

static struct kobject *ki_profile_kobj;
static struct delayed_work ki_profile_delayed_work;
static int boot_settle_retries;

static void ki_profile_delayed_work_fn(struct work_struct *work)
{
	int err;

	mutex_lock(&ki_profile_mutex);
	err = ki_apply_effective(true);
	mutex_unlock(&ki_profile_mutex);

	if (err && boot_settle_retries < 6) {
		boot_settle_retries++;
		pr_info("ki_profile: sugov limits pending (err=%d), retrying in 5s (%d/6)\n",
			err, boot_settle_retries);
		schedule_delayed_work(&ki_profile_delayed_work, msecs_to_jiffies(5000));
		return;
	}

	if (err) {
		pr_warn("ki_profile: Boot settlement gave up, err=%d\n", err);
	} else {
		int active = ki_get_active_profile();
		const char *active_name = (active >= 0 && active < KI_PROFILE_MAX) ?
					  profile_names[active] : "unknown";

		pr_info("ki_profile: Boot settlement complete, profile %d (%s) active\n",
			active, active_name);
	}
}

static int __init ki_profile_init(void)
{
	int rc;

	/* 1. Initialize all delayed work queues BEFORE creating sysfs */
	INIT_DELAYED_WORK(&ki_guard_work, ki_guard_work_fn);
	INIT_DELAYED_WORK(&ki_screen_work, ki_screen_work_fn);
	INIT_DELAYED_WORK(&ki_psy_work, ki_psy_work_fn);
	INIT_DELAYED_WORK(&ki_profile_delayed_work, ki_profile_delayed_work_fn);

	/* 2. Create kobject and sysfs group */
	ki_profile_kobj = kobject_create_and_add("ki_profile", kernel_kobj);
	if (!ki_profile_kobj) {
		pr_err("ki_profile: Failed to create kobject\n");
		return -ENOMEM;
	}

	rc = sysfs_create_group(ki_profile_kobj, &ki_profile_attr_group);
	if (rc) {
		pr_err("ki_profile: Failed to create sysfs group\n");
		kobject_put(ki_profile_kobj);
		return rc;
	}

	/* Control interface via /proc/ki_profile (0644: root RW, user RO) */
	if (!proc_create("ki_profile", 0644, NULL, &ki_profile_proc_fops))
		pr_warn("ki_profile: Failed to create /proc/ki_profile entry\n");

	/* 3. Apply default profile */
	mutex_lock(&ki_profile_mutex);
	ki_apply_effective(true);
	mutex_unlock(&ki_profile_mutex);

	/* 4. Register MI DRM display notifier */
	rc = mi_drm_register_client(&ki_display_nb);
	if (rc)
		pr_warn("ki_profile: display notifier register failed (%d), screen-off battery disabled\n",
			rc);

	/* 5. Register Power Supply notifier for charging state changes while screen off */
	rc = power_supply_reg_notifier(&ki_psy_nb);
	if (rc)
		pr_warn("ki_profile: power supply notifier register failed (%d)\n", rc);

	/*
	 * Schedule delayed enforcement after 25 seconds so userspace post_boot
	 * scripts (which overwrite schedutil and migration margins) are overridden
	 * by Ki-Profile.
	 */
	schedule_delayed_work(&ki_profile_delayed_work, msecs_to_jiffies(25000));

	pr_info("ki_profile: Ki-kernel Profile driver initialized (default: Balanced)\n");
	return 0;
}
late_initcall(ki_profile_init);

MODULE_DESCRIPTION("Ki-kernel CPU Profile Driver");
MODULE_LICENSE("GPL v2");
