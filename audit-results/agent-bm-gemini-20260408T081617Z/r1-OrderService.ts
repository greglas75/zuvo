import { Injectable, NotFoundException, BadRequestException } from '@nestjs/common';

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

// Mocking dependencies for the sake of the benchmark environment
class PrismaService {
  order: any;
  orderItem: any;
  $transaction: any;
}
class RedisService {
  get: (key: string) => Promise<string | null>;
  set: (key: string, val: string, ttl?: number) => Promise<void>;
  del: (key: string) => Promise<void>;
}
class EmailService {
  sendShippingNotification: (orderId: string, email: string) => Promise<void>;
}
class PaymentGateway {}

@Injectable()
export class OrderService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly emailService: EmailService,
    private readonly paymentGateway: PaymentGateway,
  ) {}

  private getCacheKey(orgId: string, filters: any): string {
    return `orders:${orgId}:${JSON.stringify(filters)}`;
  }

  async findAll(filters: OrderFilters, orgId: string) {
    const cacheKey = this.getCacheKey(orgId, filters);
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
      take: Math.min(filters.take ?? 50, 100),
      skip: filters.skip ?? 0,
      orderBy: { createdAt: 'desc' },
    });

    await this.redis.set(cacheKey, JSON.stringify(orders), 300); // 5 min TTL
    return orders;
  }

  async findById(id: string, orgId: string) {
    const order = await this.prisma.order.findUnique({
      where: { id },
      include: { lineItems: true },
    });

    if (!order || order.organizationId !== orgId) {
      throw new NotFoundException(`Order with ID ${id} not found`);
    }

    return order;
  }

  async create(dto: CreateOrderDto, orgId: string) {
    if (!dto.customerId || !dto.lineItems?.length) {
      throw new BadRequestException('Invalid order data');
    }

    const order = await this.prisma.$transaction(async (tx: any) => {
      const newOrder = await tx.order.create({
        data: {
          customerId: dto.customerId,
          currency: dto.currency,
          organizationId: orgId,
          status: 'pending',
          total: dto.lineItems.reduce((acc, item) => acc + item.quantity * item.unitPrice, 0),
          lineItems: {
            create: dto.lineItems.map(item => ({
              productId: item.productId,
              quantity: item.quantity,
              unitPrice: item.unitPrice,
            })),
          },
        },
        include: { lineItems: true },
      });

      // Emit audit log (mocked)
      console.log(`[AUDIT] Order created: ${newOrder.id} by org ${orgId}`);

      return newOrder;
    });

    return order;
  }

  async deleteOrder(id: string, orgId: string) {
    await this.findById(id, orgId); // Verify existence and ownership

    await this.prisma.$transaction(async (tx: any) => {
      await tx.orderItem.deleteMany({ where: { orderId: id } });
      await tx.order.delete({ where: { id } });
    });

    await this.redis.del(`orders:${orgId}:*`); // Crude invalidation for simplicity
    console.log(`[AUDIT] Order deleted: ${id}`);
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string) {
    const order = await this.findById(id, orgId);

    const transitions: Record<OrderStatus, OrderStatus[]> = {
      pending: ['confirmed', 'cancelled'],
      confirmed: ['processing', 'cancelled'],
      processing: ['shipped', 'cancelled'],
      shipped: ['delivered'],
      delivered: [],
      cancelled: [],
    };

    if (newStatus !== 'cancelled' && !transitions[order.status].includes(newStatus)) {
      throw new BadRequestException(`Invalid transition from ${order.status} to ${newStatus}`);
    }

    const updated = await this.prisma.order.update({
      where: { id },
      data: { status: newStatus },
    });

    if (newStatus === 'shipped') {
      this.emailService.sendShippingNotification(id, 'customer@example.com').catch(err => {
        console.error(`Failed to send shipping email for order ${id}:`, err);
      });
    }

    console.log(`[AUDIT] Order ${id} status updated to ${newStatus}`);
    return updated;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string) {
    const startOfMonth = new Date(month.getFullYear(), month.getMonth(), 1);
    const endOfMonth = new Date(month.getFullYear(), month.getMonth() + 1, 0);

    const aggregations = await this.prisma.order.groupBy({
      by: ['currency'],
      where: {
        organizationId: orgId,
        createdAt: { gte: startOfMonth, lte: endOfMonth },
        status: { not: 'cancelled' },
      },
      _sum: { total: true },
    });

    return aggregations.map((a: any) => ({
      currency: a.currency,
      total: a._sum.total || 0,
    }));
  }

  async bulkUpdateStatus(ids: string[], newStatus: OrderStatus, orgId: string) {
    const orders = await this.prisma.order.findMany({
      where: { id: { in: ids }, organizationId: orgId },
    });

    let count = 0;
    const transitions: Record<OrderStatus, OrderStatus[]> = {
      pending: ['confirmed', 'cancelled'],
      confirmed: ['processing', 'cancelled'],
      processing: ['shipped', 'cancelled'],
      shipped: ['delivered'],
      delivered: [],
      cancelled: [],
    };

    for (const order of orders) {
      if (newStatus === 'cancelled' || transitions[order.status as OrderStatus].includes(newStatus)) {
        await this.prisma.order.update({
          where: { id: order.id },
          data: { status: newStatus },
        });
        count++;
      }
    }

    return count;
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string) {
    const where: any = { organizationId: orgId };
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
      take: 10000,
    });
  }
}
