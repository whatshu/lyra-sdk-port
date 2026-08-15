/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Copyright (c) 2026 shu-sdk contributors
 *
 * M0 virtio-rpmsg responder implementation.  See rpmsg_responder.h for the
 * protocol overview.  Every constant here is taken from the Linux driver the
 * M0 talks to:
 *
 *   - vring layout      kernel include/uapi/linux/virtio_ring.h  vring_init()
 *   - ring geometry     drivers/rpmsg/rockchip_rpmsg_mbox.c       RPMSG_BUF_COUNT,
 *                       RPMSG_VRING_ALIGN, RPMSG_VRING_SIZE, RPMSG_VRING_OVERHEAD
 *   - mailbox registers drivers/mailbox/rockchip-mailbox.c       V2 layout
 *   - rpmsg header      drivers/rpmsg/virtio_rpmsg_bus.c         struct rpmsg_hdr
 *   - name service      drivers/rpmsg/rpmsg_ns.c                 struct rpmsg_ns_msg
 *
 * The RK3506 mailbox is the V2 single-channel IP: A2B_INTEN/STATUS/CMD/DAT at
 * 0x00/0x04/0x08/0x0c and B2A_* at 0x10/0x14/0x18/0x1c.  The AP driver's
 * mbox_tx channel is mailbox2 (A2B to us) and its mbox_rx channel is mailbox0
 * (B2A from us).  Status bits are write-1-to-clear.
 */

#include <stdint.h>
#include <string.h>

#include "hal_base.h"
#include "rpmsg_responder.h"
#include "bootmark.h"

/* ------------------------------------------------------------------------- */
/* Ring geometry — must match the kernel driver exactly.                     */
/* ------------------------------------------------------------------------- */

#define VRING_NUM       64U        /* RPMSG_BUF_COUNT                  */
#define VRING_ALIGN     0x1000U    /* RPMSG_VRING_ALIGN                */
#define VRING_DESC_SIZE 16U        /* sizeof(struct vring_desc)        */

#define RVQ_BASE        0x03c00000UL   /* vring[0] "input" : Linux rx  */
#define SVQ_BASE        0x03c08000UL   /* vring[1] "output": Linux tx  */

/* --- temporary bring-up diagnostics -------------------------------------- */
#define HBASE           0x03c90000UL   /* DDR scratch word, A7-readable     */
#define HB_EVERY        256U           /* heartbeat increment period        */
#define KICK_EVERY      0x100000U      /* liveness B2A poke period (iters)  */

/* Progress tracking: a state word + detail word beside the heartbeat, read
 * by Linux via devmem, and snapshot by fault_diag.c's HardFault_Handler.
 * The state always holds the LAST phase the responder reached; a fault in
 * that phase leaves it pointing at the operation that faulted. */
#define DIAG_STATE      0x03c90004UL
#define DIAG_DETAIL     0x03c90008UL
#define DIAG_S(_s)      (*g_state = (_s))

enum {
    DIAG_INIT = 0,       /* before the loop body runs                     */
    DIAG_LOOP_TOP = 1,   /* top of for(;;), before the heartbeat          */
    DIAG_AFTER_POLL = 2, /* mailbox2 A2B drained                          */
    DIAG_ANNOUNCE = 3,   /* in announce_endpoint()                        */
    DIAG_ANNOUNCE_DONE = 4, /* NS message posted + kicked                 */
    DIAG_SVQ = 5,        /* in the serve-tx loop                          */
    DIAG_KICK = 6,       /* in mbox_kick(); detail = mbox base            */
};

/* ------------------------------------------------------------------------- */
/* rpmsg protocol constants (kernel virtio_rpmsg_bus.c / rpmsg.h).           */
/* ------------------------------------------------------------------------- */

