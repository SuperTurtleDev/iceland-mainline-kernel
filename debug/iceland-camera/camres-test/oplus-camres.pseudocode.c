// SPDX-License-Identifier: GPL-2.0-only
/*
 * oplus-camres — Camera shared I2C bus resource manager
 *
 * Exposes a Linux I2C adapter for the shared camera bus (QUP wrap2 SE1).
 * When no consumer holds the bus (refcount 0), pins go high-Z and QUP
 * clocks gate off so the SEE (ADSP) can drive the same physical bus.
 * Transfers attempted while SEE holds the bus return -EBUSY.
 *
 * sysfs:
 *   /sys/bus/platform/devices/.../force_ap   — write 1 to force AP takeover
 *   /sys/bus/platform/devices/.../ap_holds   — read current ownership
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/i2c-algo-bit.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pinctrl/consumer.h>
#include <linux/workqueue.h>
#include <linux/io.h>
#include <linux/oplus-camres.h>

/* QUP SE registers (from kaanapali.dtsi i2c9@884000) */
#define QUP_SE_BASE		0x00884000
#define QUP_SE_SIZE		0x1000

/* GENI SE registers */
#define GENI_SE_IRQ_EN		0x0620
#define GENI_IRQ_CLR		0x0618
#define SE_GENI_STATUS		0x0064
#define SE_GENI_CFG_REG0	0x0100
#define SE_GENI_CLK_SEL		0x0084
#define SE_GENI_FW_REVISION	0x010c

/* GENI I2C registers */
#define SE_I2C_TX_TRANS_LEN	0x026c
#define SE_I2C_RX_TRANS_LEN	0x0270
#define SE_I2C_DEV_ID		0x0060
#define SE_I2C_SCL_COUNTERS	0x0268

/* M_CMD / M_TX / M_RX */
#define SE_GENI_M_CMD0		0x0210
#define SE_GENI_M_CMD_CTRL_RT	0x0214
#define SE_GENI_M_IRQ_STATUS	0x0218
#define SE_GENI_M_IRQ_EN	0x021c
#define SE_GENI_M_TX0_FIFOn	0x0260
#define SE_GENI_M_RX0_FIFOn	0x0280
#define SE_GENI_M_RX_FIFO_STATUS 0x0288
#define SE_GENI_M_TX_FIFO_STATUS 0x0278

/* I2C commands */
#define I2C_WRITE		0x1
#define I2C_READ		0x2

/* M_IRQ bits */
#define M_TX_FIFO_WATERMARK	BIT(30)
#define M_RX_FIFO_LAST		BIT(31)
#define M_CMD_DONE		BIT(0)
#define M_CMD_ABORT		BIT(1)
#define M_CMD_NACK		BIT(2)
#define M_ILLEGAL_CMD		BIT(3)
#define M_TX_FIFO_RD_ERR	BIT(5)
#define M_RX_FIFO_WR_ERR	BIT(7)
#define M_GP_IRQ_1		BIT(9)	/* NACK from slave */

/* Timeout */
#define XFER_TIMEOUT_MS		250

struct oplus_camres {
	struct device *dev;
	struct clk *core_clk;
	struct clk *se_clk;
	struct pinctrl *pinctrl;
	struct pinctrl_state *p_active;
	struct pinctrl_state *p_released;

	void __iomem *se_base;
	int irq;

	atomic_t refcount;
	struct mutex lock;
	struct delayed_work release_work;
	struct i2c_adapter adapter;
	struct completion xfer_done;
	u32 xfer_result;
	bool force_ap;
};

static struct oplus_camres *g_camres;

/* ===== Low-level QUP SE I2C (direct register access) ===== */

static inline void se_writel(struct oplus_camres *cr, u32 val, u32 reg)
{
	writel(val, cr->se_base + reg);
}

static inline u32 se_readl(struct oplus_camres *cr, u32 reg)
{
	return readl(cr->se_base + reg);
}

static irqreturn_t camres_irq(int irq, void *devid)
{
	struct oplus_camres *cr = devid;
	u32 m_irq = se_readl(cr, SE_GENI_M_IRQ_STATUS);

	se_writel(cr, m_irq, SE_GENI_M_IRQ_STATUS); /* W1C */
	se_writel(cr, 0xffffffff, GENI_IRQ_CLR);

	cr->xfer_result = m_irq;
	complete(&cr->xfer_done);

	return IRQ_HANDLED;
}

