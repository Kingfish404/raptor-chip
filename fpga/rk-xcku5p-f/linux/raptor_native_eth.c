// SPDX-License-Identifier: GPL-2.0-only
/* Native RK Ethernet packet SRAM ABI v1. All I/O is aligned 32-bit PIO.
 * No device accesses cached DDR, so no DMA/coherency contract is required.
 */
#include <linux/etherdevice.h>
#include <linux/ethtool.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/mdio-bitbang.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of_mdio.h>
#include <linux/of_net.h>
#include <linux/platform_device.h>
#include <linux/unaligned.h>
#include <linux/workqueue.h>

#define RN_ID             0x00
#define RN_VERSION        0x04
#define RN_CONTROL        0x08
#define RN_STATUS         0x0c
#define RN_IRQ_MASK       0x10
#define RN_IRQ_STATUS     0x14
#define RN_RX_DESC        0x18
#define RN_RX_POP         0x1c
#define RN_TX_LENGTH      0x20
#define RN_MDIO_CONTROL   0x40
#define RN_MDIO_INPUT     0x44
#define RN_TX_BUFFER      0x2000
#define RN_RX_BUFFER      0x4000
#define RN_SLOT_BYTES     2048
#define RN_MAX_FRAME      1536
#define RN_IRQ_RX         BIT(0)
#define RN_IRQ_TX         BIT(1)
#define RN_TX_READY       BIT(1)
#define RN_CLOCKS_READY   BIT(2)

struct rn_priv {
	struct net_device *ndev;
	void __iomem *base;
	struct napi_struct napi;
	struct mdiobb_ctrl mdio;
	struct mii_bus *mii;
	struct work_struct reset_work;
	struct mutex lifecycle;
	spinlock_t lock; /* IRQ mask, TX ownership and software statistics */
	u32 mdio_value;
	u32 irq_mask;
	unsigned int tx_length;
	bool running;
	u8 tx_buffer[RN_MAX_FRAME];
};

static u32 rn_read(struct rn_priv *p, unsigned int reg)
{
	return readl(p->base + reg);
}

static void rn_write(struct rn_priv *p, unsigned int reg, u32 value)
{
	writel(value, p->base + reg);
}

static void rn_mdio_bit(struct mdiobb_ctrl *ctrl, unsigned int bit, int value)
{
	struct rn_priv *p = container_of(ctrl, struct rn_priv, mdio);

	p->mdio_value = (p->mdio_value & ~BIT(bit)) | (!!value << bit);
	rn_write(p, RN_MDIO_CONTROL, p->mdio_value);
}

static void rn_set_mdc(struct mdiobb_ctrl *ctrl, int value)
{
	rn_mdio_bit(ctrl, 0, value);
}

static void rn_set_mdio_dir(struct mdiobb_ctrl *ctrl, int value)
{
	rn_mdio_bit(ctrl, 1, value);
}

static void rn_set_mdio_data(struct mdiobb_ctrl *ctrl, int value)
{
	rn_mdio_bit(ctrl, 2, value);
}

static int rn_get_mdio_data(struct mdiobb_ctrl *ctrl)
{
	struct rn_priv *p = container_of(ctrl, struct rn_priv, mdio);

	return rn_read(p, RN_MDIO_INPUT) & 1;
}

static const struct mdiobb_ops rn_mdio_ops = {
	.owner = THIS_MODULE,
	.set_mdc = rn_set_mdc,
	.set_mdio_dir = rn_set_mdio_dir,
	.set_mdio_data = rn_set_mdio_data,
	.get_mdio_data = rn_get_mdio_data,
};

