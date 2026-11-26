// SPDX-License-Identifier: GPL-2.0-only
/* Raptor Ethernet driver supporting both:
 * - ABI v1: 32-bit packet SRAM PIO (no DMA required)
 * - ABI v2: 64-bit AXI4-Master RX/TX Ring DMA (uses standard Linux DMA API;
 *           set dma-noncoherent in DT when the SoC relies on Zicbom CMO)
 */
#include <linux/dma-mapping.h>
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
#define RN_DMA_CAPS       0x48
#define RN_RX_ADDR_LO     0x80
#define RN_RX_ADDR_HI     0x84
#define RN_RX_PUSH        0x88
#define RN_RX_COMP        0x8c
#define RN_TX_ADDR_LO     0xa0
#define RN_TX_ADDR_HI     0xa4
#define RN_TX_PUSH        0xa8
#define RN_TX_COMP        0xac
#define RN_TX_BUFFER      0x2000
#define RN_RX_BUFFER      0x4000
#define RN_SLOT_BYTES     2048
#define RN_MAX_FRAME      1536
#define RN_DMA_MAX_RING   64
#define RN_DMA_BUF_SIZE   2048
#define RN_RING_CAP       0x48
#define RN_CTRL_ENABLE    BIT(0)
#define RN_CTRL_DMA       BIT(1)
#define RN_IRQ_RX         BIT(0)
#define RN_IRQ_TX         BIT(1)
#define RN_TX_READY       BIT(1)
#define RN_CLOCKS_READY   BIT(2)

