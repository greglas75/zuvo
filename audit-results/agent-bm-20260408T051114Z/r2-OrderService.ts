// FILE: OrderService.ts
import { Injectable, NotFoundException } from '@nestjs/common';

// ── Type Contracts ────────────────────────────────────────────────────────────

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

// ── Dependency stubs (injected via NestJS DI) ─────────────────────────────────

interface PrismaService {
  order: any;
  orderLineItem: any;
  auditLog: any;
  $transaction: (fn: (tx: any) => Promise<any>) => Promise<any>;
}

interface RedisService {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, ttl: number): Promise<void>;
  deletePattern(pattern: string): Promise<void>;
}

interface EmailService {
  sendShippingNotification(customerId: string, orderId: string): Promise<void>;
}

interface PaymentGateway {
  // injected but not used in these methods
}

interface Logger {
  error(msg: string, err?: unknown): void;
}

// ── Constants ─────────────────────────────────────────────────────────────────

const CACHE_TTL_SECONDS = 60;
const MAX_EXPORT_ROWS = 10_000;

/**
 * Valid forward transitions for the order state machine.
 * Cancellation is allowed from any non-delivered state.
 */
const VALID_TRANSITIONS: Readonly<Record<OrderStatus, OrderStatus[]>> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['processing', 'cancelled'],
  processing: ['shipped', 'cancelled'],
  shipped: ['delivered'],
  delivered: [],
  cancelled: [],
};

// ── Service ───────────────────────────────────────────────────────────────────

