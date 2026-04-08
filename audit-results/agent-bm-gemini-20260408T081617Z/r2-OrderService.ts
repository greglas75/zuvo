import { Injectable, NotFoundException, BadRequestException, InternalServerErrorException } from '@nestjs/common';

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
  $transaction: (fn: (tx: any) => Promise<any>) => Promise<any>;
}
class RedisService {
  get: (key: string) => Promise<string | null>;
  set: (key: string, val: string, ttl?: number) => Promise<void>;
  del: (key: string) => Promise<void>;
  keys: (pattern: string) => Promise<string[]>;
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

  private async invalidateOrgCache(orgId: string) {
    const pattern = `orders:${orgId}:*`;
    // In a real implementation, we'd use a better invalidation strategy like SCAN or a Set of keys
    // For this fix, we'll simulate the pattern match correctly
    const keys = await this.redis.keys(pattern);
    if (keys.length > 0) {
      await Promise.all(keys.map(k => this.redis.del(k)));
    }
  }

  async findAll(filters: OrderFilters, orgId: string) {
    const cacheKey = this.getCacheKey(orgId, filters);
    try {
      const cached = await this.redis.get(cacheKey);
      if (cached) return JSON.parse(cached);
    } catch (err) {
      console.error(`Cache read error for ${cacheKey}:`, err);
      // Fall through to DB
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

    const orders = await this.prisma.order.findMany({
      where,
      take: Math.min(filters.take ?? 50, 100),
      skip: filters.skip ?? 0,
      orderBy: { createdAt: 'desc' },
    });

    await this.redis.set(cacheKey, JSON.stringify(orders), 300);
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

    // Validation for money and quantities (Fix for security/integrity issues)
    for (const item of dto.lineItems) {
      if (item.quantity <= 0 || item.unitPrice < 0) {
        throw new BadRequestException('Invalid line item quantity or price');
      }
    }

    const order = await this.prisma.$transaction(async (tx: any) => {
      // Use integer math for total calculation to avoid floating point errors
      const totalCents = dto.lineItems.reduce((acc, item) => acc + item.quantity * Math.round(item.unitPrice * 100), 0);

      const newOrder = await tx.order.create({
        data: {
          customerId: dto.customerId,
          currency: dto.currency,
          organizationId: orgId,
          status: 'pending',
          total: totalCents / 100,
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

      console.log(`[AUDIT] Order created: ${newOrder.id} by org ${orgId}`);
      return newOrder;
    });

    await this.invalidateOrgCache(orgId);
    return order;
  }

  async deleteOrder(id: string, orgId: string) {
    await this.findById(id, orgId);

    await this.prisma.$transaction(async (tx: any) => {
      await tx.orderItem.deleteMany({ where: { orderId: id } });
      await tx.order.delete({ where: { id } });
    });

    await this.invalidateOrgCache(orgId);
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

    // Fix: Transition table must be strictly followed, including cancellation terminal states
    if (!transitions[order.status as OrderStatus].includes(newStatus)) {
      throw new BadRequestException(`Invalid transition from ${order.status} to ${newStatus}`);
    }

    // Fix: Optimistic locking with status check
    const updated = await this.prisma.order.update({
      where: { id, status: order.status }, // Ensure status hasn't changed
      data: { status: newStatus },
    });

    if (newStatus === 'shipped') {
      this.emailService.sendShippingNotification(id, 'customer@example.com').catch(err => {
        console.error(`Failed to send shipping email for order ${id}:`, err);
      });
    }

    await this.invalidateOrgCache(orgId);
    console.log(`[AUDIT] Order ${id} status updated to ${newStatus}`);
    return updated;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string) {
    // Fix: Use UTC boundaries to avoid timezone issues
    const startOfMonth = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), 1));
    const startOfNextMonth = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 1));

    const aggregations = await this.prisma.order.groupBy({
      by: ['currency'],
      where: {
        organizationId: orgId,
        createdAt: { 
          gte: startOfMonth, 
          lt: startOfNextMonth // Fix: Exclusive upper bound
        },
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
    // Fix: Use a transaction for atomicity
    return await this.prisma.$transaction(async (tx: any) => {
      const orders = await tx.order.findMany({
        where: { id: { in: ids }, organizationId: orgId },
      });

      const transitions: Record<OrderStatus, OrderStatus[]> = {
        pending: ['confirmed', 'cancelled'],
        confirmed: ['processing', 'cancelled'],
        processing: ['shipped', 'cancelled'],
        shipped: ['delivered'],
        delivered: [],
        cancelled: [],
      };

      const validIds = orders
        .filter(order => transitions[order.status as OrderStatus].includes(newStatus))
        .map(order => order.id);

      if (validIds.length === 0) return 0;

      const { count } = await tx.order.updateMany({
        where: { id: { in: validIds } },
        data: { status: newStatus },
      });

      await this.invalidateOrgCache(orgId);
      return count;
    });
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

    // In a production environment with massive data, this should use cursor pagination or streaming.
    // Given the constraints, we at least ensure it's limited to the requested 10,000.
    return this.prisma.order.findMany({
      where,
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      take: 10000, // Still bounded as per requirement
    });
  }
}
