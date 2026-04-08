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
  };
  orderLineItem: {
    deleteMany(args: Record<string, unknown>): Promise<{ count: number }>;
  };
  auditLog: {
    create(args: Record<string, unknown>): Promise<void>;
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
  keys(pattern: string): Promise<string[]>;
}

interface EmailService {
  sendShippingNotification(customerId: string, orderId: string): Promise<void>;
}

interface PaymentGateway {
  [key: string]: unknown;
}

// ── Constants ─────────────────────────────────────────────────────────────────

const CACHE_TTL_SECONDS = 300;
const MAX_EXPORT_ROWS = 10_000;

const VALID_TRANSITIONS: Record<OrderStatus, OrderStatus[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['processing', 'cancelled'],
  processing: ['shipped', 'cancelled'],
  shipped: ['delivered', 'cancelled'],
  delivered: [],
  cancelled: [],
};

// ── Service ───────────────────────────────────────────────────────────────────

@Injectable()
export class OrderService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly emailService: EmailService,
    private readonly paymentGateway: PaymentGateway,
  ) {}

  // ── Cache helpers ───────────────────────────────────────────────────────────

  private cacheKey(orgId: string, suffix: string): string {
    return `orders:${orgId}:${suffix}`;
  }

  private async invalidateOrgCache(orgId: string): Promise<void> {
    const keys = await this.redis.keys(`orders:${orgId}:*`);
    await Promise.all(keys.map((k) => this.redis.del(k)));
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

    const cacheKey = this.cacheKey(
      orgId,
      `list:${JSON.stringify({ status, dateRange, customerId, take, skip })}`,
    );

    const cached = await this.redis.get(cacheKey);
    if (cached) {
      return JSON.parse(cached) as { orders: OrderRecord[]; total: number };
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
    const cacheKey = this.cacheKey(orgId, `order:${id}`);

    const cached = await this.redis.get(cacheKey);
    if (cached) {
      return JSON.parse(cached) as OrderRecord;
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

    await this.invalidateOrgCache(orgId);
    await this.emitAuditLog('ORDER_CREATED', order.id, orgId, {
      customerId: dto.customerId,
      itemCount: dto.lineItems.length,
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

    await this.invalidateOrgCache(orgId);
    await this.emitAuditLog('ORDER_DELETED', id, orgId);
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
      throw new Error(
        `Invalid transition: ${order.status} → ${newStatus}`,
      );
    }

    const updated = await this.prisma.order.update({
      where: { id },
      data: { status: newStatus },
    });

    await this.invalidateOrgCache(orgId);
    await this.emitAuditLog('ORDER_STATUS_UPDATED', id, orgId, {
      from: order.status,
      to: newStatus,
    });

    if (newStatus === 'shipped') {
      await this.emailService
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
    const start = new Date(month.getFullYear(), month.getMonth(), 1);
    const end = new Date(month.getFullYear(), month.getMonth() + 1, 0, 23, 59, 59, 999);

    const orders = await this.prisma.order.findMany({
      where: {
        organizationId: orgId,
        status: { not: 'cancelled' },
        createdAt: { gte: start, lte: end },
      },
      include: { lineItems: true },
    });

    const revenueMap = new Map<string, number>();
    for (const order of orders) {
      const lineTotal = (order.lineItems ?? []).reduce(
        (sum, item) => sum + item.quantity * item.unitPrice,
        0,
      );
      revenueMap.set(order.currency, (revenueMap.get(order.currency) ?? 0) + lineTotal);
    }

    return Array.from(revenueMap.entries()).map(([currency, total]) => ({ currency, total }));
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

    await this.prisma.order.updateMany({
      where: { id: { in: eligibleIds } },
      data: { status: newStatus },
    });

    await this.invalidateOrgCache(orgId);

    await Promise.all(
      eligibleIds.map((id) =>
        this.emitAuditLog('ORDER_STATUS_UPDATED', id, orgId, { to: newStatus }),
      ),
    );

    if (newStatus === 'shipped') {
      await Promise.all(
        eligible.map((o) =>
          this.emailService
            .sendShippingNotification(o.customerId, o.id)
            .catch((err: unknown) => {
              console.error(`Failed shipping notification for order ${o.id}:`, err);
            }),
        ),
      );
    }

    return eligible.length;
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
