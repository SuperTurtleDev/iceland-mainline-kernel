#include <linux/device.h>
#include <linux/err.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/pm_domain.h>
#include <linux/pm_runtime.h>
#include <linux/suspend.h>
#include <linux/unaligned.h>
#include <soc/qcom/cmd-db.h>

#include <dt-bindings/power/qcom,rpmhpd.h>

static unsigned int domains = 3;
module_param(domains, uint, 0444);
MODULE_PARM_DESC(domains, "Domain mask: 1=LCX, 2=LMX, 3=both");

static unsigned int level = RPMH_REGULATOR_LEVEL_NOM;
module_param(level, uint, 0444);
MODULE_PARM_DESC(level, "Exact CMD-DB performance level, default 256");

static int setup_status;
module_param(setup_status, int, 0444);

static bool held;
module_param(held, bool, 0444);

struct held_domain {
	const char *name;
	const char *resource;
	unsigned int id;
	struct device *dev;
	bool attached;
	bool runtime_enabled;
	bool resumed;
};

static struct held_domain domain_votes[] = {
	{ .name = "iceland-hold-lcx", .resource = "lcx.lvl", .id = RPMHPD_LCX },
	{ .name = "iceland-hold-lmx", .resource = "lmx.lvl", .id = RPMHPD_LMX },
};

static DEFINE_MUTEX(hold_lock);
static bool ready;
static bool pinned;

static int validate_level(const struct held_domain *vote)
{
	const u8 *levels;
	size_t length, offset;
	unsigned int supported;

	levels = cmd_db_read_aux_data(vote->resource, &length);
	if (IS_ERR(levels))
		return PTR_ERR(levels);
	if (!length || length % sizeof(__le16))
		return -EINVAL;

	for (offset = 0; offset < length; offset += sizeof(__le16)) {
		supported = get_unaligned_le16(levels + offset);
		if (offset && !supported)
			break;
		if (supported == level)
			return 0;
	}

	pr_err("iceland_power_domain_hold: %s unsupported level=%u\n",
	       vote->resource, level);
	return -EINVAL;
}

static int drop_vote(struct held_domain *vote)
{
	int ret;

	if (!vote->resumed)
		return 0;

	ret = dev_pm_genpd_set_performance_state(vote->dev, 0);
	if (ret)
		return ret;

	ret = pm_runtime_put_sync_suspend(vote->dev);
	if (ret < 0) {
		pm_runtime_get_noresume(vote->dev);
		return ret;
	}

	vote->resumed = false;
	pr_info("iceland_power_domain_hold: %s vote released\n", vote->resource);
	return 0;
}

static int drop_all_votes(void)
{
	int index, ret;

	for (index = ARRAY_SIZE(domain_votes) - 1; index >= 0; index--) {
		ret = drop_vote(&domain_votes[index]);
		if (ret) {
			pr_err("iceland_power_domain_hold: %s release failed: %d\n",
			       domain_votes[index].resource, ret);
			return ret;
		}
	}

	held = false;
	return 0;
}

static int detach_all(void)
{
	struct held_domain *vote;
	int index, ret;

	ret = drop_all_votes();
	if (ret)
		return ret;

	for (index = ARRAY_SIZE(domain_votes) - 1; index >= 0; index--) {
		vote = &domain_votes[index];
		if (!vote->dev)
			continue;
		if (vote->runtime_enabled) {
			pm_runtime_disable(vote->dev);
			vote->runtime_enabled = false;
		}
		if (vote->attached) {
			ret = pm_genpd_remove_device(vote->dev);
			if (ret) {
				pr_err("iceland_power_domain_hold: %s detach failed: %d\n",
				       vote->resource, ret);
				return ret;
			}
			vote->attached = false;
		}
		root_device_unregister(vote->dev);
		vote->dev = NULL;
	}

	ready = false;
	return 0;
}

