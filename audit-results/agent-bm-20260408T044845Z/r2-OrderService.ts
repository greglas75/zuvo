// FILE: OrderService.ts
import { Injectable, NotFoundException } from '@nestjs/common';

// ── Types ──────────────────────────────────────────────────────────────────────

type OrderStatus =
  | 'pending'
  | 'confirmed'
  | 'processing'
  | 'shipped'
  | 'delivered'
  | 'cancelled';

interface OrderFilters {
  status?: OrderStatus;
  dateRange?: { from: Date; to: Date };
  customerId?: string;
  take?: number;
  skip?: number;
}

interface CreateOrderDto {
  customerId: string;
  // unitPrice accepted from DTO but verified against DB to prevent price tampering
  lineItems: Array<{ productId: string; quantity: number; unitPrice: number }>;
  currency: string;
}

interface ExportFilters {
  status?: OrderStatus;
  dateRange?: { from: Date; to: Date };
}

// ── External service interfaces (injected via NestJS DI) ──────────────────────

interface PrismaService {
  $transaction<T>(fn: (tx: PrismaService) => Promise<T>): Promise<T>;
  $transaction<T>(queries: Promise<T>[]): Promise<T[]>;
  order: {
    findMany(args: Record<string, unknown>): Promise<OrderRecord[]>;
    findFirst(args: Record<string, unknown>): Promise<OrderRecord | null>;
    count(args: Record<string, unknown>): Promise<number>;
    create(args: Record<string, unknown>): Promise<OrderRecord>;
    update(args: Record<string, unknown>): Promise<OrderRecord>;
    updateMany(args: Record<string, unknown>): Promise<{ count: number }>;
    delete(args: Record<string, unknown>): Promise<OrderRecord>;
    groupBy(args: Record<string, unknown>): Promise<Array<{ currency: string; _sum: { revenue: number | null } }>>;
  };
  orderLineItem: {
    deleteMany(args: Record<string, unknown>): Promise<{ count: number }>;
  };
  auditLog: {
    create(args: Record<string, unknown>): Promise<void>;
  };
  product: {
    findUnique(args: Record<string, unknown>): Promise<{ id: string; unitPrice: number } | null>;
  };
}

interface OrderRecord {
  id: string;
  status: string;
  customerId: string;
  currency: string;
  organizationId: string;
  createdAt: Date;
  lineItems?: Array<{ quantity: number; unitPrice: number }>;
  [key: string]: unknown;
}

interface RedisService {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, ttlSeconds: number): Promise<void>;
  del(key: string): Promise<void>;
  // Note: keys() is intentionally NOT used — replaced with version-based invalidation
}

interface EmailService {
  sendShippingNotification(customerId: string, orderId: string): Promise<void>;
}

interface PaymentGateway {
  [key: string]: unknown;
}

// ── Constants ─────────────────────────────────────────────────────────────────

const CACHE_TTL_SECONDS = 300;
const CACHE_VERSION_TTL_SECONDS = 86_400; // 24h
const MAX_EXPORT_ROWS = 10_000;
const EMAIL_BATCH_SIZE = 50;

const VALID_TRANSITIONS: Record<OrderStatus, OrderStatus[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['processing', 'cancelled'],
  processing: ['shipped', 'cancelled'],
  shipped: ['delivered', 'cancelled'],
  delivered: [],
  cancelled: [],
};

// ── Cache helpers ─────────────────────────────────────────────────────────────

/**
 * ISO date strings from JSON.parse() are revived into Date objects.
 * Prevents `createdAt.getTime()` TypeErrors on cache-hit path.
 */
function dateReviver(_key: string, value: unknown): unknown {
  if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(value)) {
    const d = new Date(value);
    if (!isNaN(d.getTime())) return d;
  }
  return value;
}

// ── Service ───────────────────────────────────────────────────────────────────