static int rn_poll(struct napi_struct *napi, int budget)
{
	struct rn_priv *p = container_of(napi, struct rn_priv, napi);
	struct net_device *ndev = p->ndev;
	unsigned long flags;
	int done = 0;

	while (done < budget) {
		u32 desc = rn_read(p, RN_RX_DESC);
		unsigned int len = desc & 0xffff;
		unsigned int offset = RN_RX_BUFFER + ((desc >> 16) & 7) * RN_SLOT_BYTES;
		struct sk_buff *skb;
		u8 *data;
		unsigned int i;

		if (!len)
			break;
		if (unlikely(len < ETH_ZLEN || len > RN_MAX_FRAME)) {
			spin_lock_irqsave(&p->lock, flags);
			ndev->stats.rx_errors++;
			spin_unlock_irqrestore(&p->lock, flags);
			rn_write(p, RN_RX_POP, 1);
			done++;
			continue;
		}
		skb = napi_alloc_skb(napi, len);
		if (!skb) {
			spin_lock_irqsave(&p->lock, flags);
			ndev->stats.rx_dropped++;
			spin_unlock_irqrestore(&p->lock, flags);
			rn_write(p, RN_RX_POP, 1);
			done++;
			continue;
		}
		data = skb_put(skb, len);
		/* The descriptor owns an immutable SRAM slot until RX_POP. Batch
		 * payload accesses; fencing every word needlessly serializes the CPU.
		 * Keep the ordered descriptor read and fence the ownership handoff.
		 */
		for (i = 0; i + 4 <= len; i += 4)
			put_unaligned_le32(readl_relaxed(p->base + offset + i), data + i);
		if (i < len) {
			u32 tail = readl_relaxed(p->base + offset + i);

			for (; i < len; i++, tail >>= 8)
				data[i] = tail;
		}
		/* Complete all SRAM reads and skb writes before releasing the slot. */
		mb();
		rn_write(p, RN_RX_POP, 1);
		skb->protocol = eth_type_trans(skb, ndev);
		spin_lock_irqsave(&p->lock, flags);
		ndev->stats.rx_packets++;
		ndev->stats.rx_bytes += len;
		spin_unlock_irqrestore(&p->lock, flags);
		napi_gro_receive(napi, skb);
		done++;
	}
	if (done < budget && napi_complete_done(napi, done)) {
		spin_lock_irqsave(&p->lock, flags);
		p->irq_mask |= RN_IRQ_RX;
		rn_write(p, RN_IRQ_MASK, p->irq_mask);
		/* RX is level triggered: a packet arriving during completion
		 * immediately raises the interrupt after unmasking.
		 */
		spin_unlock_irqrestore(&p->lock, flags);
	}
	return done;
}

static irqreturn_t rn_irq(int irq, void *opaque)
{
	struct net_device *ndev = opaque;
	struct rn_priv *p = netdev_priv(ndev);
	u32 status;

	spin_lock(&p->lock);
	status = rn_read(p, RN_IRQ_STATUS) & p->irq_mask;
	if (!status) {
		spin_unlock(&p->lock);
		return IRQ_NONE;
	}
	if (status & RN_IRQ_TX) {
		rn_write(p, RN_IRQ_STATUS, RN_IRQ_TX);
		if (p->tx_length) {
			ndev->stats.tx_packets++;
			ndev->stats.tx_bytes += p->tx_length;
			p->tx_length = 0;
			netif_wake_queue(ndev);
		}
	}
	if ((status & RN_IRQ_RX) && napi_schedule_prep(&p->napi)) {
		p->irq_mask &= ~RN_IRQ_RX;
		rn_write(p, RN_IRQ_MASK, p->irq_mask);
		__napi_schedule(&p->napi);
	}
	spin_unlock(&p->lock);
	return IRQ_HANDLED;
}