struct rn_priv {
	struct net_device *ndev;
	struct device *dev;
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
	bool dma_mode;
	unsigned int ring_size;
	unsigned int ring_mask;
	size_t pool_bytes;
	unsigned int rx_prod;
	unsigned int rx_cons;
	unsigned int tx_prod;
	unsigned int tx_cons;
	u8 *rx_pool;
	dma_addr_t rx_pool_dma;
	u8 *tx_pool;
	dma_addr_t tx_pool_dma;
	unsigned int tx_len[RN_DMA_MAX_RING];
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

static void rn_dma_refill_rx(struct rn_priv *p)
{
	while (p->rx_prod - p->rx_cons < p->ring_size - 1) {
		unsigned int idx = p->rx_prod & p->ring_mask;
		dma_addr_t dma = p->rx_pool_dma + idx * RN_DMA_BUF_SIZE;

		rn_write(p, RN_RX_ADDR_LO, lower_32_bits(dma));
		rn_write(p, RN_RX_ADDR_HI, upper_32_bits(dma));
		rn_write(p, RN_RX_PUSH, 1);
		p->rx_prod++;
	}
}

static void rn_dma_reclaim_tx(struct rn_priv *p)
{
	u32 comp = rn_read(p, RN_TX_COMP);
	unsigned int i;

	if (!comp)
		return;
	if (comp > p->tx_prod - p->tx_cons)
		comp = p->tx_prod - p->tx_cons;
	for (i = 0; i < comp; i++) {
		unsigned int idx = p->tx_cons & p->ring_mask;

		p->ndev->stats.tx_packets++;
		p->ndev->stats.tx_bytes += p->tx_len[idx];
		p->tx_len[idx] = 0;
		p->tx_cons++;
	}
	rn_write(p, RN_TX_COMP, comp);
	if (p->tx_prod - p->tx_cons < p->ring_size - 1) {
		if (p->irq_mask & RN_IRQ_TX) {
			p->irq_mask &= ~RN_IRQ_TX;
			rn_write(p, RN_IRQ_MASK, p->irq_mask);
		}
		netif_wake_queue(p->ndev);
	}
}

static void rn_dma_reset_rings(struct rn_priv *p)
{
	p->rx_prod = 0;
	p->rx_cons = 0;
	p->tx_prod = 0;
	p->tx_cons = 0;
}

static int rn_dma_poll(struct napi_struct *napi, int budget)
{
	struct rn_priv *p = container_of(napi, struct rn_priv, napi);
	struct net_device *ndev = p->ndev;
	unsigned long flags;
	int done = 0;

	while (done < budget) {
		u32 len = rn_read(p, RN_RX_COMP) & 0xffff;
		unsigned int idx;
		struct sk_buff *skb;
		dma_addr_t dma;
		u8 *buf;

		if (!len || p->rx_cons == p->rx_prod)
			break;
		idx = p->rx_cons & p->ring_mask;
		dma = p->rx_pool_dma + idx * RN_DMA_BUF_SIZE;
		buf = p->rx_pool + idx * RN_DMA_BUF_SIZE;
		p->rx_cons++;
		rn_write(p, RN_RX_COMP, 1);

		if (unlikely(len < ETH_ZLEN || len > RN_MAX_FRAME)) {
			spin_lock_irqsave(&p->lock, flags);
			ndev->stats.rx_errors++;
			spin_unlock_irqrestore(&p->lock, flags);
			done++;
			continue;
		}
		/* Single invalidate before CPU read; CPU never writes rx_pool. */
		dma_sync_single_for_cpu(p->dev, dma, len, DMA_FROM_DEVICE);
		skb = napi_alloc_skb(napi, len);
		if (unlikely(!skb)) {
			spin_lock_irqsave(&p->lock, flags);
			ndev->stats.rx_dropped++;
			spin_unlock_irqrestore(&p->lock, flags);
			done++;
			continue;
		}
		memcpy(skb_put(skb, len), buf, len);
		skb->protocol = eth_type_trans(skb, ndev);
		spin_lock_irqsave(&p->lock, flags);
		ndev->stats.rx_packets++;
		ndev->stats.rx_bytes += len;
		spin_unlock_irqrestore(&p->lock, flags);
		napi_gro_receive(napi, skb);
		done++;
	}
	rn_dma_refill_rx(p);
	spin_lock_irqsave(&p->lock, flags);
	rn_dma_reclaim_tx(p);
	spin_unlock_irqrestore(&p->lock, flags);
	if (done < budget && napi_complete_done(napi, done)) {
		spin_lock_irqsave(&p->lock, flags);
		p->irq_mask |= RN_IRQ_RX;
		rn_write(p, RN_IRQ_MASK, p->irq_mask);
		spin_unlock_irqrestore(&p->lock, flags);
	}
	return done;
}

static int rn_poll(struct napi_struct *napi, int budget)
{
	struct rn_priv *p = container_of(napi, struct rn_priv, napi);
	struct net_device *ndev = p->ndev;
	unsigned long flags;
	int done = 0;

	if (p->dma_mode)
		return rn_dma_poll(napi, budget);

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
		if (p->dma_mode) {
			rn_dma_reclaim_tx(p);
		} else if (p->tx_length) {
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

static netdev_tx_t rn_dma_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct rn_priv *p = netdev_priv(ndev);
	unsigned long flags;
	unsigned int len = skb->len;
	unsigned int idx;
	dma_addr_t dma;
	u8 *buf;

	if (unlikely(len < ETH_HLEN || len > RN_MAX_FRAME)) {
		spin_lock_irqsave(&p->lock, flags);
		ndev->stats.tx_dropped++;
		spin_unlock_irqrestore(&p->lock, flags);
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}
	spin_lock_irqsave(&p->lock, flags);
	rn_dma_reclaim_tx(p);
	if (unlikely(p->tx_prod - p->tx_cons >= p->ring_size - 1 ||
		     !(rn_read(p, RN_STATUS) & RN_CLOCKS_READY))) {
		p->irq_mask |= RN_IRQ_TX;
		rn_write(p, RN_IRQ_MASK, p->irq_mask);
		netif_stop_queue(ndev);
		spin_unlock_irqrestore(&p->lock, flags);
		return NETDEV_TX_BUSY;
	}
	idx = p->tx_prod & p->ring_mask;
	buf = p->tx_pool + idx * RN_DMA_BUF_SIZE;
	dma = p->tx_pool_dma + idx * RN_DMA_BUF_SIZE;
	if (unlikely(skb_copy_bits(skb, 0, buf, len))) {
		ndev->stats.tx_dropped++;
		spin_unlock_irqrestore(&p->lock, flags);
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}
	dma_sync_single_for_device(p->dev, dma, len, DMA_TO_DEVICE);
	p->tx_len[idx] = len;
	p->tx_prod++;
	if (p->tx_prod - p->tx_cons >= p->ring_size - 1) {
		p->irq_mask |= RN_IRQ_TX;
		rn_write(p, RN_IRQ_MASK, p->irq_mask);
		netif_stop_queue(ndev);
	}
	netif_trans_update(ndev);
	rn_write(p, RN_TX_ADDR_LO, lower_32_bits(dma));
	rn_write(p, RN_TX_ADDR_HI, upper_32_bits(dma));
	rn_write(p, RN_TX_PUSH, len);
	spin_unlock_irqrestore(&p->lock, flags);
	dev_consume_skb_any(skb);
	return NETDEV_TX_OK;
}

static netdev_tx_t rn_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct rn_priv *p = netdev_priv(ndev);
	unsigned long flags;
	unsigned int i, len = skb->len;

	if (p->dma_mode)
		return rn_dma_xmit(skb, ndev);

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
	if (p->dma_mode) {
		rn_dma_reset_rings(p);
	} else if (p->tx_length) {
		p->ndev->stats.tx_errors++;
		p->ndev->stats.tx_dropped++;
		p->tx_length = 0;
	}
	spin_unlock_irqrestore(&p->lock, flags);
}

static void rn_start(struct rn_priv *p)
{
	rn_write(p, RN_CONTROL, p->dma_mode ? (RN_CTRL_ENABLE | RN_CTRL_DMA) : RN_CTRL_ENABLE);
	rn_write(p, RN_IRQ_STATUS, RN_IRQ_TX);
	if (p->dma_mode)
		rn_dma_refill_rx(p);
	napi_enable(&p->napi);
	p->irq_mask = p->dma_mode ? RN_IRQ_RX : (RN_IRQ_RX | RN_IRQ_TX);
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
	p->dev = dev;
	spin_lock_init(&p->lock);
	mutex_init(&p->lifecycle);
	INIT_WORK(&p->reset_work, rn_reset_work);
	p->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(p->base))
		return PTR_ERR(p->base);
	if (rn_read(p, RN_ID) != 0x524e4554)
		return dev_err_probe(dev, -ENODEV, "Raptor Ethernet ID mismatch\n");
	ret = rn_read(p, RN_VERSION);
	if (ret != 1 && ret != 2)
		return dev_err_probe(dev, -ENODEV, "Raptor Ethernet ABI mismatch (%d)\n", ret);
	p->dma_mode = (ret == 2);
	if (p->dma_mode) {
		u32 cap = rn_read(p, RN_RING_CAP) & 0xffff;

		if (cap < 16 || cap > RN_DMA_MAX_RING || (cap & (cap - 1)))
			cap = 16;
		p->ring_size = cap;
		p->ring_mask = cap - 1;
		p->pool_bytes = (size_t)cap * RN_DMA_BUF_SIZE;
		ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(64));
		if (ret)
			return dev_err_probe(dev, ret, "cannot set 64-bit DMA mask\n");
		p->rx_pool = devm_kmalloc(dev, p->pool_bytes, GFP_KERNEL);
		p->tx_pool = devm_kmalloc(dev, p->pool_bytes, GFP_KERNEL);
		if (!p->rx_pool || !p->tx_pool)
			return -ENOMEM;
		p->rx_pool_dma = dma_map_single(dev, p->rx_pool, p->pool_bytes,
						DMA_FROM_DEVICE);
		if (dma_mapping_error(dev, p->rx_pool_dma))
			return -ENOMEM;
		p->tx_pool_dma = dma_map_single(dev, p->tx_pool, p->pool_bytes,
						DMA_TO_DEVICE);
		if (dma_mapping_error(dev, p->tx_pool_dma)) {
			dma_unmap_single(dev, p->rx_pool_dma, p->pool_bytes,
					 DMA_FROM_DEVICE);
			return -ENOMEM;
		}
	}
	rn_write(p, RN_IRQ_MASK, 0);
	rn_write(p, RN_CONTROL, 0);
	rn_write(p, RN_MDIO_CONTROL, 0);
	ndev->irq = platform_get_irq(pdev, 0);
	if (ndev->irq < 0)
		return ndev->irq;
	ret = of_get_ethdev_address(dev->of_node, ndev);
	if (ret == -EPROBE_DEFER)
		return ret;
	if (ret)
		eth_hw_addr_random(ndev);
	if (of_phy_is_fixed_link(dev->of_node)) {
		ret = of_phy_register_fixed_link(dev->of_node);
		if (ret)
			return dev_err_probe(dev, ret, "cannot register fixed-link PHY\n");
		interface = PHY_INTERFACE_MODE_GMII;
		ndev->phydev = of_phy_connect(ndev, dev->of_node, rn_adjust_link, 0, interface);
		if (!ndev->phydev) {
			of_phy_deregister_fixed_link(dev->of_node);
			return -ENODEV;
		}
	} else {
		ret = of_get_phy_mode(dev->of_node, &interface);
		if (ret || interface != PHY_INTERFACE_MODE_RGMII_TXID)
			return dev_err_probe(dev, -EINVAL, "requires rgmii-txid PHY mode\n");
		p->mdio.ops = &rn_mdio_ops;
		p->mii = alloc_mdio_bitbang(&p->mdio);
		if (!p->mii)
			return -ENOMEM;
		p->mii->name = "Raptor MDIO";
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
			dev_err_probe(dev, ret, "cannot register MDIO bus\n");
			goto free_mii;
		}
		phy_node = of_parse_phandle(dev->of_node, "phy-handle", 0);
		ndev->phydev = of_phy_connect(ndev, phy_node, rn_adjust_link, 0, interface);
		of_node_put(phy_node);
		if (!ndev->phydev) {
			ret = -ENODEV;
			goto unregister_mii;
		}
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
	dev_info(dev, "Raptor %s Ethernet, %pM, 1000baseT full duplex\n",
		 p->dma_mode ? "AXI4 Ring DMA (ABI v2)" : "packet SRAM PIO (ABI v1)",
		 ndev->dev_addr);
	return 0;

