// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2013-2015,2017,2019, The Linux Foundation. All rights reserved.
 */

#define pr_fmt(fmt) "cpu-boost: " fmt

#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/cpufreq.h>
#include <linux/cpu.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/input.h>
#include <linux/mutex.h>
#include <linux/time.h>
#include <linux/sysfs.h>

#define cpu_boost_attr_rw(_name)		\
static struct kobj_attribute _name##_attr =	\
__ATTR(_name, 0644, show_##_name, store_##_name)

#define show_one(file_name)			\
static ssize_t show_##file_name			\
(struct kobject *kobj, struct kobj_attribute *attr, char *buf)	\
{								\
	return scnprintf(buf, PAGE_SIZE, "%u\n", file_name);	\
}

#define store_one(file_name)					\
static ssize_t store_##file_name				\
(struct kobject *kobj, struct kobj_attribute *attr,		\
const char *buf, size_t count)					\
{								\
								\
	sscanf(buf, "%u", &file_name);				\
	return count;						\
}

struct cpu_sync {
	int cpu;
	unsigned int input_boost_min;
	unsigned int input_boost_freq;
	unsigned int powerkey_input_boost_freq;
};

static DEFINE_PER_CPU(struct cpu_sync, sync_info);
static struct workqueue_struct *cpu_boost_wq;

static struct work_struct input_boost_work;

static struct work_struct powerkey_input_boost_work;
static bool input_boost_enabled;

static unsigned int input_boost_ms = 40;
show_one(input_boost_ms);
store_one(input_boost_ms);
cpu_boost_attr_rw(input_boost_ms);

static unsigned int powerkey_input_boost_ms = 400;
show_one(powerkey_input_boost_ms);
store_one(powerkey_input_boost_ms);
cpu_boost_attr_rw(powerkey_input_boost_ms);

static unsigned int sched_boost_on_input;
show_one(sched_boost_on_input);
store_one(sched_boost_on_input);
cpu_boost_attr_rw(sched_boost_on_input);


static unsigned int sched_boost_on_powerkey_input = 1;
show_one(sched_boost_on_powerkey_input);
store_one(sched_boost_on_powerkey_input);
cpu_boost_attr_rw(sched_boost_on_powerkey_input);

/* Serializes the boost works, which can otherwise run concurrently */
static DEFINE_MUTEX(boost_lock);
/* Boost type currently held by cpu-boost, 0 if none. Protected by boost_lock */
static int active_sched_boost;

#define FULL_THROTTLE_BOOST_TYPE	1
#define RESTRAINED_BOOST_TYPE		3

static struct delayed_work input_boost_rem;
static u64 last_input_time;
#define MIN_INPUT_INTERVAL (80 * USEC_PER_MSEC)

static ssize_t store_input_boost_freq(struct kobject *kobj,
				      struct kobj_attribute *attr,
				      const char *buf, size_t count)
{
	int i, ntokens = 0;
	unsigned int val, cpu;
	const char *cp = buf;
	bool enabled = false;

	while ((cp = strpbrk(cp + 1, " :")))
		ntokens++;

	/* single number: apply to all CPUs */
	if (!ntokens) {
		if (sscanf(buf, "%u\n", &val) != 1)
			return -EINVAL;
		for_each_possible_cpu(i)
			per_cpu(sync_info, i).input_boost_freq = val;
		goto check_enable;
	}

	/* CPU:value pair */
	if (!(ntokens % 2))
		return -EINVAL;

	cp = buf;
	for (i = 0; i < ntokens; i += 2) {
		if (sscanf(cp, "%u:%u", &cpu, &val) != 2)
			return -EINVAL;
		if (cpu >= num_possible_cpus())
			return -EINVAL;

		per_cpu(sync_info, cpu).input_boost_freq = val;
		cp = strnchr(cp, PAGE_SIZE - (cp - buf), ' ');
		cp++;
	}

check_enable:
	for_each_possible_cpu(i) {
		if (per_cpu(sync_info, i).input_boost_freq) {
			enabled = true;
			break;
		}
	}
	input_boost_enabled = enabled;

	return count;
}

static ssize_t show_input_boost_freq(struct kobject *kobj,
				     struct kobj_attribute *attr, char *buf)
{
	int cnt = 0, cpu;
	struct cpu_sync *s;

	for_each_possible_cpu(cpu) {
		s = &per_cpu(sync_info, cpu);
		cnt += snprintf(buf + cnt, PAGE_SIZE - cnt,
				"%d:%u ", cpu, s->input_boost_freq);
	}
	cnt += snprintf(buf + cnt, PAGE_SIZE - cnt, "\n");
	return cnt;
}

cpu_boost_attr_rw(input_boost_freq);
static ssize_t store_powerkey_input_boost_freq(struct kobject *kobj,
				      struct kobj_attribute *attr,
				      const char *buf, size_t count)
{
	int i, ntokens = 0;
	unsigned int val, cpu;
	const char *cp = buf;
	bool enabled = false;

	while ((cp = strpbrk(cp + 1, " :")))
		ntokens++;

	/* single number: apply to all CPUs */
	if (!ntokens) {
		if (sscanf(buf, "%u\n", &val) != 1)
			return -EINVAL;
		for_each_possible_cpu(i)
			per_cpu(sync_info, i).powerkey_input_boost_freq = val;
		goto check_enable;
	}

	/* CPU:value pair */
	if (!(ntokens % 2))
		return -EINVAL;

	cp = buf;
	for (i = 0; i < ntokens; i += 2) {
		if (sscanf(cp, "%u:%u", &cpu, &val) != 2)
			return -EINVAL;
		if (cpu >= num_possible_cpus())
			return -EINVAL;
		per_cpu(sync_info, cpu).powerkey_input_boost_freq = val;
		cp = strnchr(cp, PAGE_SIZE - (cp - buf), ' ');
		cp++;
	}

check_enable:
	for_each_possible_cpu(i) {
		if (per_cpu(sync_info, i).powerkey_input_boost_freq) {
			enabled = true;
			break;
		}
	}
	input_boost_enabled = enabled;

	return count;
}

static ssize_t show_powerkey_input_boost_freq(struct kobject *kobj,
				     struct kobj_attribute *attr, char *buf)
{
	int cnt = 0, cpu;
	struct cpu_sync *s;
	unsigned int boost_freq = 0;

	for_each_possible_cpu(cpu) {
		s = &per_cpu(sync_info, cpu);
		boost_freq = s->powerkey_input_boost_freq;
		cnt += snprintf(buf + cnt, PAGE_SIZE - cnt,
				"%d:%u ", cpu, boost_freq);
	}
	cnt += snprintf(buf + cnt, PAGE_SIZE - cnt, "\n");
	return cnt;
}


cpu_boost_attr_rw(powerkey_input_boost_freq);

/*
 * The CPUFREQ_ADJUST notifier is used to override the current policy min to
 * make sure policy min >= boost_min. The cpufreq framework then does the job
 * of enforcing the new policy.
 */
static int boost_adjust_notify(struct notifier_block *nb, unsigned long val,
				void *data)
{
	struct cpufreq_policy *policy = data;
	unsigned int cpu = policy->cpu;
	struct cpu_sync *s = &per_cpu(sync_info, cpu);
	unsigned int ib_min = s->input_boost_min;

	switch (val) {
	case CPUFREQ_ADJUST:
		if (!ib_min)
			break;

		pr_debug("CPU%u policy min before boost: %u kHz\n",
			 cpu, policy->min);
		pr_debug("CPU%u boost min: %u kHz\n", cpu, ib_min);

		cpufreq_verify_within_limits(policy, ib_min, UINT_MAX);

		pr_debug("CPU%u policy min after boost: %u kHz\n",
			 cpu, policy->min);
		break;
	}

	return NOTIFY_OK;
}

static struct notifier_block boost_adjust_nb = {
	.notifier_call = boost_adjust_notify,
};

static void update_policy_online(void)
{
	unsigned int i;
	struct cpufreq_policy *policy;
	cpumask_t visited_cpus;

	cpumask_clear(&visited_cpus);
	/* Re-evaluate policy to trigger adjust notifier for online CPUs */
	get_online_cpus();
	for_each_online_cpu(i) {
		if (cpumask_test_cpu(i, &visited_cpus))
			continue;
		policy = cpufreq_cpu_get(i);
		if (policy) {
			cpumask_or(&visited_cpus, &visited_cpus, policy->related_cpus);
			cpufreq_cpu_put(policy);
		}
		pr_debug("Updating policy for CPU%d\n", i);
		cpufreq_update_policy(i);
	}
	put_online_cpus();
}

/*
 * Drop only cpu-boost's own reference. sched_set_boost(0) would clear every
 * holder, including the boost of the Ki-Profile Performance mode.
 * Types above RESTRAINED (MI_BOOST) are enabled as FULL_THROTTLE.
 */
static void release_sched_boost(void)
{
	int type = active_sched_boost;

	if (!type)
		return;

	if (sched_set_boost(type > RESTRAINED_BOOST_TYPE ?
			    -FULL_THROTTLE_BOOST_TYPE : -type))
		pr_err("cpu-boost: sched boost disable failed\n");
	active_sched_boost = 0;
}

static void do_input_boost_rem(struct work_struct *work)
{
	unsigned int i;
	struct cpu_sync *i_sync_info;

	mutex_lock(&boost_lock);

	/* A newer boost re-armed this work while it waited for the lock */
	if (delayed_work_pending(&input_boost_rem)) {
		mutex_unlock(&boost_lock);
		return;
	}

	/* Reset the input_boost_min for all CPUs in the system */
	pr_debug("Resetting input boost min for all CPUs\n");
	for_each_possible_cpu(i) {
		i_sync_info = &per_cpu(sync_info, i);
		i_sync_info->input_boost_min = 0;
	}

	/* Update policies for all online CPUs */
	update_policy_online();

	release_sched_boost();
	mutex_unlock(&boost_lock);
}

static void do_input_boost(struct work_struct *work)
{
	unsigned int i, ret;
	struct cpu_sync *i_sync_info;

	mutex_lock(&boost_lock);
	cancel_delayed_work(&input_boost_rem);
	release_sched_boost();

	/* Set the input_boost_min for all CPUs in the system */
	pr_debug("Setting input boost min for all CPUs\n");
	for_each_possible_cpu(i) {
		i_sync_info = &per_cpu(sync_info, i);
		i_sync_info->input_boost_min = i_sync_info->input_boost_freq;
	}

	/* Update policies for all online CPUs */
	update_policy_online();

	/* Enable scheduler boost to migrate tasks to big cluster */
	if (sched_boost_on_input > 0) {
		ret = sched_set_boost(sched_boost_on_input);
		if (ret)
			pr_err("cpu-boost: sched boost enable failed\n");
		else
			active_sched_boost = sched_boost_on_input;
	}

	queue_delayed_work(cpu_boost_wq, &input_boost_rem,
					msecs_to_jiffies(input_boost_ms));
	mutex_unlock(&boost_lock);
}

static void do_powerkey_input_boost(struct work_struct *work)
{

	unsigned int i, ret;
	struct cpu_sync *i_sync_info;

	mutex_lock(&boost_lock);
	cancel_delayed_work(&input_boost_rem);
	release_sched_boost();

	/* Set the powerkey_input_boost_min for all CPUs in the system */
	pr_debug("Setting powerkey input boost min for all CPUs\n");
	for_each_possible_cpu(i) {
		i_sync_info = &per_cpu(sync_info, i);
		i_sync_info->input_boost_min =
			i_sync_info->powerkey_input_boost_freq;
	}

	/* Update policies for all online CPUs */
	update_policy_online();

	/* Enable scheduler boost to migrate tasks to big cluster */
	if (sched_boost_on_powerkey_input) {
		ret = sched_set_boost(FULL_THROTTLE_BOOST_TYPE);
		if (ret)
			pr_err("cpu-boost: HMP boost enable failed\n");
		else
			active_sched_boost = FULL_THROTTLE_BOOST_TYPE;
	}

	queue_delayed_work(cpu_boost_wq, &input_boost_rem,
				msecs_to_jiffies(powerkey_input_boost_ms));
	mutex_unlock(&boost_lock);
}

static void cpuboost_input_event(struct input_handle *handle,
		unsigned int type, unsigned int code, int value)
{
	u64 now;

	if (!input_boost_enabled)
		return;

	/*
	 * Skip release frames (SLOT, TRACKING_ID -1, key up, SYN). A finger that
	 * moves still reports ABS_MT_POSITION_*, so gestures keep boosting.
	 */
	if (type == EV_SYN || (type == EV_KEY && value == 0) ||
	    (type == EV_ABS && (code == ABS_MT_SLOT ||
				(code == ABS_MT_TRACKING_ID && value < 0))))
		return;

	now = ktime_to_us(ktime_get());
	if (now - last_input_time < MIN_INPUT_INTERVAL)
		return;

	if (work_pending(&input_boost_work))
		return;

	if (type == EV_KEY && code == KEY_POWER)
		queue_work(cpu_boost_wq, &powerkey_input_boost_work);
	else
		queue_work(cpu_boost_wq, &input_boost_work);

	last_input_time = ktime_to_us(ktime_get());
}

#ifdef CONFIG_XIAOMI_MIUI
void touch_irq_boost(void)
{
	u64 now;

	if (!input_boost_enabled)
		return;

	now = ktime_to_us(ktime_get());
	if (now - last_input_time < MIN_INPUT_INTERVAL)
		return;

	if (work_pending(&input_boost_work))
		return;

	queue_work(cpu_boost_wq, &input_boost_work);

	last_input_time = ktime_to_us(ktime_get());
}
EXPORT_SYMBOL(touch_irq_boost);
#else
void touch_irq_boost(void)
{
	// Do Nothing
}
EXPORT_SYMBOL(touch_irq_boost);
#endif

static int cpuboost_input_connect(struct input_handler *handler,
		struct input_dev *dev, const struct input_device_id *id)
{
	struct input_handle *handle;
	int error;

	handle = kzalloc(sizeof(struct input_handle), GFP_KERNEL);
	if (!handle)
		return -ENOMEM;

	handle->dev = dev;
	handle->handler = handler;
	handle->name = "cpufreq";

	error = input_register_handle(handle);
	if (error)
		goto err2;

	error = input_open_device(handle);
	if (error)
		goto err1;

	return 0;
err1:
	input_unregister_handle(handle);
err2:
	kfree(handle);
	return error;
}

static void cpuboost_input_disconnect(struct input_handle *handle)
{
	input_close_device(handle);
	input_unregister_handle(handle);
	kfree(handle);
}

static const struct input_device_id cpuboost_ids[] = {
	/* multi-touch touchscreen */
	{
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT |
			INPUT_DEVICE_ID_MATCH_ABSBIT,
		.evbit = { BIT_MASK(EV_ABS) },
		.absbit = { [BIT_WORD(ABS_MT_POSITION_X)] =
			BIT_MASK(ABS_MT_POSITION_X) |
			BIT_MASK(ABS_MT_POSITION_Y) },
	},
	/* touchpad */
	{
		.flags = INPUT_DEVICE_ID_MATCH_KEYBIT |
			INPUT_DEVICE_ID_MATCH_ABSBIT,
		.keybit = { [BIT_WORD(BTN_TOUCH)] = BIT_MASK(BTN_TOUCH) },
		.absbit = { [BIT_WORD(ABS_X)] =
			BIT_MASK(ABS_X) | BIT_MASK(ABS_Y) },
	},
	/* Keypad */
	{
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT,
		.evbit = { BIT_MASK(EV_KEY) },
	},
	{ },
};

static struct input_handler cpuboost_input_handler = {
	.event          = cpuboost_input_event,
	.connect        = cpuboost_input_connect,
	.disconnect     = cpuboost_input_disconnect,
	.name           = "cpu-boost",
	.id_table       = cpuboost_ids,
};

struct kobject *cpu_boost_kobj;
static int cpu_boost_init(void)
{
	int cpu, ret;
	struct cpu_sync *s;

	cpu_boost_wq = alloc_workqueue("cpuboost_wq", WQ_HIGHPRI, 0);
	if (!cpu_boost_wq)
		return -EFAULT;

	INIT_WORK(&input_boost_work, do_input_boost);
	INIT_WORK(&powerkey_input_boost_work, do_powerkey_input_boost);
	INIT_DELAYED_WORK(&input_boost_rem, do_input_boost_rem);

	for_each_possible_cpu(cpu) {
		s = &per_cpu(sync_info, cpu);
		s->cpu = cpu;
	}
	cpufreq_register_notifier(&boost_adjust_nb, CPUFREQ_POLICY_NOTIFIER);

	cpu_boost_kobj = kobject_create_and_add("cpu_boost",
						&cpu_subsys.dev_root->kobj);
	if (!cpu_boost_kobj)
		pr_err("Failed to initialize sysfs node for cpu_boost.\n");

	ret = sysfs_create_file(cpu_boost_kobj, &input_boost_ms_attr.attr);
	if (ret)
		pr_err("Failed to create input_boost_ms node: %d\n", ret);

	ret = sysfs_create_file(cpu_boost_kobj,
				&powerkey_input_boost_ms_attr.attr);
	if (ret)
		pr_err("Failed to create powerkey_input_boost_ms node: %d\n",
			ret);

	ret = sysfs_create_file(cpu_boost_kobj, &input_boost_freq_attr.attr);
	if (ret)
		pr_err("Failed to create input_boost_freq node: %d\n", ret);

	ret = sysfs_create_file(cpu_boost_kobj,
				&powerkey_input_boost_freq_attr.attr);
	if (ret)
		pr_err("Failed to create powerkey_input_boost_freq node: %d\n",
			ret);

	ret = sysfs_create_file(cpu_boost_kobj,
				&sched_boost_on_input_attr.attr);
	if (ret)
		pr_err("Failed to create sched_boost_on_input node: %d\n", ret);

	ret = sysfs_create_file(cpu_boost_kobj,
				&sched_boost_on_powerkey_input_attr.attr);
	if (ret)
		pr_err("Failed to create sched_boost_on_powerkey_input node: %d\n",
			ret);

	ret = input_register_handler(&cpuboost_input_handler);
	return 0;
}
late_initcall(cpu_boost_init);
