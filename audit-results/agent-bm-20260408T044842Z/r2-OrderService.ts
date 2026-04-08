// FILE: OrderService.ts
import { Injectable, NotFoundException, Logger } from '@nestjs/common';
import { PrismaService } from './prisma.service';
import { RedisService } from './redis.service';
import { EmailService } from './email.service';
import { PaymentGateway } from './payment.gateway';

type OrderStatus = 'pending' | 'confirmed' | 'processing' | 'shipped' | 'delivered' | 'cancelled';

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

const VALID_TRANSITIONS: Record<OrderStatus, OrderStatus[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['processing', 'cancelled'],
  processing: ['shipped', 'cancelled'],
  shipped: ['delivered'],
  delivered: [],
  cancelled: [],
};

const CACHE_TTL = 300; // 5 minutes
const EXPORT_MAX_ROWS = 10000;

/** Round monetary values to cents precision */
function roundCents(value: number): number {
  return Math.round(value * 100) / 100;
}

/** JSON.parse reviver that restores ISO date strings to Date objects */
function dateReviver(_key: string, value: unknown): unknown {
  if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(value)) {
    const date = new Date(value);
    if (!isNaN(date.getTime())) return date;
  }
  return value;
}

@Injectable()
export class OrderService {
  private readonly logger = new Logger(OrderService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly email: EmailService,
    private readonly paymentGateway: PaymentGateway,
  ) {}

  async findAll(filters: OrderFilters, orgId: string) {
    const cacheKey = `orders:${orgId}:${JSON.stringify(filters)}`;
    const cached = await this.redis.get(cacheKey);
    if (cached) {
      return JSON.parse(cached, dateReviver);
    }

    const where: Record<string, unknown> = { organizationId: orgId };
    if (filters.status) {
      where.status = filters.status;
    }
    if (filters.dateRange) {
      where.createdAt = {
        gte: filters.dateRange.from,
        lte: filters.dateRange.to,
      };
    }
    if (filters.customerId) {
      where.customerId = filters.customerId;
    }

    const orders = await this.prisma.order.findMany({
      where,
      take: filters.take ?? 50,
      skip: filters.skip ?? 0,
      include: { lineItems: true },
      orderBy: { createdAt: 'desc' },
    });

    await this.redis.set(cacheKey, JSON.stringify(orders), CACHE_TTL);
    return orders;
  }