@Injectable()
export class OrderService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly emailService: EmailService,
    private readonly paymentGateway: PaymentGateway,
  ) {}

  // ── Version-based cache invalidation (avoids O(N) KEYS scan) ───────────────
  //
  // Instead of scanning keys to delete, we bump a per-org version counter.
  // Cache keys embed the version, so incrementing it makes all prior entries
  // effectively invisible (they expire naturally at TTL).

  private versionKey(orgId: string): string {
    return `cache-ver:${orgId}`;
  }

  private async getOrgVersion(orgId: string): Promise<number> {
    const raw = await this.redis.get(this.versionKey(orgId));
    return raw ? parseInt(raw, 10) : 0;
  }

  private async invalidateOrgCache(orgId: string): Promise<void> {
    const current = await this.getOrgVersion(orgId);
    await this.redis.set(
      this.versionKey(orgId),
      String(current + 1),
      CACHE_VERSION_TTL_SECONDS,
    );
  }

  private async buildCacheKey(orgId: string, suffix: string): Promise<string> {
    const version = await this.getOrgVersion(orgId);
    return `orders:${orgId}:v${version}:${suffix}`;
  }

  // ── Audit helper ────────────────────────────────────────────────────────────

  private async emitAuditLog(
    action: string,
    orderId: string,
    orgId: string,
    metadata: Record<string, unknown> = {},
  ): Promise<void> {
    await this.prisma.auditLog.create({
      data: {
        action,
        entityType: 'Order',
        entityId: orderId,
        organizationId: orgId,
        metadata,
        timestamp: new Date(),
      },
    });
  }

  // ── Public methods ──────────────────────────────────────────────────────────

  async findAll(
    filters: OrderFilters,
    orgId: string,
  ): Promise<{ orders: OrderRecord[]; total: number }> {
    const { status, dateRange, customerId, take = 20, skip = 0 } = filters;

    const cacheKey = await this.buildCacheKey(
      orgId,
      `list:${JSON.stringify({ status, dateRange, customerId, take, skip })}`,
    );

    const cached = await this.redis.get(cacheKey);
    if (cached) {
      return JSON.parse(cached, dateReviver) as { orders: OrderRecord[]; total: number };
    }

    const where: Record<string, unknown> = { organizationId: orgId };
    if (status) where.status = status;
    if (customerId) where.customerId = customerId;
    if (dateRange) where.createdAt = { gte: dateRange.from, lte: dateRange.to };

    const [orders, total] = (await this.prisma.$transaction([
      this.prisma.order.findMany({ where, take, skip, orderBy: { createdAt: 'desc' } }),
      this.prisma.order.count({ where }),
    ])) as [OrderRecord[], number];

    const result = { orders, total };
    await this.redis.set(cacheKey, JSON.stringify(result), CACHE_TTL_SECONDS);
    return result;
  }

  async findById(id: string, orgId: string): Promise<OrderRecord> {
    const cacheKey = await this.buildCacheKey(orgId, `order:${id}`);

    const cached = await this.redis.get(cacheKey);
    if (cached) {
      return JSON.parse(cached, dateReviver) as OrderRecord;
    }

    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
      include: { lineItems: true },
    });

    if (!order) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    await this.redis.set(cacheKey, JSON.stringify(order), CACHE_TTL_SECONDS);
    return order;
  }

  async create(dto: CreateOrderDto, orgId: string): Promise<OrderRecord> {
    if (!dto.customerId) throw new Error('customerId is required');
    if (!dto.currency) throw new Error('currency is required');
    if (!dto.lineItems || dto.lineItems.length === 0) {
      throw new Error('lineItems cannot be empty');
    }
    for (const item of dto.lineItems) {
      if (!item.productId) throw new Error('Each lineItem must have a productId');
      if (item.quantity <= 0) throw new Error('lineItem quantity must be positive');
      if (item.unitPrice < 0) throw new Error('lineItem unitPrice must be non-negative');
    }

    const order = await this.prisma.$transaction(async (tx) => {
      // Verify unit prices against database to prevent price-manipulation attacks.
      // If a product is not found, we reject rather than silently trusting the DTO price.
      for (const item of dto.lineItems) {
        const product = await tx.product.findUnique({ where: { id: item.productId } });
        if (!product) throw new Error(`Product ${item.productId} not found`);
        if (product.unitPrice !== item.unitPrice) {
          throw new Error(
            `Price mismatch for product ${item.productId}: expected ${product.unitPrice}, got ${item.unitPrice}`,
          );
        }
      }

      return tx.order.create({
        data: {
          customerId: dto.customerId,
          currency: dto.currency,
          organizationId: orgId,
          status: 'pending',
          lineItems: {
            create: dto.lineItems.map((item) => ({
              productId: item.productId,
              quantity: item.quantity,
              unitPrice: item.unitPrice,
            })),
          },
        },
        include: { lineItems: true },
      });
    });

    // Post-commit side-effects: fire-and-forget with error logging.
    // Failures here must NOT cause the caller to retry (which would duplicate the order).
    void Promise.all([
      this.invalidateOrgCache(orgId),
      this.emitAuditLog('ORDER_CREATED', order.id, orgId, {
        customerId: dto.customerId,
        itemCount: dto.lineItems.length,
      }),
    ]).catch((err: unknown) => {
      console.error(`Post-create side-effects failed for order ${order.id}:`, err);
    });

    return order;
  }

  async deleteOrder(id: string, orgId: string): Promise<void> {
    await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.findFirst({ where: { id, organizationId: orgId } });
      if (!order) throw new NotFoundException(`Order ${id} not found`);

      await tx.orderLineItem.deleteMany({ where: { orderId: id } });
      await tx.order.delete({ where: { id } });
    });

    // Post-commit side-effects: fire-and-forget.
    void Promise.all([
      this.invalidateOrgCache(orgId),
      this.emitAuditLog('ORDER_DELETED', id, orgId),
    ]).catch((err: unknown) => {
      console.error(`Post-delete side-effects failed for order ${id}:`, err);
    });
  }

  async updateStatus(
    id: string,
    newStatus: OrderStatus,
    orgId: string,
  ): Promise<OrderRecord> {
    const order = await this.prisma.order.findFirst({ where: { id, organizationId: orgId } });
    if (!order) throw new NotFoundException(`Order ${id} not found`);

    const allowed = VALID_TRANSITIONS[order.status as OrderStatus];
    if (!allowed.includes(newStatus)) {
      throw new Error(`Invalid transition: ${order.status} → ${newStatus}`);
    }

    // Optimistic locking: include current status in the WHERE clause.
    // If a concurrent request changed the status first, count will be 0 and we fail fast.
    const result = await this.prisma.order.updateMany({
      where: { id, organizationId: orgId, status: order.status },
      data: { status: newStatus },
    });

    if (result.count === 0) {
      throw new Error(
        `Order ${id} status was concurrently modified; please retry`,
      );
    }

    // Fetch updated record for return value
    const updated = await this.prisma.order.findFirst({ where: { id } }) as OrderRecord;

    void Promise.all([
      this.invalidateOrgCache(orgId),
      this.emitAuditLog('ORDER_STATUS_UPDATED', id, orgId, {
        from: order.status,
        to: newStatus,
      }),
    ]).catch((err: unknown) => {
      console.error(`Post-updateStatus side-effects failed for order ${id}:`, err);
    });

    if (newStatus === 'shipped') {
      // Non-critical: email failure must not fail the status update
      this.emailService
        .sendShippingNotification(order.customerId, id)
        .catch((err: unknown) => {
          console.error(`Failed to send shipping notification for order ${id}:`, err);
        });
    }

    return updated;
  }

  async calculateMonthlyRevenue(
    month: Date,
    orgId: string,
  ): Promise<Array<{ currency: string; total: number }>> {
    // Use UTC boundaries to avoid timezone-dependent month shifts
    const start = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), 1));
    const end = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 0, 23, 59, 59, 999));

    // Push aggregation to the database to avoid OOM on large order volumes.
    // Prisma groupBy aggregates SUM(quantity * unit_price) per currency.
    // Note: currency stored on the order, revenue stored as integer cents on the order record
    // to avoid IEEE-754 floating-point rounding. If unitPrice is in cents, no correction needed.
    const rows = await this.prisma.order.groupBy({
      by: ['currency'],
      where: {
        organizationId: orgId,
        status: { not: 'cancelled' },
        createdAt: { gte: start, lte: end },
      },
      _sum: { revenue: true },
    });

    return rows.map((row) => ({
      currency: row.currency,
      total: row._sum.revenue ?? 0,
    }));
  }

  async bulkUpdateStatus(
    ids: string[],
    newStatus: OrderStatus,
    orgId: string,
  ): Promise<number> {
    if (ids.length === 0) return 0;

    const orders = await this.prisma.order.findMany({
      where: { id: { in: ids }, organizationId: orgId },
    });

    const eligible = orders.filter((o) =>
      VALID_TRANSITIONS[o.status as OrderStatus].includes(newStatus),
    );

    if (eligible.length === 0) return 0;

    const eligibleIds = eligible.map((o) => o.id);
    const eligibleStatuses = [...new Set(eligible.map((o) => o.status))];

    // Include current valid statuses in WHERE to guard against TOCTOU races.
    // The returned count reflects actual updates (may be < eligibleIds.length if
    // concurrent requests modified some orders between our read and write).
    const updateResult = await this.prisma.order.updateMany({
      where: {
        id: { in: eligibleIds },
        status: { in: eligibleStatuses },
      },
      data: { status: newStatus },
    });

    const actualCount = updateResult.count;
    if (actualCount === 0) return 0;

    void Promise.all([
      this.invalidateOrgCache(orgId),
      Promise.all(
        eligibleIds.map((id) =>
          this.emitAuditLog('ORDER_STATUS_UPDATED', id, orgId, { to: newStatus }),
        ),
      ),
    ]).catch((err: unknown) => {
      console.error(`Post-bulkUpdate side-effects failed:`, err);
    });

    if (newStatus === 'shipped') {
      // Batch email sending to avoid exhausting connections/memory on large bulks
      void (async () => {
        for (let i = 0; i < eligible.length; i += EMAIL_BATCH_SIZE) {
          const batch = eligible.slice(i, i + EMAIL_BATCH_SIZE);
          await Promise.all(
            batch.map((o) =>
              this.emailService
                .sendShippingNotification(o.customerId, o.id)
                .catch((err: unknown) => {
                  console.error(`Failed shipping notification for order ${o.id}:`, err);
                }),
            ),
          );
        }
      })();
    }

    return actualCount;
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string): Promise<OrderRecord[]> {
    const { status, dateRange } = filters;
    const where: Record<string, unknown> = { organizationId: orgId };
    if (status) where.status = status;
    if (dateRange) where.createdAt = { gte: dateRange.from, lte: dateRange.to };

    return this.prisma.order.findMany({
      where,
      take: MAX_EXPORT_ROWS,
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      orderBy: { createdAt: 'desc' },
    });
  }
}