#define RPMSG_MBOX_MAGIC  0x524D5347UL
#define LINK_ID           0x02U
#define RPMSG_NS_ADDR     53U          /* RPMSG_NS_ADDR                  */
#define RPMSG_NS_CREATE   0U           /* this kernel: CREATE=0, DESTROY=1 */
#define RPMSG_NAME_SIZE   32U
#define RPMSG_HDR_SIZE    16U          /* sizeof(struct rpmsg_hdr)       */
#define MAX_BUF_SIZE      512U         /* MAX_RPMSG_BUF_SIZE             */
#define M0_EPT_ADDR       0x1FU        /* endpoint address we announce   */

#define VRING_DESC_F_NEXT 1U           /* VRING_DESC_F_NEXT              */

/* ------------------------------------------------------------------------- */
/* Mailbox (V2 layout).                                                      */
/* ------------------------------------------------------------------------- */

#define MBOX0_BASE        0xff290000UL   /* Linux mbox_rx (M0 -> Linux)  */
#define MBOX2_BASE        0xff292000UL   /* Linux mbox_tx (Linux -> M0)  */

/*
 * A2B_INTEN enable bit.  The AP's rockchip_mbox_v2_startup() writes A2B_INTEN
 * = 0x01000100: the bit-24 write-enable key is consumed by the hardware,
 * leaving only the bit-8 trigger-method field -- no enable bit.  Without
 * INTEN_TX_DONE (bit 0) the hardware never latches A2B_STATUS, so the
 * mbox_poll_kick() poll below can never observe the AP's kick.  The kernel
 * expects the remote to enable its own receive side (HAL_MBOX_ChanEnable does
 * exactly this), but the rk3506-mcu HAL project never calls it.  mbox_enable_rx()
 * is re-asserted periodically (not just at init) because the AP re-runs
 * v2_startup() on every Linux boot and its write clears bit 0 again.
 */
#define MBOX_A2B_INTEN_EN  0x00010001UL   /* write-enable key | bit 0 */

struct mbox_v2 {
    volatile uint32_t a2b_inten;   /* 0x00 */
    volatile uint32_t a2b_status;  /* 0x04 */
    volatile uint32_t a2b_cmd;     /* 0x08 */
    volatile uint32_t a2b_dat;     /* 0x0c */
    volatile uint32_t b2a_inten;   /* 0x10 */
    volatile uint32_t b2a_status;  /* 0x14 */
    volatile uint32_t b2a_cmd;     /* 0x18 */
    volatile uint32_t b2a_dat;     /* 0x1c */
};

#define MBOX_A2B_RX_MASK   0x1U          /* single channel              */

/* ------------------------------------------------------------------------- */
/* virtio split ring structures (kernel uapi/linux/virtio_ring.h).           */
/* ------------------------------------------------------------------------- */

struct vring_desc {
    uint64_t addr;       /* buffer address (guest physical) */
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed));

struct vring_avail {
    volatile uint16_t flags;
    volatile uint16_t idx;
    volatile uint16_t ring[VRING_NUM];
    /* used_event_idx lives at ring[VRING_NUM]; not negotiated, ignored */
} __attribute__((packed));

struct vring_used_elem {
    uint32_t id;
    uint32_t len;
} __attribute__((packed));

struct vring_used {
    volatile uint16_t flags;
    volatile uint16_t idx;
    struct vring_used_elem ring[VRING_NUM];
    /* avail_event_idx at ring[VRING_NUM]; not negotiated, ignored */
} __attribute__((packed));

/*
 * vring_init() from the kernel: desc table, then avail straight after,
 * then used aligned up to VRING_ALIGN.
 *   avail_start = base + num * 16
 *   avail_end   = avail_start + 2 + 2 + num*2 + 2 (flags, idx, ring[], used_event)
 *   used_start  = ALIGN(avail_end, VRING_ALIGN)
 */
#define VRING_USED_OFF(base)                                     \
    (((uint32_t)(base) + (VRING_NUM * VRING_DESC_SIZE) + 6U +    \
      (VRING_NUM * 2U) + VRING_ALIGN - 1U) & ~(VRING_ALIGN - 1U))