static netdev_tx_t rn_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct rn_priv *p = netdev_priv(ndev);
	unsigned long flags;
	unsigned int i, len = skb->len;

	if (unlikely(len < ETH_HLEN || len > RN_MAX_FRAME ||
		     skb_copy_bits(skb, 0, p->tx_buffer, len))) {
		spin_lock_irqsave(&p->lock, flags);
		ndev->stats.tx_dropped++;
		spin_unlock_irqrestore(&p->lock, flags);
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}
	spin_lock_irqsave(&p->lock, flags);
	if (unlikely(p->tx_length ||
		     (rn_read(p, RN_STATUS) & (RN_TX_READY | RN_CLOCKS_READY)) !=
		     (RN_TX_READY | RN_CLOCKS_READY))) {
		netif_stop_queue(ndev);
		spin_unlock_irqrestore(&p->lock, flags);
		schedule_work(&p->reset_work);
		return NETDEV_TX_BUSY;
	}
	netif_stop_queue(ndev);
	p->tx_length = len;
	spin_unlock_irqrestore(&p->lock, flags);
	for (i = 0; i + 4 <= len; i += 4)
		writel_relaxed(get_unaligned_le32(p->tx_buffer + i),
			       p->base + RN_TX_BUFFER + i);
	if (i < len) {
		u32 tail = 0;
		unsigned int b;

		for (b = 0; i + b < len; b++)
			tail |= (u32)p->tx_buffer[i + b] << (8 * b);
		writel_relaxed(tail, p->base + RN_TX_BUFFER + i);
	}
	netif_trans_update(ndev);
	/* Order the complete batch of SRAM writes before giving it to the MAC. */
	mb();
	rn_write(p, RN_TX_LENGTH, len);
	dev_kfree_skb_any(skb);
	return NETDEV_TX_OK;
}

static void rn_quiesce(struct rn_priv *p)
{
	unsigned long flags;

	netif_tx_disable(p->ndev);
	disable_irq(p->ndev->irq);
	napi_disable(&p->napi);
	spin_lock_irqsave(&p->lock, flags);
	p->irq_mask = 0;
	rn_write(p, RN_IRQ_MASK, 0);
	rn_write(p, RN_CONTROL, 0);
	if (p->tx_length) {
		p->ndev->stats.tx_errors++;
		p->ndev->stats.tx_dropped++;
		p->tx_length = 0;
	}
	spin_unlock_irqrestore(&p->lock, flags);
}

static void rn_start(struct rn_priv *p)
{
	rn_write(p, RN_CONTROL, 1);
	rn_write(p, RN_IRQ_STATUS, RN_IRQ_TX);
	napi_enable(&p->napi);
	p->irq_mask = RN_IRQ_RX | RN_IRQ_TX;
	rn_write(p, RN_IRQ_MASK, p->irq_mask);
	enable_irq(p->ndev->irq);
	netif_wake_queue(p->ndev);
}

static void rn_reset_work(struct work_struct *work)
{
	struct rn_priv *p = container_of(work, struct rn_priv, reset_work);

	mutex_lock(&p->lifecycle);
	if (p->running) {
		netdev_warn(p->ndev, "resetting stalled packet queue\n");
		rn_quiesce(p);
		rn_start(p);
	}
	mutex_unlock(&p->lifecycle);
}

static void rn_tx_timeout(struct net_device *ndev, unsigned int queue)
{
	struct rn_priv *p = netdev_priv(ndev);

	schedule_work(&p->reset_work);
}

static void rn_adjust_link(struct net_device *ndev)
{
	struct rn_priv *p = netdev_priv(ndev);
	struct phy_device *phy = ndev->phydev;
	u32 status;
	int ret;

	if (phy->link) {
		ret = readl_poll_timeout(p->base + RN_STATUS, status,
					status & RN_CLOCKS_READY, 1000, 100000);
		if (ret || phy->speed != SPEED_1000 || phy->duplex != DUPLEX_FULL) {
			netif_carrier_off(ndev);
			netdev_err(ndev, "gigabit RX clock/link unavailable (status %#x)\n", status);
		}
	}
	phy_print_status(phy);
}

static int rn_open(struct net_device *ndev)
{
	struct rn_priv *p = netdev_priv(ndev);

	mutex_lock(&p->lifecycle);
	p->running = true;
	rn_start(p);
	/* Start PHY negotiation before requiring RX MMCM lock: the PHY can
	 * supply a different RX frequency until it negotiates gigabit mode.
	 */
	phy_start(ndev->phydev);
	mutex_unlock(&p->lifecycle);
	return 0;
}

static int rn_stop(struct net_device *ndev)
{
	struct rn_priv *p = netdev_priv(ndev);

	mutex_lock(&p->lifecycle);
	p->running = false;
	phy_stop(ndev->phydev);
	rn_quiesce(p);
	mutex_unlock(&p->lifecycle);
	cancel_work_sync(&p->reset_work);
	return 0;
}

