/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_KI_PROFILE_H
#define _LINUX_KI_PROFILE_H

enum ki_profile_mode {
	KI_PROFILE_BATTERY = 0,
	KI_PROFILE_BALANCED = 1,
	KI_PROFILE_PERFORMANCE = 2,
	KI_PROFILE_MAX,
};

int sugov_set_cluster_rate_limits(unsigned int cpu, unsigned int up_us, unsigned int down_us);
int sugov_set_cluster_rtg_boost(unsigned int cpu, unsigned int freq_hz);
int sugov_set_cluster_hispeed(unsigned int cpu, unsigned int freq_hz, unsigned int load);
int sugov_set_cluster_floor(unsigned int cpu, unsigned int freq_hz);
int sugov_set_cluster_pl(unsigned int cpu, bool enable);
int sugov_set_cluster_iowait_boost(unsigned int cpu, unsigned int max_pct);
void kgsl_set_performance_mode(bool enable);
void sched_set_updown_migrate(unsigned int up, unsigned int down);
void sched_set_group_updown_migrate(unsigned int up_pct, unsigned int down_pct);
int sched_set_boost(int type);
int ki_cpufreq_reset_idle_floors(int mode);
int ki_cpufreq_set_limits(unsigned int cpu, unsigned int min_freq, unsigned int max_freq);
unsigned int ki_cpufreq_get_max(unsigned int cpu);
int ki_get_active_profile(void);

extern int current_profile_mode;
extern bool ki_thermal_throttle_enabled;
extern unsigned int sysctl_sched_window_stats_policy;

#endif /* _LINUX_KI_PROFILE_H */