static int camres_qup_wait_xfer(struct oplus_camres *cr)
{
	unsigned long timeout = msecs_to_jiffies(XFER_TIMEOUT_MS);

	if (!wait_for_completion_timeout(&cr->xfer_done, timeout)) {
		dev_err(cr->dev, "QUP transfer timeout\n");
		return -ETIMEDOUT;
	}

	if (cr->xfer_result & (M_CMD_NACK | M_GP_IRQ_1)) {
		dev_dbg(cr->dev, "QUP NACK (status=0x%x)\n", cr->xfer_result);
		return -ENXIO;
	}

	if (cr->xfer_result & (M_CMD_ABORT | M_ILLEGAL_CMD |
				M_TX_FIFO_RD_ERR | M_RX_FIFO_WR_ERR)) {
		dev_err(cr->dev, "QUP error (status=0x%x)\n", cr->xfer_result);
		return -EIO;
	}

	return 0;
}

static int camres_qup_xfer_msg(struct oplus_camres *cr,
			       struct i2c_msg *msg)
{
	u32 cmd, len;
	int i, ret;

	reinit_completion(&cr->xfer_done);

	se_writel(cr, 0xffffffff, SE_GENI_M_IRQ_STATUS);
	se_writel(cr, M_CMD_DONE | M_CMD_ABORT | M_CMD_NACK | M_GP_IRQ_1 |
			 M_TX_FIFO_RD_ERR | M_RX_FIFO_WR_ERR,
			 SE_GENI_M_IRQ_EN);

	if (msg->flags & I2C_M_RD) {
		/* Read */
		len = msg->len;
		se_writel(cr, len, SE_I2C_RX_TRANS_LEN);
		/* Write slave address first */
		se_writel(cr, (msg->addr << 1) | 1, SE_GENI_M_TX0_FIFOn);
		cmd = I2C_READ;
	} else {
		/* Write */
		len = msg->len;
		se_writel(cr, len + 1, SE_I2C_TX_TRANS_LEN);
		se_writel(cr, (msg->addr << 1), SE_GENI_M_TX0_FIFOn);
		cmd = I2C_WRITE;

		for (i = 0; i < len; i++)
			se_writel(cr, msg->buf[i], SE_GENI_M_TX0_FIFOn);
	}

	/* Issue command */
	se_writel(cr, cmd, SE_GENI_M_CMD0);

	ret = camres_qup_wait_xfer(cr);
	if (ret)
		return ret;

	/* Read received data */
	if (msg->flags & I2C_M_RD) {
		u32 fifo_status = se_readl(cr, SE_GENI_M_RX_FIFO_STATUS);
		int rx_count = (fifo_status >> 16) & 0x1ff;

		for (i = 0; i < min_t(int, rx_count, msg->len); i++) {
			u32 val = se_readl(cr, SE_GENI_M_RX0_FIFOn);
			msg->buf[i] = val & 0xff;
		}
	}

	return 0;
}

static int camres_i2c_xfer(struct i2c_adapter *adap,
			   struct i2c_msg *msgs, int num)
{
	struct oplus_camres *cr = i2c_get_adapdata(adap);
	int i, ret;

	if (!atomic_read(&cr->refcount) && !cr->force_ap)
		return -EBUSY;

	for (i = 0; i < num; i++) {
		ret = camres_qup_xfer_msg(cr, &msgs[i]);
		if (ret)
			return ret;
	}

	return num;
}

static u32 camres_i2c_func(struct i2c_adapter *adap)
{
	return I2C_FUNC_I2C | I2C_FUNC_SMBUS_EMUL;
}

static const struct i2c_algorithm camres_i2c_algo = {
	.xfer = camres_i2c_xfer,
	.functionality = camres_i2c_func,
};

/* ===== Bus ownership management ===== */

static void oplus_camres_release_work(struct work_struct *work)
{
	struct oplus_camres *cr = container_of(to_delayed_work(work),
						struct oplus_camres,
						release_work);

	mutex_lock(&cr->lock);

	if (atomic_read(&cr->refcount) == 0 && !cr->force_ap) {
		dev_info(cr->dev, "releasing camera bus to SEE\n");
		clk_disable_unprepare(cr->se_clk);
		clk_disable_unprepare(cr->core_clk);
		pinctrl_select_state(cr->pinctrl, cr->p_released);
	}

	mutex_unlock(&cr->lock);
}