  async findById(id: string, orgId: string) {
    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
      include: { lineItems: true, customer: true, payments: true },
    });

    if (!order) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    return order;
  }

  async create(dto: CreateOrderDto, orgId: string) {
    if (!dto.customerId) {
      throw new Error('customerId is required');
    }
    if (!dto.lineItems || dto.lineItems.length === 0) {
      throw new Error('At least one line item is required');
    }
    if (!dto.currency) {
      throw new Error('currency is required');
    }
    for (const item of dto.lineItems) {
      if (item.quantity <= 0) {
        throw new Error('Line item quantity must be positive');
      }
      if (item.unitPrice < 0) {
        throw new Error('Line item unitPrice must not be negative');
      }
    }

    const totalAmount = dto.lineItems.reduce(
      (sum, item) => sum + roundCents(item.quantity * item.unitPrice),
      0,
    );

    const order = await this.prisma.$transaction(async (tx) => {
      const created = await tx.order.create({
        data: {
          organizationId: orgId,
          customerId: dto.customerId,
          currency: dto.currency,
          totalAmount: roundCents(totalAmount),
          status: 'pending' as OrderStatus,
          lineItems: {
            create: dto.lineItems.map((item) => ({
              productId: item.productId,
              quantity: item.quantity,
              unitPrice: item.unitPrice,
              total: roundCents(item.quantity * item.unitPrice),
            })),
          },
        },
        include: { lineItems: true },
      });

      await tx.auditLog.create({
        data: {
          action: 'ORDER_CREATED',
          entityType: 'Order',
          entityId: created.id,
          organizationId: orgId,
          metadata: { customerId: dto.customerId, totalAmount: roundCents(totalAmount), currency: dto.currency },
        },
      });

      return created;
    });

    await this.invalidateCache(orgId);
    return order;
  }

  async deleteOrder(id: string, orgId: string) {
    const existing = await this.findById(id, orgId);

    await this.prisma.$transaction(async (tx) => {
      await tx.lineItem.deleteMany({ where: { orderId: existing.id } });
      await tx.order.delete({ where: { id: existing.id } });
      await tx.auditLog.create({
        data: {
          action: 'ORDER_DELETED',
          entityType: 'Order',
          entityId: existing.id,
          organizationId: orgId,
          metadata: { deletedOrderStatus: existing.status },
        },
      });
    });

    await this.invalidateCache(orgId);
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string) {
    const order = await this.findById(id, orgId);
    const currentStatus = order.status as OrderStatus;

    const allowed = VALID_TRANSITIONS[currentStatus];
    if (!allowed.includes(newStatus)) {
      throw new Error(
        `Invalid status transition from '${currentStatus}' to '${newStatus}'`,
      );
    }

    // FIX: Wrap in transaction for atomicity; use optimistic locking via where clause
    const updated = await this.prisma.$transaction(async (tx) => {
      const result = await tx.order.updateMany({
        where: { id: order.id, status: currentStatus },
        data: { status: newStatus },
      });

      if (result.count === 0) {
        throw new Error(
          `Concurrent modification: order ${id} status changed since read`,
        );
      }

      await tx.auditLog.create({
        data: {
          action: 'ORDER_STATUS_UPDATED',
          entityType: 'Order',
          entityId: order.id,
          organizationId: orgId,
          metadata: { from: currentStatus, to: newStatus },
        },
      });

      return tx.order.findFirst({
        where: { id: order.id },
        include: { lineItems: true },
      });
    });

    if (newStatus === 'shipped') {
      await this.email
        .sendOrderShippedNotification(order.id, order.customerId)
        .catch((err: Error) => {
          this.logger.error(
            `Failed to send shipping notification for order ${order.id}: ${err.message}`,
          );
        });
    }

    await this.invalidateCache(orgId);
    return updated;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string) {
    // FIX: Use UTC boundaries to avoid timezone drift
    const year = month.getUTCFullYear();
    const mon = month.getUTCMonth();
    const startOfMonth = new Date(Date.UTC(year, mon, 1));
    const endOfMonth = new Date(Date.UTC(year, mon + 1, 0, 23, 59, 59, 999));

    const result = await this.prisma.order.groupBy({
      by: ['currency'],
      where: {
        organizationId: orgId,
        status: { not: 'cancelled' },
        createdAt: {
          gte: startOfMonth,
          lte: endOfMonth,
        },
      },
      _sum: { totalAmount: true },
    });

    return result.map((row) => ({
      currency: row.currency,
      total: row._sum.totalAmount ?? 0,
    }));
  }

  async bulkUpdateStatus(ids: string[], newStatus: OrderStatus, orgId: string) {
    let updatedCount = 0;

    for (const id of ids) {
      try {
        // FIX: Wrap each item in its own transaction for atomicity
        const success = await this.prisma.$transaction(async (tx) => {
          const order = await tx.order.findFirst({
            where: { id, organizationId: orgId },
          });

          if (!order) return false;

          const currentStatus = order.status as OrderStatus;
          const allowed = VALID_TRANSITIONS[currentStatus];
          if (!allowed.includes(newStatus)) return false;

          // Optimistic lock: include current status in where
          const result = await tx.order.updateMany({
            where: { id: order.id, status: currentStatus },
            data: { status: newStatus },
          });

          if (result.count === 0) return false;

          await tx.auditLog.create({
            data: {
              action: 'ORDER_STATUS_UPDATED',
              entityType: 'Order',
              entityId: order.id,
              organizationId: orgId,
              metadata: { from: currentStatus, to: newStatus, bulk: true },
            },
          });

          return true;
        });

        if (success) updatedCount++;
      } catch (err) {
        this.logger.warn(`Failed to update order ${id} in bulk operation: ${(err as Error).message}`);
      }
    }

    if (updatedCount > 0) {
      await this.invalidateCache(orgId);
    }

    return updatedCount;
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string) {
    const where: Record<string, unknown> = { organizationId: orgId };

    if (filters.status) {
      where.status = filters.status;
    }
    if (filters.dateRange) {
      where.createdAt = {
        gte: filters.dateRange.from,
        lte: filters.dateRange.to,
      };
    }

    return this.prisma.order.findMany({
      where,
      take: EXPORT_MAX_ROWS,
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      orderBy: { createdAt: 'desc' },
    });
  }

  // FIX: Replace redis.keys() with SCAN-based iteration
  private async invalidateCache(orgId: string) {
    const pattern = `orders:${orgId}:*`;
    let cursor = '0';
    const keysToDelete: string[] = [];

    do {
      const [nextCursor, keys] = await this.redis.scan(cursor, 'MATCH', pattern, 'COUNT', 100);
      cursor = nextCursor;
      keysToDelete.push(...keys);
    } while (cursor !== '0');

    if (keysToDelete.length > 0) {
      await this.redis.del(...keysToDelete);
    }
  }
}
