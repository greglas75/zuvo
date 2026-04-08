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
      return JSON.parse(cached);
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
      (sum, item) => sum + item.quantity * item.unitPrice,
      0,
    );

    const order = await this.prisma.$transaction(async (tx) => {
      const created = await tx.order.create({
        data: {
          organizationId: orgId,
          customerId: dto.customerId,
          currency: dto.currency,
          totalAmount,
          status: 'pending' as OrderStatus,
          lineItems: {
            create: dto.lineItems.map((item) => ({
              productId: item.productId,
              quantity: item.quantity,
              unitPrice: item.unitPrice,
              total: item.quantity * item.unitPrice,
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
          metadata: { customerId: dto.customerId, totalAmount, currency: dto.currency },
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

    const updated = await this.prisma.order.update({
      where: { id: order.id },
      data: { status: newStatus },
      include: { lineItems: true },
    });

    await this.prisma.auditLog.create({
      data: {
        action: 'ORDER_STATUS_UPDATED',
        entityType: 'Order',
        entityId: order.id,
        organizationId: orgId,
        metadata: { from: currentStatus, to: newStatus },
      },
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
    const startOfMonth = new Date(month.getFullYear(), month.getMonth(), 1);
    const endOfMonth = new Date(month.getFullYear(), month.getMonth() + 1, 0, 23, 59, 59, 999);

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
        const order = await this.prisma.order.findFirst({
          where: { id, organizationId: orgId },
        });

        if (!order) continue;

        const currentStatus = order.status as OrderStatus;
        const allowed = VALID_TRANSITIONS[currentStatus];
        if (!allowed.includes(newStatus)) continue;

        await this.prisma.order.update({
          where: { id: order.id },
          data: { status: newStatus },
        });

        await this.prisma.auditLog.create({
          data: {
            action: 'ORDER_STATUS_UPDATED',
            entityType: 'Order',
            entityId: order.id,
            organizationId: orgId,
            metadata: { from: currentStatus, to: newStatus, bulk: true },
          },
        });

        updatedCount++;
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

  private async invalidateCache(orgId: string) {
    const keys = await this.redis.keys(`orders:${orgId}:*`);
    if (keys.length > 0) {
      await this.redis.del(...keys);
    }
  }
}