@Injectable()
export class OrderService {
  private readonly logger: Logger = console;

  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly email: EmailService,
    private readonly payment: PaymentGateway,
  ) {}

  // ── findAll ──────────────────────────────────────────────────────────────

  async findAll(
    filters: OrderFilters,
    orgId: string,
  ): Promise<{ orders: any[]; total: number }> {
    const { status, dateRange, customerId, take = 20, skip = 0 } = filters;
    const cacheKey = this.buildCacheKey(orgId, { status, dateRange, customerId, take, skip });

    const cached = await this.redis.get(cacheKey);
    if (cached) {
      return JSON.parse(cached);
    }

    const where = this.buildOrderWhere(orgId, { status, dateRange, customerId });

    const [orders, total] = await Promise.all([
      this.prisma.order.findMany({
        where,
        take,
        skip,
        orderBy: { createdAt: 'desc' },
        include: { lineItems: true },
      }),
      this.prisma.order.count({ where }),
    ]);

    const result = { orders, total };
    await this.redis.set(cacheKey, JSON.stringify(result), CACHE_TTL_SECONDS);
    return result;
  }

  // ── findById ─────────────────────────────────────────────────────────────

  async findById(id: string, orgId: string): Promise<any> {
    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
      include: { lineItems: true },
    });

    if (!order) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    return order;
  }

  // ── create ───────────────────────────────────────────────────────────────

  async create(dto: CreateOrderDto, orgId: string): Promise<any> {
    const { customerId, lineItems, currency } = dto;

    if (!customerId?.trim()) {
      throw new Error('createOrder: customerId is required');
    }
    if (!lineItems?.length) {
      throw new Error('createOrder: at least one line item is required');
    }
    if (!currency?.trim()) {
      throw new Error('createOrder: currency is required');
    }

    const order = await this.prisma.$transaction(async (tx: any) => {
      const created = await tx.order.create({
        data: {
          customerId,
          currency,
          organizationId: orgId,
          status: 'pending' as OrderStatus,
          lineItems: {
            create: lineItems.map((item) => ({
              productId: item.productId,
              quantity: item.quantity,
              unitPrice: item.unitPrice,
            })),
          },
        },
        include: { lineItems: true },
      });

      await tx.auditLog.create({
        data: {
          action: 'ORDER_CREATED',
          entityId: created.id,
          entityType: 'Order',
          organizationId: orgId,
          metadata: {
            customerId,
            currency,
            lineItemCount: lineItems.length,
          },
        },
      });

      return created;
    });

    // FIX: Cache invalidation failure must not abort an already-committed mutation
    await this.invalidateOrgCache(orgId).catch((err) =>
      this.logger.error('[OrderService] Cache invalidation failed after create', err),
    );
    return order;
  }

  // ── deleteOrder ──────────────────────────────────────────────────────────

  async deleteOrder(id: string, orgId: string): Promise<void> {
    const existing = await this.findById(id, orgId);

    await this.prisma.$transaction(async (tx: any) => {
      await tx.orderLineItem.deleteMany({ where: { orderId: id } });
      // FIX: include organizationId in mutation WHERE for defense-in-depth
      await tx.order.delete({ where: { id, organizationId: orgId } });

      await tx.auditLog.create({
        data: {
          action: 'ORDER_DELETED',
          entityId: id,
          entityType: 'Order',
          organizationId: orgId,
          metadata: { previousStatus: existing.status },
        },
      });
    });

    // FIX: Cache invalidation failure must not abort an already-committed mutation
    await this.invalidateOrgCache(orgId).catch((err) =>
      this.logger.error('[OrderService] Cache invalidation failed after delete', err),
    );
  }

  // ── updateStatus ─────────────────────────────────────────────────────────

  async updateStatus(
    id: string,
    newStatus: OrderStatus,
    orgId: string,
  ): Promise<any> {
    const order = await this.findById(id, orgId);
    const currentStatus = order.status as OrderStatus;

    const allowed = VALID_TRANSITIONS[currentStatus] ?? [];
    if (!allowed.includes(newStatus)) {
      throw new Error(
        `Invalid status transition: ${currentStatus} → ${newStatus}`,
      );
    }

    const updated = await this.prisma.$transaction(async (tx: any) => {
      // FIX: Optimistic concurrency — WHERE includes status to prevent TOCTOU race.
      // If a concurrent request already changed the status, updateCount = 0 and
      // we throw a conflict error rather than silently overwriting.
      const updateCount = await tx.order.updateMany({
        where: { id, organizationId: orgId, status: currentStatus },
        data: { status: newStatus },
      });

      if (updateCount.count === 0) {
        throw new Error(
          `Concurrent update conflict on order ${id}: status was modified concurrently`,
        );
      }

      const result = await tx.order.findFirst({
        where: { id, organizationId: orgId },
        include: { lineItems: true },
      });

      await tx.auditLog.create({
        data: {
          action: 'ORDER_STATUS_UPDATED',
          entityId: id,
          entityType: 'Order',
          organizationId: orgId,
          metadata: { from: currentStatus, to: newStatus },
        },
      });

      return result;
    });

    if (newStatus === 'shipped') {
      await this.email
        .sendShippingNotification(order.customerId, id)
        .catch((err: Error) => {
          this.logger.error(
            `[OrderService] Failed to send shipping email for order ${id}`,
            err,
          );
        });
    }

    // FIX: Cache invalidation failure must not abort an already-committed mutation
    await this.invalidateOrgCache(orgId).catch((err) =>
      this.logger.error('[OrderService] Cache invalidation failed after updateStatus', err),
    );
    return updated;
  }

  // ── calculateMonthlyRevenue ──────────────────────────────────────────────

  async calculateMonthlyRevenue(
    month: Date,
    orgId: string,
  ): Promise<Array<{ currency: string; total: number }>> {
    const from = new Date(month.getFullYear(), month.getMonth(), 1);
    const to = new Date(
      month.getFullYear(),
      month.getMonth() + 1,
      0,
      23,
      59,
      59,
      999,
    );

    const orders = await this.prisma.order.findMany({
      where: {
        organizationId: orgId,
        status: { in: ['shipped', 'delivered'] },
        createdAt: { gte: from, lte: to },
      },
      include: { lineItems: true },
    });

    const byCurrency: Record<string, number> = {};
    for (const order of orders) {
      const orderTotal = (
        order.lineItems as Array<{ quantity: number; unitPrice: number }>
      ).reduce((sum, item) => sum + item.quantity * item.unitPrice, 0);
      byCurrency[order.currency] = (byCurrency[order.currency] ?? 0) + orderTotal;
    }

    // FIX: Round to 2 decimal places to prevent floating-point accumulation errors
    return Object.entries(byCurrency).map(([currency, total]) => ({
      currency,
      total: Math.round(total * 100) / 100,
    }));
  }

  // ── bulkUpdateStatus ─────────────────────────────────────────────────────

  async bulkUpdateStatus(
    ids: string[],
    newStatus: OrderStatus,
    orgId: string,
  ): Promise<number> {
    // NOTE: spec mandates returning count, but we collect failures for logging.
    // Invalid transitions and not-found orders are skipped silently per spec.
    const results = await Promise.allSettled(
      ids.map((id) => this.updateStatus(id, newStatus, orgId)),
    );

    const failures = results.filter((r) => r.status === 'rejected');
    if (failures.length > 0) {
      this.logger.error(
        `[OrderService] bulkUpdateStatus: ${failures.length}/${ids.length} orders failed`,
        failures.map((f) => (f as PromiseRejectedResult).reason?.message),
      );
    }

    return results.filter((r) => r.status === 'fulfilled').length;
  }

  // ── getOrdersForExport ───────────────────────────────────────────────────

  async getOrdersForExport(filters: ExportFilters, orgId: string): Promise<any[]> {
    const { status, dateRange } = filters;

    const where = this.buildOrderWhere(orgId, { status, dateRange });

    return this.prisma.order.findMany({
      where,
      take: MAX_EXPORT_ROWS,
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      orderBy: { createdAt: 'asc' },
    });
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  private buildCacheKey(orgId: string, params: object): string {
    return `orders:${orgId}:${JSON.stringify(params)}`;
  }

  private buildOrderWhere(
    orgId: string,
    filters: {
      status?: OrderStatus;
      dateRange?: { from: Date; to: Date };
      customerId?: string;
    },
  ): object {
    const { status, dateRange, customerId } = filters;
    return {
      organizationId: orgId,
      ...(status !== undefined && { status }),
      ...(customerId !== undefined && { customerId }),
      ...(dateRange !== undefined && {
        createdAt: {
          gte: dateRange.from,
          lte: dateRange.to,
        },
      }),
    };
  }

  private async invalidateOrgCache(orgId: string): Promise<void> {
    await this.redis.deletePattern(`orders:${orgId}:*`);
  }
}