struct vring_ctx {
    uint32_t                 base;
    const volatile struct vring_desc  *desc;
    const volatile struct vring_avail *avail;
    volatile struct vring_used        *used;
    uint32_t                 last_avail;  /* how far we've consumed avail */
};

/* ------------------------------------------------------------------------- */
/* rpmsg message header (kernel virtio_rpmsg_bus.c).                         */
/* ------------------------------------------------------------------------- */

struct rpmsg_hdr {
    uint32_t src;
    uint32_t dst;
    uint32_t reserved;
    uint16_t len;
    uint16_t flags;
    uint8_t  data[];
} __attribute__((packed));

struct rpmsg_ns_msg {
    char     name[RPMSG_NAME_SIZE];
    uint32_t addr;
    uint32_t flags;
} __attribute__((packed));

static struct vring_ctx g_rvq;   /* Linux -> M0 receive (input)  */
static struct vring_ctx g_svq;   /* Linux -> M0 transmit (output)*/
static volatile uint32_t g_announced;
static volatile uint32_t g_handshaken; /* first A2B kick (master handshake) */

static volatile uint32_t *g_state  = (volatile uint32_t *)(uintptr_t)DIAG_STATE;
static volatile uint32_t *g_detail = (volatile uint32_t *)(uintptr_t)DIAG_DETAIL;

/* ------------------------------------------------------------------------- */
/* Helpers.                                                                  */
/* ------------------------------------------------------------------------- */

static void vring_init_ctx(struct vring_ctx *vq, uint32_t base)
{
    vq->base      = base;
    vq->desc      = (const volatile struct vring_desc *)(uintptr_t)base;
    vq->avail     = (const volatile struct vring_avail *)
                    (uintptr_t)(base + VRING_NUM * VRING_DESC_SIZE);
    vq->used      = (volatile struct vring_used *)(uintptr_t)VRING_USED_OFF(base);
    vq->last_avail = 0;
}

/*
 * Take the next posted buffer from the avail ring.  Returns the desc head, or
 * -1 if empty.  On success *buf holds the buffer address Linux posted and
 * *len its capacity.
 */
static int32_t vring_get_avail(struct vring_ctx *vq, uintptr_t *buf, uint32_t *len)
{
    uint16_t idx = vq->avail->idx;
    uint16_t head;

    if (vq->last_avail == idx)
        return -1;

    /*
     * Linux publishes ring entries before the avail index (release).  Read
     * the entry, then make sure the descriptor we read after it is ordered.
     */
    __DMB();
    head = vq->avail->ring[vq->last_avail % VRING_NUM];
    __DMB();

    if (vq->desc[head].flags & VRING_DESC_F_NEXT) {
        /* single-buffer transfers only in this stack; never chain */
        return -1;
    }

    *buf = (uintptr_t)vq->desc[head].addr;
    *len = vq->desc[head].len;
    vq->last_avail++;

    return head;
}

/* Publish a completed buffer to the used ring (device -> driver). */
static void vring_put_used(struct vring_ctx *vq, int32_t head, uint32_t len)
{
    uint16_t idx = vq->used->idx;

    vq->used->ring[idx % VRING_NUM].id  = (uint32_t)head;
    vq->used->ring[idx % VRING_NUM].len = len;

    /* Release: ring entries must be visible before the index advances. */
    __DMB();
    vq->used->idx = (uint16_t)(idx + 1U);
    __DMB();
}

/* Kick the Linux side: write a B2A message on @mbox (cmd=link-id, data=magic). */
static void mbox_kick(uint32_t mbox)
{
    volatile struct mbox_v2 *m = (volatile struct mbox_v2 *)(uintptr_t)mbox;
    uint32_t i;

    *g_detail = mbox;
    DIAG_S(DIAG_KICK);

    /* Don't clobber an undelivered message: wait for the AP to consume it. */
    for (i = 0; i < 10000U && (m->b2a_status & MBOX_A2B_RX_MASK); i++) {
    }

    m->b2a_cmd = LINK_ID;
    m->b2a_dat = RPMSG_MBOX_MAGIC;  /* DAT write triggers delivery */
    DIAG_S(DIAG_ANNOUNCE_DONE);     /* harmless for the liveness poke too */
}