static void rn_get_stats64(struct net_device *ndev, struct rtnl_link_stats64 *stats)
{
	struct rn_priv *p = netdev_priv(ndev);
	unsigned long flags;

	spin_lock_irqsave(&p->lock, flags);
	netdev_stats_to_stats64(stats, &ndev->stats);
	spin_unlock_irqrestore(&p->lock, flags);
}

static const struct net_device_ops rn_netdev_ops = {
	.ndo_open = rn_open,
	.ndo_stop = rn_stop,
	.ndo_start_xmit = rn_xmit,
	.ndo_tx_timeout = rn_tx_timeout,
	.ndo_get_stats64 = rn_get_stats64,
	.ndo_eth_ioctl = phy_do_ioctl_running,
	.ndo_set_mac_address = eth_mac_addr,
	.ndo_validate_addr = eth_validate_addr,
};

/* Raw hardware counters reset when the MAC is stopped or its clocks fail. */
static const char rn_stat_names[][ETH_GSTRING_LEN] = {
	"hw_rx_good", "hw_rx_errors", "hw_rx_overflow", "hw_tx_complete",
	"hw_tx_rejected", "hw_rx_bad_fcs",
};

static int rn_get_sset_count(struct net_device *ndev, int set)
{
	return set == ETH_SS_STATS ? ARRAY_SIZE(rn_stat_names) : -EOPNOTSUPP;
}

static void rn_get_strings(struct net_device *ndev, u32 set, u8 *data)
{
	if (set == ETH_SS_STATS)
		memcpy(data, rn_stat_names, sizeof(rn_stat_names));
}

static void rn_get_ethtool_stats(struct net_device *ndev,
				 struct ethtool_stats *stats, u64 *values)
{
	struct rn_priv *p = netdev_priv(ndev);
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(rn_stat_names); i++)
		values[i] = rn_read(p, 0x28 + i * 4);
}

static const struct ethtool_ops rn_ethtool_ops = {
	.get_link = ethtool_op_get_link,
	.get_link_ksettings = phy_ethtool_get_link_ksettings,
	.set_link_ksettings = phy_ethtool_set_link_ksettings,
	.get_ts_info = ethtool_op_get_ts_info,
	.get_sset_count = rn_get_sset_count,
	.get_strings = rn_get_strings,
	.get_ethtool_stats = rn_get_ethtool_stats,
};