static int camres_ap_takeover(struct oplus_camres *cr)
{
	int ret;

	dev_info(cr->dev, "AP acquiring camera bus\n");

	ret = pinctrl_select_state(cr->pinctrl, cr->p_active);
	if (ret) {
		dev_err(cr->dev, "pinctrl active failed: %d\n", ret);
		return ret;
	}

	ret = clk_prepare_enable(cr->core_clk);
	if (ret) {
		dev_err(cr->dev, "core clk failed: %d\n", ret);
		goto err_pinctrl;
	}

	ret = clk_prepare_enable(cr->se_clk);
	if (ret) {
		dev_err(cr->dev, "se clk failed: %d\n", ret);
		goto err_core;
	}

	usleep_range(1000, 1500);
	return 0;

err_core:
	clk_disable_unprepare(cr->core_clk);
err_pinctrl:
	pinctrl_select_state(cr->pinctrl, cr->p_released);
	return ret;
}

/* ===== Public API ===== */

int oplus_camres_acquire(struct device *consumer)
{
	struct oplus_camres *cr = g_camres;
	int ret = 0;

	if (!cr)
		return -EPROBE_DEFER;

	mutex_lock(&cr->lock);

	if (atomic_read(&cr->refcount) == 0 && !cr->force_ap) {
		ret = camres_ap_takeover(cr);
		if (ret)
			goto out;
	}

	atomic_inc(&cr->refcount);

out:
	mutex_unlock(&cr->lock);
	return ret;
}
EXPORT_SYMBOL_GPL(oplus_camres_acquire);

int oplus_camres_release(struct device *consumer)
{
	struct oplus_camres *cr = g_camres;

	if (!cr)
		return -ENODEV;

	if (atomic_dec_if_positive(&cr->refcount) == 0)
		schedule_delayed_work(&cr->release_work,
				      msecs_to_jiffies(500));

	return 0;
}
EXPORT_SYMBOL_GPL(oplus_camres_release);

bool oplus_camres_ap_holds(void)
{
	return g_camres && (atomic_read(&g_camres->refcount) > 0 ||
			     g_camres->force_ap);
}
EXPORT_SYMBOL_GPL(oplus_camres_ap_holds);

/* ===== sysfs ===== */

static ssize_t force_ap_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct oplus_camres *cr = dev_get_drvdata(dev);
	return sprintf(buf, "%d\n", cr->force_ap ? 1 : 0);
}

static ssize_t force_ap_store(struct device *dev,
			       struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct oplus_camres *cr = dev_get_drvdata(dev);
	unsigned long val;
	int ret;

	ret = kstrtoul(buf, 10, &val);
	if (ret)
		return ret;

	mutex_lock(&cr->lock);

	if (val && !cr->force_ap) {
		/* Force AP takeover */
		if (atomic_read(&cr->refcount) == 0) {
			ret = camres_ap_takeover(cr);
			if (ret) {
				mutex_unlock(&cr->lock);
				return ret;
			}
		}
		cr->force_ap = true;
		dev_info(dev, "forced AP takeover\n");
	} else if (!val && cr->force_ap) {
		/* Release force, schedule normal release */
		cr->force_ap = false;
		if (atomic_read(&cr->refcount) == 0)
			schedule_delayed_work(&cr->release_work,
					      msecs_to_jiffies(500));
		dev_info(dev, "released force, bus may return to SEE\n");
	}

	mutex_unlock(&cr->lock);
	return count;
}
static DEVICE_ATTR_RW(force_ap);

static ssize_t ap_holds_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct oplus_camres *cr = dev_get_drvdata(dev);
	return sprintf(buf, "%d\n", oplus_camres_ap_holds() ? 1 : 0);
}
static DEVICE_ATTR_RO(ap_holds);

static struct attribute *camres_attrs[] = {
	&dev_attr_force_ap.attr,
	&dev_attr_ap_holds.attr,
	NULL,
};
ATTRIBUTE_GROUPS(camres);

/* ===== Platform driver ===== */