/* Enable the AP -> M0 (A2B) receive side; see MBOX_A2B_INTEN_EN above. */
static void mbox_enable_rx(void)
{
    volatile struct mbox_v2 *m = (volatile struct mbox_v2 *)(uintptr_t)MBOX2_BASE;
    m->a2b_inten = MBOX_A2B_INTEN_EN;
}

/*
 * Consume one kick from the AP on mailbox2 (A2B).  Returns 1 when a kick was
 * pending, 0 otherwise.  Reading the payload clears the hardware flag.
 */
static int mbox_poll_kick(void)
{
    volatile struct mbox_v2 *m = (volatile struct mbox_v2 *)(uintptr_t)MBOX2_BASE;
    uint32_t cmd, dat;

    if (!(m->a2b_status & MBOX_A2B_RX_MASK))
        return 0;

    cmd = m->a2b_cmd;
    dat = m->a2b_dat;

    /* write-1-to-clear so Linux's last_tx_done() sees the channel free */
    m->a2b_status = MBOX_A2B_RX_MASK;

    if ((dat != RPMSG_MBOX_MAGIC) || ((cmd & 0xFFU) != LINK_ID))
        return 0;   /* not ours — ignore */

    return 1;
}

/* Announce the "rpmsg-tty" endpoint so Linux probes rpmsg_tty -> /dev/ttyRPMSG0. */
static void announce_endpoint(void)
{
    struct rpmsg_hdr *hdr;
    struct rpmsg_ns_msg *ns;
    int32_t head;
    uintptr_t buf;
    uint32_t len;

    head = vring_get_avail(&g_rvq, &buf, &len);
    if (head < 0)
        return;                     /* no rx buffer yet; retry next poll */

    hdr = (struct rpmsg_hdr *)buf;
    hdr->src      = M0_EPT_ADDR;
    hdr->dst      = RPMSG_NS_ADDR;
    hdr->reserved = 0;
    hdr->len      = (uint16_t)sizeof(struct rpmsg_ns_msg);
    hdr->flags    = 0;

    ns = (struct rpmsg_ns_msg *)hdr->data;
    memset(ns->name, 0, RPMSG_NAME_SIZE);
    strcpy(ns->name, "rpmsg-tty");
    ns->addr  = M0_EPT_ADDR;
    ns->flags = RPMSG_NS_CREATE;

    vring_put_used(&g_rvq, head, RPMSG_HDR_SIZE + sizeof(struct rpmsg_ns_msg));
    mbox_kick(MBOX0_BASE);          /* rx kick: Linux will read the NS message */
    g_announced = 1;
}