static int rn_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *mdio_node, *phy_node;
	struct net_device *ndev;
	struct rn_priv *p;
	phy_interface_t interface;
	int ret;

	ndev = devm_alloc_etherdev(dev, sizeof(*p));
	if (!ndev)
		return -ENOMEM;
	SET_NETDEV_DEV(ndev, dev);
	p = netdev_priv(ndev);
	p->ndev = ndev;
	spin_lock_init(&p->lock);
	mutex_init(&p->lifecycle);
	INIT_WORK(&p->reset_work, rn_reset_work);
	p->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(p->base))
		return PTR_ERR(p->base);
	if (rn_read(p, RN_ID) != 0x524e4554 || rn_read(p, RN_VERSION) != 1)
		return dev_err_probe(dev, -ENODEV, "native Ethernet ABI mismatch\n");
	rn_write(p, RN_IRQ_MASK, 0);
	rn_write(p, RN_CONTROL, 0);
	rn_write(p, RN_MDIO_CONTROL, 0);
	ndev->irq = platform_get_irq(pdev, 0);
	if (ndev->irq < 0)
		return ndev->irq;
	ret = of_get_phy_mode(dev->of_node, &interface);
	if (ret || interface != PHY_INTERFACE_MODE_RGMII_TXID)
		return dev_err_probe(dev, -EINVAL, "requires rgmii-txid PHY mode\n");
	ret = of_get_ethdev_address(dev->of_node, ndev);
	if (ret == -EPROBE_DEFER)
		return ret;
	if (ret)
		eth_hw_addr_random(ndev);
	p->mdio.ops = &rn_mdio_ops;
	p->mii = alloc_mdio_bitbang(&p->mdio);
	if (!p->mii)
		return -ENOMEM;
	p->mii->name = "Raptor native MDIO";
	p->mii->parent = dev;
	snprintf(p->mii->id, MII_BUS_ID_SIZE, "%s-mii", dev_name(dev));
	mdio_node = of_get_child_by_name(dev->of_node, "mdio");
	if (!mdio_node) {
		ret = -EINVAL;
		goto free_mii;
	}
	ret = of_mdiobus_register(p->mii, mdio_node);
	of_node_put(mdio_node);
	if (ret) {
		dev_err_probe(dev, ret, "cannot register native MDIO bus\n");
		goto free_mii;
	}
	phy_node = of_parse_phandle(dev->of_node, "phy-handle", 0);
	ndev->phydev = of_phy_connect(ndev, phy_node, rn_adjust_link, 0, interface);
	of_node_put(phy_node);
	if (!ndev->phydev) {
		ret = -ENODEV;
		goto unregister_mii;
	}
	phy_set_max_speed(ndev->phydev, SPEED_1000);
	phy_remove_link_mode(ndev->phydev, ETHTOOL_LINK_MODE_10baseT_Half_BIT);
	phy_remove_link_mode(ndev->phydev, ETHTOOL_LINK_MODE_10baseT_Full_BIT);
	phy_remove_link_mode(ndev->phydev, ETHTOOL_LINK_MODE_100baseT_Half_BIT);
	phy_remove_link_mode(ndev->phydev, ETHTOOL_LINK_MODE_100baseT_Full_BIT);
	phy_remove_link_mode(ndev->phydev, ETHTOOL_LINK_MODE_1000baseT_Half_BIT);
	phy_remove_link_mode(ndev->phydev, ETHTOOL_LINK_MODE_Pause_BIT);
	phy_remove_link_mode(ndev->phydev, ETHTOOL_LINK_MODE_Asym_Pause_BIT);
	ndev->netdev_ops = &rn_netdev_ops;
	ndev->ethtool_ops = &rn_ethtool_ops;
	ndev->watchdog_timeo = 5 * HZ;
	ndev->min_mtu = ETH_MIN_MTU;
	ndev->max_mtu = ETH_DATA_LEN;
	netif_carrier_off(ndev);
	netif_napi_add(ndev, &p->napi, rn_poll);
	ret = devm_request_irq(dev, ndev->irq, rn_irq, IRQF_NO_AUTOEN, dev_name(dev), ndev);
	if (ret)
		goto delete_napi;
	ret = register_netdev(ndev);
	if (ret)
		goto delete_napi;
	platform_set_drvdata(pdev, ndev);
	dev_info(dev, "native packet SRAM Ethernet, %pM, 1000baseT full duplex\n", ndev->dev_addr);
	return 0;

delete_napi:
	netif_napi_del(&p->napi);
	phy_disconnect(ndev->phydev);
unregister_mii:
	mdiobus_unregister(p->mii);
free_mii:
	free_mdio_bitbang(p->mii);
	return ret;
}

static void rn_remove(struct platform_device *pdev)
{
	struct net_device *ndev = platform_get_drvdata(pdev);
	struct rn_priv *p = netdev_priv(ndev);

	unregister_netdev(ndev);
	cancel_work_sync(&p->reset_work);
	netif_napi_del(&p->napi);
	phy_disconnect(ndev->phydev);
	mdiobus_unregister(p->mii);
	free_mdio_bitbang(p->mii);
}

static const struct of_device_id rn_of_match[] = {
	{ .compatible = "raptor,native-ethernet-v1" },
	{ }
};
MODULE_DEVICE_TABLE(of, rn_of_match);

static struct platform_driver rn_driver = {
	.probe = rn_probe,
	.remove = rn_remove,
	.driver = {
		.name = "raptor-native-eth",
		.of_match_table = rn_of_match,
	},
};
module_platform_driver(rn_driver);

MODULE_DESCRIPTION("Raptor native Ethernet packet SRAM driver");
MODULE_LICENSE("GPL");
