// SPDX-License-Identifier: MIT
/*
 * charge_boost_lite - USB PD fixed-PDO vbus booster for the Qualcomm
 * SM8850 (kaanapali) battery manager found in OnePlus Pad 4 (iceland).
 *
 * What it does
 * ------------
 * Attaches a private pmic_glink client (via the exported pmic_glink /
 * auxiliary-bus helpers, no kernel tree changes) and requests a higher
 * fixed PDO from the charger, following the reference charging stack:
 *
 *   1. read the adapter detection state (PD / PD_PPS contract?)
 *   2. drop the input current limit to a low value
 *      (contract renegotiation window),
 *   3. request the fixed PDO voltage (SET_PDO, value in mV),
 *   4. verify the physical vbus moved (>= 7.5 V for a 9 V request),
 *   5. re-raise the input current limit,
 *   6. on module unload restore the 5 V baseline (PDO 5000 mV and
 *      the captured input-current baseline).
 *
 * All interaction is through published kernel interfaces and the
 * battery-manager message channel; no proprietary charging curves,
 * current tables or protocol data are included.
 *
 * Parameters (see README)
 * -----------------------
 *   pdo_mv   target fixed PDO voltage in mV (5000/9000/12000),
 *            writable at runtime, writing re-sends the request
 *   curr_uv  input current limit after boost, uA, runtime writable
 *   apply    run the automatic sequence at load (default true)
 *
 * This program is distributed under the MIT license, see LICENSE.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/device.h>
#include <linux/auxiliary_bus.h>
#include <linux/power_supply.h>
#include <linux/completion.h>
#include <linux/delay.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/soc/qcom/pmic_glink.h>

/* battery-manager wire constants (drivers/power/supply/qcom_battmgr.c) */
#define LITE_OWNER_BATTMGR	32778
#define LITE_TYPE_REQ_RESP	1

#define OP_USB_GET		0x32
#define OP_USB_SET		0x33
#define OP_OPLUS_SET		0x300
#define OP_OPLUS_GET		0x301

#define USB_ONLINE		0
#define USB_VOLT_NOW		1
#define USB_VOLT_MAX		2
#define USB_CURR_NOW		3
#define USB_CURR_MAX		4
#define USB_IN_CURR_LIM		5

#define OPLUS_USB_SET_PPS_VOLT	29	/* APDO voltage, mV */
#define OPLUS_USB_SET_PPS_CURR	30	/* APDO current, mA */
#define OPLUS_USB_TYPE		7	/* 6 = PD, 8 = PD_PPS */
#define OPLUS_CHECK_PD_COMPLETED 131
#define OPLUS_SET_PDO		71	/* value = fixed PDO voltage, mV */

#define RX_TIMEOUT_MS		1000
#define VBUS_OK_UV		7500000	/* vendor threshold for a 9V contract */

struct lite_msg {
	__le32 owner;
	__le32 type;
	__le32 opcode;
	__le32 battery;
	__le32 property;
	__le32 value;
};

struct lite_resp {
	__le32 owner;
	__le32 type;
	__le32 opcode;
	__le32 property;
	__le32 value;
	__le32 result;
};

struct charge_boost_lite {
	struct auxiliary_device *aux;
	struct pmic_glink_client *client;

	struct mutex lock;
	struct completion resp_rcv;
	struct lite_resp resp;
	bool resp_valid;
	u32 wait_opcode;
	bool waiting;

	int base_icl_uv;	/* captured at init, restored at exit */
	bool boosted;
};

static struct charge_boost_lite *lite;

static int pdo_mv = 9000;
static int curr_uv = 3000000;
static int boost_icl_uv = 500000;
static int retry = 3;
static bool apply = true;
static int base_icl = 2000000;
static int pd_type = -1;
static int check;
static int pps_mv;
static int pps_ma = 2000;

static void lite_pdr_notify(void *priv, int state)
{
	pr_info("charge_boost_lite: pmic_glink state notify: %d\n", state);
}