/* Serve one TX message Linux sent us on the svq. */
static void serve_tx(int32_t head, uintptr_t buf, uint32_t len)
{
    const struct rpmsg_hdr *rx = (const struct rpmsg_hdr *)buf;
    const char *payload;
    int32_t tx_head;
    uintptr_t tx_buf;
    uint32_t tx_len;
    uint32_t plen;
    struct rpmsg_hdr *tx;
    uint32_t used_len = 0;

    if (len < RPMSG_HDR_SIZE)
        goto done;

    plen    = rx->len;
    payload = (const char *)rx->data;

    if (plen > MAX_BUF_SIZE - RPMSG_HDR_SIZE)
        plen = MAX_BUF_SIZE - RPMSG_HDR_SIZE;

    /*
     * Name-service traffic (dst == RPMSG_NS_ADDR) is only Linux confirming a
     * channel it created itself; we have nothing to add.  Real data is
     * addressed to our announced endpoint: echo "ping" as "pong".
     */
    if (rx->dst == M0_EPT_ADDR && plen > 0) {
        tx_head = vring_get_avail(&g_rvq, &tx_buf, &tx_len);
        if (tx_head < 0)
            goto done;               /* no rx buffer to reply into */

        tx = (struct rpmsg_hdr *)tx_buf;
        tx->src      = M0_EPT_ADDR;
        tx->dst      = rx->src;
        tx->reserved = 0;

        if (plen == 4 && memcmp(payload, "ping", 4) == 0) {
            tx->len  = 4;
            tx->flags = 0;
            memcpy(tx->data, "pong", 4);
            used_len = RPMSG_HDR_SIZE + 4;
        } else {
            tx->len  = (uint16_t)plen;
            tx->flags = 0;
            memcpy(tx->data, payload, plen);
            used_len = RPMSG_HDR_SIZE + plen;
        }

        vring_put_used(&g_rvq, tx_head, used_len);
        mbox_kick(MBOX0_BASE);       /* rx kick: deliver the reply */
    }

done:
    /* Recycle the TX buffer so Linux's next get_a_tx_buf() can reuse it. */
    vring_put_used(&g_svq, head, len);
    /*
     * txdone kick (mailbox2 B2A) is optional: rpmsg_tty sends non-blocking and
     * reclaims used buffers via virtqueue_get_buf() without waiting, so we
     * don't need to wake any sleeping sender.
     */
}

/* ------------------------------------------------------------------------- */
/* Public API.                                                               */
/* ------------------------------------------------------------------------- */

void rpmsg_responder_run(void)
{
    int32_t head;
    uintptr_t buf;
    uint32_t len;
    volatile uint32_t *hb = (volatile uint32_t *)(uintptr_t)HBASE;
    uint32_t iters = 0, kick_cnt = 0;

    BM_STAGE(BM_RUN);

    vring_init_ctx(&g_rvq, RVQ_BASE);
    vring_init_ctx(&g_svq, SVQ_BASE);
    g_announced = 0;
    g_handshaken = 0;
    *hb = 0;
    *g_detail = 0;
    *g_state = DIAG_INIT;

    mbox_enable_rx();

    for (;;) {
        DIAG_S(DIAG_LOOP_TOP);
        iters++;

        /*
         * Bring-up heartbeat: keep a visible counter in DDR so a live M0 can
         * be told apart from a silent one via devmem (temporary diagnostic).
         */
        if ((iters & (HB_EVERY - 1U)) == 0) {
            *hb = *hb + 1U;
            /* Linux's v2_startup clears bit 0 on every boot; re-assert. */
            mbox_enable_rx();
        }

        /* Drain pending A2B kicks (handshake + each Linux TX message). */
        if (mbox_poll_kick())
            g_handshaken = 1;
        DIAG_S(DIAG_AFTER_POLL);

        /*
         * Announce only after the master's handshake.  Linux posts rx
         * buffers, registers its NS endpoint (rpmsg_ns_register_device),
         * and only then sends the first A2B kick via virtio_device_ready
         * (drivers/rpmsg/virtio_rpmsg_bus.c).  Announcing on buffer
         * availability alone races that registration: the name-service
         * message arrives before the endpoint exists, is dropped with
         * "msg received with no recipient", and since we announce only
         * once, the channel is lost for good.
         */
        if (!g_announced) {
            if (g_handshaken && g_rvq.avail->idx != 0) {
                DIAG_S(DIAG_ANNOUNCE);
                announce_endpoint();
            }
            /*
             * Liveness poke: while still unannounced, kick the AP once in a
             * while so the mailbox B2A IRQ count proves the M0 is running and
             * can reach the peripheral bus (temporary diagnostic).
             */
            kick_cnt++;
            if (kick_cnt >= KICK_EVERY) {
                kick_cnt = 0;
                mbox_kick(MBOX0_BASE);
            }
        }

        /* Serve every TX message Linux queued on the svq. */
        DIAG_S(DIAG_SVQ);
        while ((head = vring_get_avail(&g_svq, &buf, &len)) >= 0)
            serve_tx(head, buf, len);
    }
}
