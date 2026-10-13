#include <linux/err.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/regulator/consumer.h>

static char *rail;
module_param(rail, charp, 0444);
MODULE_PARM_DESC(rail, "Existing regulator-name to hold enabled until unload");

static struct regulator *supply;
static bool held;

static int release_set(const char *value, const struct kernel_param *parameter)
{
	bool requested;
	int ret;

	ret = kstrtobool(value, &requested);
	if (ret || !requested)
		return ret ? ret : -EINVAL;
	if (!held)
		return 0;

	ret = regulator_disable(supply);
	pr_info("iceland_power_hold: %s released ret=%d enabled=%d\n",
		rail, ret, regulator_is_enabled(supply));
	if (!ret)
		held = false;
	return ret;
}

static const struct kernel_param_ops release_ops = {
	.set = release_set,
};
module_param_cb(release, &release_ops, NULL, 0200);

static int __init iceland_power_hold_init(void)
{
	int ret;

	if (!rail || !*rail)
		return -EINVAL;

	supply = regulator_get_optional(NULL, rail);
	if (IS_ERR(supply))
		return PTR_ERR(supply);

	pr_info("iceland_power_hold: %s before enabled=%d voltage=%d\n",
		rail, regulator_is_enabled(supply), regulator_get_voltage(supply));
	ret = regulator_enable(supply);
	if (ret) {
		regulator_put(supply);
		return ret;
	}
	held = true;

	pr_info("iceland_power_hold: %s held enabled=%d voltage=%d\n",
		rail, regulator_is_enabled(supply), regulator_get_voltage(supply));
	return 0;
}

static void __exit iceland_power_hold_exit(void)
{
	if (held)
		release_set("1", NULL);
	regulator_put(supply);
}

module_init(iceland_power_hold_init);
module_exit(iceland_power_hold_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Temporary single regulator enable vote for Iceland diagnosis");