static int oplus_camres_probe(struct platform_device *pdev)
{
	struct oplus_camres *cr;
	struct resource *res;
	int ret;

	cr = devm_kzalloc(&pdev->dev, sizeof(*cr), GFP_KERNEL);
	if (!cr)
		return -ENOMEM;

	cr->dev = &pdev->dev;
	platform_set_drvdata(pdev, cr);
	mutex_init(&cr->lock);
	atomic_set(&cr->refcount, 0);
	init_completion(&cr->xfer_done);
	INIT_DELAYED_WORK(&cr->release_work, oplus_camres_release_work);

	cr->core_clk = devm_clk_get(&pdev->dev, "core");
	if (IS_ERR(cr->core_clk))
		return dev_err_probe(&pdev->dev, PTR_ERR(cr->core_clk),
				     "failed to get core clock\n");

	cr->se_clk = devm_clk_get(&pdev->dev, "se");
	if (IS_ERR(cr->se_clk))
		return dev_err_probe(&pdev->dev, PTR_ERR(cr->se_clk),
				     "failed to get se clock\n");

	cr->pinctrl = devm_pinctrl_get(&pdev->dev);
	if (IS_ERR(cr->pinctrl))
		return dev_err_probe(&pdev->dev, PTR_ERR(cr->pinctrl),
				     "failed to get pinctrl\n");

	cr->p_active = pinctrl_lookup_state(cr->pinctrl, "active");
	if (IS_ERR(cr->p_active))
		return dev_err_probe(&pdev->dev, PTR_ERR(cr->p_active),
				     "failed to get active pinctrl state\n");

	cr->p_released = pinctrl_lookup_state(cr->pinctrl, "released");
	if (IS_ERR(cr->p_released))
		return dev_err_probe(&pdev->dev, PTR_ERR(cr->p_released),
				     "failed to get released pinctrl state\n");

	/* Map QUP SE registers */
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	cr->se_base = devm_ioremap_resource(&pdev->dev, res);
	if (IS_ERR(cr->se_base))
		return dev_err_probe(&pdev->dev, PTR_ERR(cr->se_base),
				     "failed to map QUP SE registers\n");

	cr->irq = platform_get_irq(pdev, 0);
	if (cr->irq < 0)
		return cr->irq;

	ret = devm_request_irq(&pdev->dev, cr->irq, camres_irq, 0,
			       "oplus-camres", cr);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "failed to request IRQ\n");

	/* Register I2C adapter */
	cr->adapter.owner = THIS_MODULE;
	cr->adapter.class = I2C_CLASS_DEPRECATED;
	cr->adapter.algo = &camres_i2c_algo;
	cr->adapter.dev.parent = &pdev->dev;
	cr->adapter.dev.of_node = pdev->dev.of_node;
	strscpy(cr->adapter.name, "oplus-camres-i2c",
		sizeof(cr->adapter.name));
	i2c_set_adapdata(&cr->adapter, cr);

	ret = i2c_add_adapter(&cr->adapter);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "failed to add I2C adapter\n");

	/*
	 * Boot-time default: bus belongs to SEE.
	 * Pins in high-Z, QUP clocks gated.
	 */
	pinctrl_select_state(cr->pinctrl, cr->p_released);

	g_camres = cr;
	dev_info(&pdev->dev, "camera bus I2C adapter registered (bus %d), released to SEE\n",
		 cr->adapter.nr);

	return 0;
}

static void oplus_camres_remove(struct platform_device *pdev)
{
	struct oplus_camres *cr = platform_get_drvdata(pdev);

	cancel_delayed_work_sync(&cr->release_work);
	i2c_del_adapter(&cr->adapter);
	g_camres = NULL;
}

static const struct of_device_id oplus_camres_of_match[] = {
	{ .compatible = "oplus,camres" },
	{ }
};
MODULE_DEVICE_TABLE(of, oplus_camres_of_match);

static struct platform_driver oplus_camres_driver = {
	.probe = oplus_camres_probe,
	.remove = oplus_camres_remove,
	.driver = {
		.name = "oplus-camres",
		.of_match_table = oplus_camres_of_match,
		.dev_groups = camres_groups,
	},
};
module_platform_driver(oplus_camres_driver);

MODULE_AUTHOR("Iceland mainline");
MODULE_DESCRIPTION("OPlus camera shared I2C bus with SEE ownership management");
MODULE_LICENSE("GPL");
