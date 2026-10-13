#include <linux/clk.h>
#include <linux/err.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/of.h>

static unsigned int clock_id;
module_param(clock_id, uint, 0444);
MODULE_PARM_DESC(clock_id, "Kaanapali RPMh clock ID to hold enabled until unload");

static struct clk *held_clock;

static int __init iceland_clock_hold_init(void)
{
	struct of_phandle_args clock_spec = {};
	int ret;

	clock_spec.np = of_find_compatible_node(NULL, NULL,
					      "qcom,kaanapali-rpmh-clk");
	if (!clock_spec.np) {
		pr_err("iceland_clock_hold: RPMh clock provider not found\n");
		return -ENODEV;
	}
	clock_spec.args_count = 1;
	clock_spec.args[0] = clock_id;
	held_clock = of_clk_get_from_provider(&clock_spec);
	of_node_put(clock_spec.np);
	if (IS_ERR(held_clock)) {
		ret = PTR_ERR(held_clock);
		pr_err("iceland_clock_hold: clock_id=%u lookup failed: %d\n",
		       clock_id, ret);
		return ret;
	}

	pr_info("iceland_clock_hold: clock_id=%u before rate=%lu\n",
		clock_id, clk_get_rate(held_clock));
	ret = clk_prepare_enable(held_clock);
	if (ret) {
		pr_err("iceland_clock_hold: clock_id=%u enable failed: %d\n",
		       clock_id, ret);
		clk_put(held_clock);
		return ret;
	}

	pr_info("iceland_clock_hold: clock_id=%u held rate=%lu\n",
		clock_id, clk_get_rate(held_clock));
	return 0;
}

static void __exit iceland_clock_hold_exit(void)
{
	clk_disable_unprepare(held_clock);
	pr_info("iceland_clock_hold: clock_id=%u released\n", clock_id);
	clk_put(held_clock);
}

module_init(iceland_clock_hold_init);
module_exit(iceland_clock_hold_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Temporary RPMh clock enable vote for Iceland diagnosis");