static void lite_rx(const void *data, size_t len, void *priv)
{
	const struct lite_resp *r = data;

	if (len < sizeof(*r))
		return;
	if (!lite || !lite->waiting)
		return;
	if (le32_to_cpu(r->opcode) != lite->wait_opcode)
		return;

	lite->resp = *r;
	lite->resp_valid = true;
	complete(&lite->resp_rcv);
}

static int lite_xchg(u32 opcode, u32 property, u32 value, u32 *out_value)
{
	struct lite_msg msg = {
		.owner = cpu_to_le32(LITE_OWNER_BATTMGR),
		.type = cpu_to_le32(LITE_TYPE_REQ_RESP),
		.opcode = cpu_to_le32(opcode),
		.battery = cpu_to_le32(0),
		.property = cpu_to_le32(property),
		.value = cpu_to_le32(value),
	};
	unsigned long left;
	int ret;

	if (!lite || !lite->client)
		return -ENOTCONN;

	mutex_lock(&lite->lock);
	lite->waiting = true;
	lite->resp_valid = false;
	lite->wait_opcode = opcode;
	reinit_completion(&lite->resp_rcv);

	ret = pmic_glink_send(lite->client, &msg, sizeof(msg));
	if (ret) {
		lite->waiting = false;
		mutex_unlock(&lite->lock);
		return ret;
	}

	left = wait_for_completion_timeout(&lite->resp_rcv,
					   msecs_to_jiffies(RX_TIMEOUT_MS));
	lite->waiting = false;
	if (left && lite->resp_valid) {
		if (out_value)
			*out_value = le32_to_cpu(lite->resp.value);
		ret = (int)le32_to_cpu(lite->resp.result);
	} else {
		ret = -ETIMEDOUT;
	}
	mutex_unlock(&lite->lock);
	return ret;
}

static int lite_get_usb(u32 property, u32 *value)
{
	return lite_xchg(OP_USB_GET, property, 0, value);
}

static int lite_set_icl(u32 value_uv)
{
	return lite_xchg(OP_USB_SET, USB_IN_CURR_LIM, value_uv, NULL);
}

static int lite_set_pdo(u32 mv)
{
	return lite_xchg(OP_OPLUS_SET, OPLUS_SET_PDO, mv, NULL);
}

static int lite_set_pps(u32 mv, u32 ma)
{
	int r1 = lite_xchg(OP_OPLUS_SET, OPLUS_USB_SET_PPS_VOLT, mv, NULL);
	int r2 = lite_xchg(OP_OPLUS_SET, OPLUS_USB_SET_PPS_CURR, ma, NULL);

	return r1 ? r1 : r2;
}

/* refresh + log the PD detection state; result also in the pd_type param */
static int lite_detect(void)
{
	u32 type = 0, pdc = 0, vbus = 0;

	lite_xchg(OP_OPLUS_GET, OPLUS_USB_TYPE, 0, &type);
	lite_xchg(OP_OPLUS_GET, OPLUS_CHECK_PD_COMPLETED, 0, &pdc);
	lite_get_usb(USB_VOLT_NOW, &vbus);
	pd_type = (int)type;
	pr_info("charge_boost_lite: detect type=%u pd_completed=%u vbus=%u uV\n",
		type, pdc, vbus);
	return (type == 6 || type == 8) ? 0 : -ENODEV;
}

/* Walk qcom-battmgr-usb -> battmgr auxiliary device -> pmic_glink core */
static struct device *lite_find_pmic_glink_dev(void)
{
	struct power_supply *psy;
	struct device *adev, *pgdev;

	psy = power_supply_get_by_name("qcom-battmgr-usb");
	if (!psy)
		return NULL;

	adev = psy->dev.parent;
	power_supply_put(psy);

	if (!adev || !dev_is_auxiliary(adev))
		return NULL;

	pgdev = adev->parent;
	if (!pgdev || !pgdev->driver ||
	    strcmp(pgdev->driver->name, "qcom_pmic_glink"))
		return NULL;

	return pgdev;
}