delete_napi:
	netif_napi_del(&p->napi);
	phy_disconnect(ndev->phydev);
	if (of_phy_is_fixed_link(dev->of_node))
		of_phy_deregister_fixed_link(dev->of_node);
unregister_mii:
	if (p->mii)
		mdiobus_unregister(p->mii);
free_mii:
	if (p->mii)
		free_mdio_bitbang(p->mii);
	if (p->dma_mode) {
		dma_unmap_single(dev, p->tx_pool_dma, p->pool_bytes, DMA_TO_DEVICE);
		dma_unmap_single(dev, p->rx_pool_dma, p->pool_bytes, DMA_FROM_DEVICE);
	}
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
	if (of_phy_is_fixed_link(pdev->dev.of_node))
		of_phy_deregister_fixed_link(pdev->dev.of_node);
	if (p->mii) {
		mdiobus_unregister(p->mii);
		free_mdio_bitbang(p->mii);
	}
	if (p->dma_mode) {
		dma_unmap_single(&pdev->dev, p->tx_pool_dma, p->pool_bytes, DMA_TO_DEVICE);
		dma_unmap_single(&pdev->dev, p->rx_pool_dma, p->pool_bytes, DMA_FROM_DEVICE);
	}
}

static const struct of_device_id rn_of_match[] = {
	{ .compatible = "raptor,ethernet-v1" },
	{ .compatible = "raptor,ethernet-v2" },
	{ .compatible = "raptor,native-ethernet-v1" },
	{ .compatible = "raptor,native-ethernet-v2" },
	{ }
};
MODULE_DEVICE_TABLE(of, rn_of_match);

static struct platform_driver rn_driver = {
	.probe = rn_probe,
	.remove = rn_remove,
	.driver = {
		.name = "raptor-eth",
		.of_match_table = rn_of_match,
	},
};
module_platform_driver(rn_driver);

MODULE_DESCRIPTION("Raptor Ethernet controller driver");
MODULE_LICENSE("GPL");
