import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from 'prisma.service';
import { RedisService } from 'redis.service';
import { EmailService } from 'email.service';
import { PaymentGateway } from 'payment-gateway.service';

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
  createdAt: Date;
  updatedAt: Date;
}

interface LineItem {
  id: string;
  orderId: string;
  productId: string;
  quantity: number;
  unitPrice: number;
}

interface OrderWithItems extends Order {
  lineItems: LineItem[];
}

interface AuditLog {
  action: string;
  orderId: string;
  organizationId: string;
  timestamp: Date;
  details?: Record<string, unknown>;
}

@Injectable()
export class OrderService {
  constructor(
    private prisma: PrismaService,
    private redis: RedisService,
    private email: EmailService,
    private payment: PaymentGateway,
  ) {}

  private getCacheKey(type: string, orgId: string, filter?: string): string {
    return `orders:${orgId}:${type}${filter ? `:${filter}` : ''}`;
  }

  async findAll(filters: OrderFilters, orgId: string): Promise<OrderWithItems[]> {
    const cacheKey = this.getCacheKey('findAll', orgId, JSON.stringify(filters));

    // Try cache first
    const cached = await this.redis.get(cacheKey);
    if (cached) {
      return JSON.parse(cached);
    }

    // Query with filters
    const where: Record<string, unknown> = { organizationId: orgId };

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
      include: { lineItems: true },
      take: filters.take || 50,
      skip: filters.skip || 0,
      orderBy: { createdAt: 'desc' },
    });

    // Cache with 5 minute TTL
    await this.redis.set(cacheKey, JSON.stringify(orders), 300);

    return orders;
  }

  async findById(id: string, orgId: string): Promise<OrderWithItems> {
    const cacheKey = this.getCacheKey('findById', orgId, id);

    const cached = await this.redis.get(cacheKey);
    if (cached) {
      return JSON.parse(cached);
    }

    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
      include: { lineItems: true },
    });

    if (!order) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    await this.redis.set(cacheKey, JSON.stringify(order), 300);
    return order;
  }

  async create(dto: CreateOrderDto, orgId: string): Promise<OrderWithItems> {
    if (!dto.customerId || !dto.lineItems || dto.lineItems.length === 0) {
      throw new Error('Invalid CreateOrderDto: customerId and lineItems are required');
    }

    const order = await this.prisma.$transaction(async (tx) => {
      const newOrder = await tx.order.create({
        data: {
          organizationId: orgId,
          customerId: dto.customerId,
          currency: dto.currency,
          status: 'pending',
        },
        include: { lineItems: true },
      });

      await tx.lineItem.createMany({
        data: dto.lineItems.map((item) => ({
          orderId: newOrder.id,
          productId: item.productId,
          quantity: item.quantity,
          unitPrice: item.unitPrice,
        })),
      });

      await tx.auditLog.create({
        data: {
          action: 'ORDER_CREATED',
          orderId: newOrder.id,
          organizationId: orgId,
          timestamp: new Date(),
        },
      });

      return newOrder;
    });

    // Invalidate cache
    await this.redis.del(this.getCacheKey('findAll', orgId, '*'));

    return order;
  }

  async deleteOrder(id: string, orgId: string): Promise<void> {
    const order = await this.findById(id, orgId);

    await this.prisma.$transaction(async (tx) => {
      await tx.lineItem.deleteMany({ where: { orderId: id } });
      await tx.order.delete({ where: { id } });

      await tx.auditLog.create({
        data: {
          action: 'ORDER_DELETED',
          orderId: id,
          organizationId: orgId,
          timestamp: new Date(),
        },
      });
    });

    // Invalidate cache
    await this.redis.del(this.getCacheKey('findById', orgId, id));
    await this.redis.del(this.getCacheKey('findAll', orgId, '*'));
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string): Promise<Order> {
    const order = await this.findById(id, orgId);

    // State machine enforcement
    const validTransitions: Record<OrderStatus, OrderStatus[]> = {
      pending: ['confirmed', 'cancelled'],
      confirmed: ['processing', 'cancelled'],
      processing: ['shipped', 'cancelled'],
      shipped: ['delivered'],
      delivered: [],
      cancelled: [],
    };

    if (newStatus !== 'cancelled' && !validTransitions[order.status].includes(newStatus)) {
      throw new Error(`Cannot transition from ${order.status} to ${newStatus}`);
    }

    const updated = await this.prisma.order.update({
      where: { id },
      data: { status: newStatus },
    });

    // Send email on shipped status
    if (newStatus === 'shipped') {
      await this.email.sendShippedNotification(order.customerId, id).catch((err) => {
        console.error(`Failed to send shipped notification for order ${id}:`, err);
      });
    }

    // Audit log
    await this.prisma.auditLog.create({
      data: {
        action: 'ORDER_STATUS_UPDATED',
        orderId: id,
        organizationId: orgId,
        timestamp: new Date(),
        details: { oldStatus: order.status, newStatus },
      },
    });

    // Invalidate cache
    await this.redis.del(this.getCacheKey('findById', orgId, id));
    await this.redis.del(this.getCacheKey('findAll', orgId, '*'));

    return updated;
  }

  async calculateMonthlyRevenue(
    month: Date,
    orgId: string,
  ): Promise<Array<{ currency: string; total: number }>> {
    const startOfMonth = new Date(month.getFullYear(), month.getMonth(), 1);
    const endOfMonth = new Date(month.getFullYear(), month.getMonth() + 1, 0);

    const lineItems = await this.prisma.lineItem.findMany({
      where: {
        order: {
          organizationId: orgId,
          createdAt: { gte: startOfMonth, lte: endOfMonth },
          status: { in: ['shipped', 'delivered'] }, // Only count shipped/delivered
        },
      },
      select: {
        quantity: true,
        unitPrice: true,
        order: { select: { currency: true } },
      },
    });

    const revenue: Record<string, number> = {};

    for (const item of lineItems) {
      const key = item.order.currency;
      const amount = item.quantity * item.unitPrice;
      revenue[key] = (revenue[key] || 0) + amount;
    }

    return Object.entries(revenue).map(([currency, total]) => ({ currency, total }));
  }

  async bulkUpdateStatus(ids: string[], newStatus: OrderStatus, orgId: string): Promise<number> {
    let updated = 0;

    for (const id of ids) {
      try {
        await this.updateStatus(id, newStatus, orgId);
        updated++;
      } catch (err) {
        // Skip invalid transitions silently
        continue;
      }
    }

    return updated;
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string): Promise<OrderWithItems[]> {
    const maxRows = 10000;
    const where: Record<string, unknown> = { organizationId: orgId };

    if (filters.status) where.status = filters.status;

    if (filters.dateRange) {
      where.createdAt = {
        gte: filters.dateRange.from,
        lte: filters.dateRange.to,
      };
    }

    return this.prisma.order.findMany({
      where,
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      take: maxRows,
      orderBy: { createdAt: 'desc' },
    });
  }
}
