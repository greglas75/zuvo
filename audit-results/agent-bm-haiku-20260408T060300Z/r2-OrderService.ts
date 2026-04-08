import { Injectable, NotFoundException, ConflictException } from '@nestjs/common';
import { PrismaService } from './prisma.service';
import { RedisService } from './redis.service';
import { EmailService } from './email.service';
import { PaymentGateway } from './payment-gateway';

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

interface Order {
  id: string;
  organizationId: string;
  customerId: string;
  status: OrderStatus;
  currency: string;
  totalAmount: number;
  createdAt: Date;
}

@Injectable()
export class OrderService {
  private readonly CACHE_TTL = 3600;
  private readonly MAX_EXPORT_ROWS = 10000;
  private readonly MAX_TAKE = 100;

  private readonly stateTransitions: Record<OrderStatus, OrderStatus[]> = {
    pending: ['confirmed', 'cancelled'],
    confirmed: ['processing', 'cancelled'],
    processing: ['shipped', 'cancelled'],
    shipped: ['delivered'],
    delivered: [],
    cancelled: [],
  };

  constructor(
    private prisma: PrismaService,
    private redis: RedisService,
    private email: EmailService,
    private payment: PaymentGateway,
  ) {}

  async findAll(filters: OrderFilters, orgId: string): Promise<Order[]> {
    const cacheKey = `orders:${orgId}:${JSON.stringify(filters)}`;
    const cached = await this.redis.get(cacheKey);
    if (cached) {
      const parsed = JSON.parse(cached);
      return parsed.map((o: any) => ({ ...o, createdAt: new Date(o.createdAt) }));
    }

    const where: any = { organizationId: orgId };
    if (filters.status) where.status = filters.status;
    if (filters.customerId) where.customerId = filters.customerId;
    if (filters.dateRange) {
      where.createdAt = {
        gte: filters.dateRange.from,
        lte: filters.dateRange.to,
      };
    }

    const take = Math.min(filters.take ?? 50, this.MAX_TAKE);
    const orders = await this.prisma.order.findMany({
      where,
      take,
      skip: filters.skip ?? 0,
      orderBy: { createdAt: 'desc' },
    });

    await this.redis.set(cacheKey, JSON.stringify(orders), this.CACHE_TTL);
    return orders;
  }

  async findById(id: string, orgId: string): Promise<Order> {
    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
    });
    if (!order) throw new NotFoundException(`Order ${id} not found`);
    return order;
  }

  async create(dto: CreateOrderDto, orgId: string): Promise<Order> {
    if (!dto.customerId || !dto.lineItems.length || !dto.currency) {
      throw new Error('Invalid order data');
    }

    for (const item of dto.lineItems) {
      if (item.quantity <= 0 || !Number.isFinite(item.quantity)) {
        throw new Error(`Invalid quantity: ${item.quantity}`);
      }
      if (item.unitPrice < 0 || !Number.isFinite(item.unitPrice)) {
        throw new Error(`Invalid unitPrice: ${item.unitPrice}`);
      }
    }

    const order = await this.prisma.$transaction(async (tx) => {
      const totalAmount = dto.lineItems.reduce(
        (sum, item) => sum + item.quantity * item.unitPrice,
        0,
      );

      return await tx.order.create({
        data: {
          organizationId: orgId,
          customerId: dto.customerId,
          status: 'pending',
          currency: dto.currency,
          totalAmount,
          lineItems: {
            createMany: {
              data: dto.lineItems,
            },
          },
        },
      });
    });

    await this.invalidateCache(orgId);
    await this.emitAuditLog('ORDER_CREATED', order.id, orgId);

    return order;
  }

  async deleteOrder(id: string, orgId: string): Promise<void> {
    const order = await this.findById(id, orgId);

    await this.prisma.$transaction(async (tx) => {
      await tx.lineItem.deleteMany({ where: { orderId: id } });
      await tx.order.delete({ where: { id } });
    });

    await this.invalidateCache(orgId);
    await this.emitAuditLog('ORDER_DELETED', id, orgId);
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string): Promise<Order> {
    const order = await this.findById(id, orgId);

    const allowedNext = this.stateTransitions[order.status];
    if (!allowedNext.includes(newStatus)) {
      throw new Error(`Cannot transition from ${order.status} to ${newStatus}`);
    }

    const updated = await this.prisma.order.updateMany({
      where: { id, status: order.status },
      data: { status: newStatus },
    });

    if (updated.count === 0) {
      throw new ConflictException('Order status has changed; transition no longer valid');
    }

    if (newStatus === 'shipped') {
      try {
        await this.email.sendOrderShipped(order.customerId, order.id);
      } catch (err) {
        console.error(`Failed to send shipped email for order ${id}:`, err);
      }
    }

    await this.invalidateCache(orgId);
    await this.emitAuditLog('ORDER_STATUS_UPDATED', id, orgId, { oldStatus: order.status, newStatus });

    return await this.findById(id, orgId);
  }

  async calculateMonthlyRevenue(month: Date, orgId: string): Promise<{ currency: string; total: number }[]> {
    const startOfMonth = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), 1));
    const startOfNextMonth = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 1));

    const orders = await this.prisma.order.findMany({
      where: {
        organizationId: orgId,
        status: { in: ['delivered', 'shipped'] },
        createdAt: { gte: startOfMonth, lt: startOfNextMonth },
      },
    });

    const byCurrency: Record<string, number> = {};
    orders.forEach((order) => {
      byCurrency[order.currency] = (byCurrency[order.currency] ?? 0) + order.totalAmount;
    });

    return Object.entries(byCurrency).map(([currency, total]) => ({
      currency,
      total,
    }));
  }

  async bulkUpdateStatus(
    ids: string[],
    newStatus: OrderStatus,
    orgId: string,
  ): Promise<number> {
    let updated = 0;
    const errors: string[] = [];

    for (const id of ids) {
      try {
        const order = await this.prisma.order.findFirst({
          where: { id, organizationId: orgId },
        });
        if (!order) continue;

        const allowedNext = this.stateTransitions[order.status];
        if (!allowedNext.includes(newStatus)) continue;

        const result = await this.prisma.order.updateMany({
          where: { id, status: order.status },
          data: { status: newStatus },
        });

        if (result.count > 0) {
          updated++;
        }
      } catch (err) {
        if (err instanceof Error) {
          errors.push(`Order ${id}: ${err.message}`);
        }
      }
    }

    if (errors.length > 0) {
      console.error(`Bulk update errors: ${errors.join('; ')}`);
    }

    await this.invalidateCache(orgId);
    return updated;
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string): Promise<Order[]> {
    const where: any = { organizationId: orgId };
    if (filters.status) where.status = filters.status;
    if (filters.dateRange) {
      where.createdAt = {
        gte: filters.dateRange.from,
        lt: new Date(filters.dateRange.to.getTime() + 86400000),
      };
    }

    return await this.prisma.order.findMany({
      where,
      take: this.MAX_EXPORT_ROWS,
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      orderBy: { createdAt: 'desc' },
    });
  }

  private async emitAuditLog(action: string, orderId: string, orgId: string, metadata?: any): Promise<void> {
    console.log(`[AUDIT] ${action} | Order: ${orderId} | Org: ${orgId}`, metadata ?? '');
  }

  private async invalidateCache(orgId: string): Promise<void> {
    const pattern = `orders:${orgId}:*`;
    await this.redis.deletePattern(pattern);
  }
}