/* runtime param writers: writing re-sends the request */
static int lite_pps_mv_set(const char *val, const struct kernel_param *kp)
{
	int ret, n;

	ret = kstrtoint(val, 0, &n);
	if (ret)
		return ret;
	*((int *)kp->arg) = n;

	if (n <= 0)
		return 0;
	ret = lite_set_pps(n, pps_ma);
	if (lite)
		lite->boosted = true;
	pr_info("charge_boost_lite: SET_PPS %d mV / %d mA result %d\n",
		n, pps_ma, ret);
	return 0;
}

static int lite_pps_ma_set(const char *val, const struct kernel_param *kp)
{
	int ret, n;

	ret = kstrtoint(val, 0, &n);
	if (ret)
		return ret;
	*((int *)kp->arg) = n;

	if (pps_mv <= 0)
		return 0;
	ret = lite_set_pps(pps_mv, n);
	if (lite)
		lite->boosted = true;
	pr_info("charge_boost_lite: SET_PPS %d mV / %d mA result %d\n",
		pps_mv, n, ret);
	return 0;
}

static const struct kernel_param_ops lite_pps_mv_ops = {
	.set = lite_pps_mv_set, .get = param_get_int,
};
static const struct kernel_param_ops lite_pps_ma_ops = {
	.set = lite_pps_ma_set, .get = param_get_int,
};
static int lite_pdo_mv_set(const char *val, const struct kernel_param *kp)
{
	int ret, n;

	ret = kstrtoint(val, 0, &n);
	if (ret)
		return ret;
	*((int *)kp->arg) = n;

	if (n <= 0)
		return 0;
	ret = lite_set_pdo(n);
	if (lite)
		lite->boosted = (n != 5000);
	pr_info("charge_boost_lite: SET_PDO=%d mV result %d\n", n, ret);
	return 0;
}

static int lite_curr_uv_set(const char *val, const struct kernel_param *kp)
{
	int ret, n;

	ret = kstrtoint(val, 0, &n);
	if (ret)
		return ret;
	*((int *)kp->arg) = n;

	if (n <= 0)
		return 0;
	ret = lite_set_icl(n);
	pr_info("charge_boost_lite: SET ICL=%d uA result %d\n", n, ret);
	return 0;
}

static int lite_check_set(const char *val, const struct kernel_param *kp)
{
	int ret, n;

	ret = kstrtoint(val, 0, &n);
	if (ret)
		return ret;

	lite_detect();
	return 0;
}

static const struct kernel_param_ops lite_pdo_ops = {
	.set = lite_pdo_mv_set, .get = param_get_int,
};
static const struct kernel_param_ops lite_curr_ops = {
	.set = lite_curr_uv_set, .get = param_get_int,
};
static const struct kernel_param_ops lite_check_ops = {
	.set = lite_check_set, .get = param_get_int,
};

module_param_cb(pdo_mv, &lite_pdo_ops, &pdo_mv, 0644);
MODULE_PARM_DESC(pdo_mv, "fixed PDO voltage in mV (5000/9000/12000), runtime writable");
module_param_cb(curr_uv, &lite_curr_ops, &curr_uv, 0644);
MODULE_PARM_DESC(curr_uv, "input current limit after boost, uA, runtime writable");
module_param_cb(check, &lite_check_ops, &check, 0200);
MODULE_PARM_DESC(check, "write any value to refresh + log PD detection state");
module_param(boost_icl_uv, int, 0644);
MODULE_PARM_DESC(boost_icl_uv, "input current during PDO renegotiation, uA");
module_param(retry, int, 0444);
MODULE_PARM_DESC(retry, "PDO request attempts");
module_param(apply, bool, 0644);
MODULE_PARM_DESC(apply, "run the automatic boost sequence at load");
module_param(base_icl, int, 0644);
MODULE_PARM_DESC(base_icl, "fallback restore ICL, uA");
module_param_cb(pps_mv, &lite_pps_mv_ops, &pps_mv, 0644);
MODULE_PARM_DESC(pps_mv, "PPS/APDO voltage in mV (0 = off), runtime writable; keepalive = rewrite");
module_param_cb(pps_ma, &lite_pps_ma_ops, &pps_ma, 0644);
MODULE_PARM_DESC(pps_ma, "PPS/APDO current in mA, runtime writable");
module_param(pd_type, int, 0444);
MODULE_PARM_DESC(pd_type, "last detected adapter type (6=PD, 8=PD_PPS)");

