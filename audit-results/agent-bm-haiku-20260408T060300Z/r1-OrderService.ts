import { Injectable, NotFoundException } from '@nestjs/common';
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
  private readonly CACHE_TTL = 3600; // 1 hour in seconds
  private readonly MAX_EXPORT_ROWS = 10000;

  // State transition rules: from → allowed next states
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
    if (cached) return JSON.parse(cached);

    const where: any = { organizationId: orgId };
    if (filters.status) where.status = filters.status;
    if (filters.customerId) where.customerId = filters.customerId;
    if (filters.dateRange) {
      where.createdAt = {
        gte: filters.dateRange.from,
        lte: filters.dateRange.to,
      };
    }

    const orders = await this.prisma.order.findMany({
      where,
      take: filters.take ?? 50,
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

    return await this.prisma.$transaction(async (tx) => {
      const totalAmount = dto.lineItems.reduce(
        (sum, item) => sum + item.quantity * item.unitPrice,
        0,
      );

      const order = await tx.order.create({
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

      // Emit audit log
      await this.emitAuditLog('ORDER_CREATED', order.id, orgId);
      await this.invalidateCache(orgId);

      return order;
    });
  }

  async deleteOrder(id: string, orgId: string): Promise<void> {
    const order = await this.findById(id, orgId);

    await this.prisma.$transaction(async (tx) => {
      await tx.lineItem.deleteMany({ where: { orderId: id } });
      await tx.order.delete({ where: { id } });
    });

    await this.emitAuditLog('ORDER_DELETED', id, orgId);
    await this.invalidateCache(orgId);
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string): Promise<Order> {
    const order = await this.findById(id, orgId);

    // Validate state transition
    const allowedNext = this.stateTransitions[order.status];
    if (!allowedNext.includes(newStatus)) {
      throw new Error(`Cannot transition from ${order.status} to ${newStatus}`);
    }

    const updated = await this.prisma.order.update({
      where: { id },
      data: { status: newStatus },
    });

    // Send email notification on shipped
    if (newStatus === 'shipped') {
      try {
        await this.email.sendOrderShipped(order.customerId, order.id);
      } catch (err) {
        console.error(`Failed to send shipped email for order ${id}:`, err);
      }
    }

    await this.emitAuditLog('ORDER_STATUS_UPDATED', id, orgId, { oldStatus: order.status, newStatus });
    await this.invalidateCache(orgId);

    return updated;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string): Promise<{ currency: string; total: number }[]> {
    const startOfMonth = new Date(month.getFullYear(), month.getMonth(), 1);
    const endOfMonth = new Date(month.getFullYear(), month.getMonth() + 1, 0);

    const orders = await this.prisma.order.findMany({
      where: {
        organizationId: orgId,
        status: { in: ['delivered', 'shipped'] },
        createdAt: { gte: startOfMonth, lte: endOfMonth },
      },
    });

    const byCurrency: Record<string, number> = {};
    orders.forEach((order) => {
      byurrency[order.currency] = (byurrency[order.currency] ?? 0) + order.totalAmount;
    });

    return Object.entries(byurrency).map(([currency, total]) => ({
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

    for (const id of ids) {
      try {
        const order = await this.prisma.order.findFirst({
          where: { id, organizationId: orgId },
        });
        if (!order) continue;

        const allowedNext = this.stateTransitions[order.status];
        if (!allowedNext.includes(newStatus)) continue;

        await this.prisma.order.update({
          where: { id },
          data: { status: newStatus },
        });
        updated++;
      } catch {
        // Silently skip invalid transitions
      }
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
        lte: filters.dateRange.to,
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
    // Placeholder: emit to audit log system
    console.log(`[AUDIT] ${action} | Order: ${orderId} | Org: ${orgId}`, metadata ?? '');
  }

  private async invalidateCache(orgId: string): Promise<void> {
    const pattern = `orders:${orgId}:*`;
    await this.redis.deletePattern(pattern);
  }
}