static int hold_set(const char *value, const struct kernel_param *parameter)
{
	unsigned int sleep_flags;
	struct held_domain *vote;
	bool requested;
	int index, ret, rollback_ret;

	ret = kstrtobool(value, &requested);
	if (ret || !requested)
		return ret ? ret : -EINVAL;

	sleep_flags = lock_system_sleep();
	mutex_lock(&hold_lock);
	if (!ready || setup_status) {
		ret = setup_status ? setup_status : -ENODEV;
		goto out;
	}
	if (held) {
		ret = 0;
		goto out;
	}

	for (index = 0; index < ARRAY_SIZE(domain_votes); index++) {
		vote = &domain_votes[index];
		if (!vote->dev)
			continue;
		ret = pm_runtime_resume_and_get(vote->dev);
		if (ret < 0)
			goto rollback;
		vote->resumed = true;
		ret = dev_pm_genpd_set_performance_state(vote->dev, level);
		if (ret)
			goto rollback;
		pr_info("iceland_power_domain_hold: %s held level=%u\n",
			vote->resource, level);
	}
	held = true;
	ret = 0;
	goto out;

rollback:
	pr_err("iceland_power_domain_hold: %s hold failed: %d\n",
	       vote->resource, ret);
	rollback_ret = drop_all_votes();
	if (rollback_ret)
		setup_status = rollback_ret;
out:
	mutex_unlock(&hold_lock);
	unlock_system_sleep(sleep_flags);
	return ret;
}

static int release_set(const char *value, const struct kernel_param *parameter)
{
	unsigned int sleep_flags;
	bool requested;
	int ret;

	ret = kstrtobool(value, &requested);
	if (ret || !requested)
		return ret ? ret : -EINVAL;

	sleep_flags = lock_system_sleep();
	mutex_lock(&hold_lock);
	ret = detach_all();
	if (!ret && pinned) {
		pinned = false;
		pr_info("iceland_power_domain_hold: detached, safe to unload\n");
		module_put(THIS_MODULE);
	}
	mutex_unlock(&hold_lock);
	unlock_system_sleep(sleep_flags);
	return ret;
}

static const struct kernel_param_ops hold_ops = { .set = hold_set };
static const struct kernel_param_ops release_ops = { .set = release_set };
module_param_cb(hold, &hold_ops, NULL, 0200);
module_param_cb(release, &release_ops, NULL, 0200);

static int __init iceland_power_domain_hold_init(void)
{
	struct of_phandle_args domain_spec = { .args_count = 1 };
	struct held_domain *vote;
	unsigned int sleep_flags;
	int index, ret, cleanup_ret;

	if (!domains || domains & ~3U || !level)
		return -EINVAL;
	domain_spec.np = of_find_compatible_node(NULL, NULL,
					       "qcom,kaanapali-rpmhpd");
	if (!domain_spec.np)
		return -ENODEV;

	sleep_flags = lock_system_sleep();
	for (index = 0; index < ARRAY_SIZE(domain_votes); index++) {
		if (!(domains & BIT(index)))
			continue;
		ret = validate_level(&domain_votes[index]);
		if (ret)
			goto rollback;
	}
	for (index = 0; index < ARRAY_SIZE(domain_votes); index++) {
		if (!(domains & BIT(index)))
			continue;
		vote = &domain_votes[index];
		vote->dev = root_device_register(vote->name);
		if (IS_ERR(vote->dev)) {
			ret = PTR_ERR(vote->dev);
			vote->dev = NULL;
			goto rollback;
		}
		ret = pm_runtime_set_suspended(vote->dev);
		if (ret)
			goto rollback;
		domain_spec.args[0] = vote->id;
		ret = of_genpd_add_device(&domain_spec, vote->dev);
		if (ret)
			goto rollback;
		vote->attached = true;
		pm_runtime_enable(vote->dev);
		vote->runtime_enabled = true;
	}
	ready = true;
	__module_get(THIS_MODULE);
	pinned = true;
	pr_info("iceland_power_domain_hold: attached domains=%u level=%u; write hold=1, then release=1 before unload\n",
		domains, level);
	ret = 0;
	goto out;

rollback:
	setup_status = ret;
	cleanup_ret = detach_all();
	if (cleanup_ret) {
		__module_get(THIS_MODULE);
		pinned = true;
		pr_err("iceland_power_domain_hold: setup=%d cleanup=%d; retained for release retry\n",
		       ret, cleanup_ret);
		ret = 0;
	}
out:
	unlock_system_sleep(sleep_flags);
	of_node_put(domain_spec.np);
	return ret;
}

static void __exit iceland_power_domain_hold_exit(void)
{
	pr_info("iceland_power_domain_hold: unloaded\n");
}

module_init(iceland_power_domain_hold_init);
module_exit(iceland_power_domain_hold_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Temporary LCX/LMX genpd votes for Iceland diagnosis");