static int lite_run_sequence(void)
{
	u32 vbus = 0, base = 0;
	int ret, i;

	if (lite_detect()) {
		pr_info("charge_boost_lite: no PD contract, staying passive\n");
		return -ENODEV;
	}

	if (!lite_get_usb(USB_IN_CURR_LIM, &base) && base > 0)
		lite->base_icl_uv = (int)base;

	/* renegotiation window: low current, then request the PDO */
	lite_set_icl(boost_icl_uv);
	msleep(350);

	for (i = 0; i < retry; i++) {
		ret = lite_set_pdo(pdo_mv);
		msleep(350);
		lite_get_usb(USB_VOLT_NOW, &vbus);
		pr_info("charge_boost_lite: attempt %d: PDO=%d result %d vbus %u uV\n",
			i, pdo_mv, ret, vbus);
		if (vbus >= VBUS_OK_UV)
			break;
		msleep(650);
	}

	if (vbus >= VBUS_OK_UV) {
		lite->boosted = true;
		lite_set_icl(curr_uv);
		lite_get_usb(USB_VOLT_NOW, &vbus);
		pr_info("charge_boost_lite: BOOSTED, vbus %u uV, ICL %d uA\n",
			vbus, curr_uv);
		return 0;
	}

	/* failure: fall back to the 5 V baseline */
	pr_warn("charge_boost_lite: boost failed, restoring 5V baseline\n");
	lite_set_pdo(5000);
	lite_set_icl(lite->base_icl_uv);
	return -EIO;
}

static int __init charge_boost_lite_init(void)
{
	struct device *pgdev;
	int ret;

	if (pdo_mv != 5000 && pdo_mv != 9000 && pdo_mv != 12000)
		return -EINVAL;

	lite = kzalloc(sizeof(*lite), GFP_KERNEL);
	if (!lite)
		return -ENOMEM;
	mutex_init(&lite->lock);
	init_completion(&lite->resp_rcv);
	lite->base_icl_uv = base_icl;

	pgdev = lite_find_pmic_glink_dev();
	if (!pgdev) {
		pr_err("charge_boost_lite: pmic_glink not found (qcom-battmgr-usb?)\n");
		ret = -ENODEV;
		goto err_free;
	}

	lite->aux = auxiliary_device_create(pgdev, KBUILD_MODNAME,
					    "charge-boost-lite", NULL, 0);
	if (!lite->aux) {
		ret = -ENOMEM;
		goto err_free;
	}

	lite->client = devm_pmic_glink_client_alloc(&lite->aux->dev,
						    LITE_OWNER_BATTMGR,
						    lite_rx, lite_pdr_notify,
						    lite);
	if (IS_ERR(lite->client)) {
		ret = PTR_ERR(lite->client);
		goto err_destroy_aux;
	}
	pmic_glink_client_register(lite->client);

	pr_info("charge_boost_lite: attached to pmic_glink (%s)\n",
		dev_name(pgdev));

	if (apply)
		lite_run_sequence();

	return 0;

err_destroy_aux:
	auxiliary_device_destroy(lite->aux);
err_free:
	kfree(lite);
	lite = NULL;
	return ret;
}

static void __exit charge_boost_lite_exit(void)
{
	if (!lite)
		return;

	if (lite->boosted) {
		int ret = lite_set_pdo(5000);

		lite_set_icl(lite->base_icl_uv);
		msleep(350);
		pr_info("charge_boost_lite: restore PDO=5000 (%s), ICL=%d\n",
			ret ? "no ack" : "acked", lite->base_icl_uv);
	}

	auxiliary_device_destroy(lite->aux);
	pr_info("charge_boost_lite: unloaded\n");
	kfree(lite);
	lite = NULL;
}

module_init(charge_boost_lite_init);
module_exit(charge_boost_lite_exit);

MODULE_DESCRIPTION("USB PD fixed-PDO vbus booster for SM8850 (qcom-battmgr)");
MODULE_LICENSE("Dual MIT/GPL");
