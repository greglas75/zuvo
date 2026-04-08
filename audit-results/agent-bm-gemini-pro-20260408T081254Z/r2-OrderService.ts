import { Injectable, NotFoundException, BadRequestException, ConflictException } from '@nestjs/common';

export type OrderStatus = 'pending' | 'confirmed' | 'processing' | 'shipped' | 'delivered' | 'cancelled';

export interface OrderFilters {
  status?: OrderStatus;
  dateRange?: { from: Date; to: Date };
  customerId?: string;
  take?: number;
  skip?: number;
}

export interface CreateOrderDto {
  customerId: string;
  lineItems: Array<{ productId: string; quantity: number; unitPrice: number }>;
  currency: string;
}

export interface ExportFilters {
  status?: OrderStatus;
  dateRange?: { from: Date; to: Date };
}

@Injectable()
export class OrderService {
  constructor(
    private readonly prisma: any,
    private readonly redis: any,
    private readonly emailService: any,
    private readonly paymentGateway: any,
  ) {}

  private validateLineItems(lineItems: any[]) {
    if (!lineItems || lineItems.length === 0) {
      throw new BadRequestException('Order must have at least one line item');
    }
    for (const item of lineItems) {
      if (!Number.isFinite(item.quantity) || item.quantity <= 0 || !Number.isInteger(item.quantity)) {
        throw new BadRequestException('Invalid quantity');
      }
      if (!Number.isFinite(item.unitPrice) || item.unitPrice < 0) {
        throw new BadRequestException('Invalid unit price');
      }
    }
  }

  async findAll(filters: OrderFilters, orgId: string) {
    const cacheKey = `org:${orgId}:orders:findAll:${JSON.stringify(filters)}:v1`;
    try {
      const cached = await this.redis.get(cacheKey);
      if (cached) {
        return JSON.parse(cached, (key, value) => 
          typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(value) ? new Date(value) : value
        );
      }
    } catch (err) {
      console.error('Redis error', err);
    }

    const { status, dateRange, customerId, take = 50, skip = 0 } = filters;
    const where: any = { orgId };
    if (status) where.status = status;
    if (customerId) where.customerId = customerId;
    if (dateRange) {
      where.createdAt = { gte: dateRange.from, lte: dateRange.to };
    }

    if (take <= 0 || !Number.isInteger(take)) throw new BadRequestException('Invalid take');
    if (skip < 0 || !Number.isInteger(skip)) throw new BadRequestException('Invalid skip');

    const orders = await this.prisma.order.findMany({ where, take, skip });

    try {
      await this.redis.set(cacheKey, JSON.stringify(orders), 'EX', 300);
    } catch (err) {
      console.error('Redis error', err);
    }
    return orders;
  }

  async findById(id: string, orgId: string) {
    const cacheKey = `org:${orgId}:orders:findById:${id}:v1`;
    try {
      const cached = await this.redis.get(cacheKey);
      if (cached) {
        return JSON.parse(cached, (key, value) => 
          typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(value) ? new Date(value) : value
        );
      }
    } catch (err) {
      console.error('Redis error', err);
    }

    const order = await this.prisma.order.findUnique({ where: { id } });
    if (!order || order.orgId !== orgId) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    try {
      await this.redis.set(cacheKey, JSON.stringify(order), 'EX', 300);
    } catch (err) {
      console.error('Redis error', err);
    }
    return order;
  }

  async create(dto: CreateOrderDto, orgId: string) {
    if (!dto.customerId || typeof dto.customerId !== 'string') {
        throw new BadRequestException('Invalid customerId');
    }
    if (!dto.currency || typeof dto.currency !== 'string' || dto.currency.length !== 3) {
      throw new BadRequestException('Invalid currency');
    }
    this.validateLineItems(dto.lineItems);

    const order = await this.prisma.$transaction(async (tx: any) => {
      const newOrder = await tx.order.create({
        data: {
          orgId,
          customerId: dto.customerId,
          currency: dto.currency,
          status: 'pending',
          lineItems: {
            create: dto.lineItems
          }
        },
        include: { lineItems: true }
      });
      await tx.auditLog.create({
        data: { orgId, orderId: newOrder.id, action: 'CREATE_ORDER' }
      });
      return newOrder;
    });

    try { await this.redis.incr(`org:${orgId}:orders:v1`); } catch (err) { console.error(err); }
    return order;
  }

  async deleteOrder(id: string, orgId: string) {
    const order = await this.prisma.order.findUnique({ where: { id } });
    if (!order || order.orgId !== orgId) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    await this.prisma.$transaction(async (tx: any) => {
      await tx.lineItem.deleteMany({ where: { orderId: id } });
      await tx.order.delete({ where: { id } });
      await tx.auditLog.create({
        data: { orgId, orderId: id, action: 'DELETE_ORDER' }
      });
    });

    try { await this.redis.incr(`org:${orgId}:orders:v1`); } catch (err) { console.error(err); }
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string) {
    const transitions: Record<OrderStatus, OrderStatus[]> = {
      'pending': ['confirmed', 'cancelled'],
      'confirmed': ['processing', 'cancelled'],
      'processing': ['shipped', 'cancelled'],
      'shipped': ['delivered', 'cancelled'],
      'delivered': [],
      'cancelled': []
    };

    const order = await this.prisma.$transaction(async (tx: any) => {
      const currentOrder = await tx.order.findUnique({ where: { id } });
      if (!currentOrder || currentOrder.orgId !== orgId) {
        throw new NotFoundException(`Order ${id} not found`);
      }

      if (currentOrder.status === newStatus) return currentOrder;

      const allowed = transitions[currentOrder.status as OrderStatus] || [];
      if (!allowed.includes(newStatus)) {
        throw new ConflictException(`Cannot transition from ${currentOrder.status} to ${newStatus}`);
      }

      const updateResult = await tx.order.updateMany({
        where: { id, status: currentOrder.status, orgId },
        data: { status: newStatus }
      });

      if (updateResult.count === 0) {
         throw new ConflictException('Order state changed concurrently');
      }
      
      const updatedOrder = await tx.order.findUnique({ where: { id } });

      await tx.auditLog.create({
        data: { orgId, orderId: id, action: `UPDATE_STATUS_${newStatus}` }
      });

      return updatedOrder;
    });

    if (newStatus === 'shipped') {
        this.emailService.sendShippingNotification(order.customerId, id).catch((err: any) => {
            console.error('Failed to send shipping email for order', id, err);
        });
    }

    try { await this.redis.incr(`org:${orgId}:orders:v1`); } catch (err) { console.error(err); }
    return order;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string) {
    if (!(month instanceof Date) || isNaN(month.getTime())) {
      throw new BadRequestException('Invalid month date');
    }
    const startOfMonth = new Date(month.getFullYear(), month.getMonth(), 1);
    const endOfMonth = new Date(month.getFullYear(), month.getMonth() + 1, 0, 23, 59, 59, 999);

    const aggregates = await this.prisma.order.groupBy({
      by: ['currency'],
      where: { orgId, createdAt: { gte: startOfMonth, lte: endOfMonth } },
      _sum: { totalAmount: true }
    });

    return aggregates.map((a: any) => ({
      currency: a.currency,
      total: a._sum.totalAmount || 0
    }));
  }

  async bulkUpdateStatus(ids: string[], newStatus: OrderStatus, orgId: string) {
    if (!ids || ids.length === 0) return 0;
    
    let updateCount = 0;
    
    // Skip invalid transitions silently per requirements
    const transitions: Record<OrderStatus, OrderStatus[]> = {
        'pending': ['confirmed', 'cancelled'],
        'confirmed': ['processing', 'cancelled'],
        'processing': ['shipped', 'cancelled'],
        'shipped': ['delivered', 'cancelled'],
        'delivered': [],
        'cancelled': []
    };
    
    for (const id of ids) {
      try {
        await this.prisma.$transaction(async (tx: any) => {
            const currentOrder = await tx.order.findUnique({ where: { id } });
            if (!currentOrder || currentOrder.orgId !== orgId) return; // skip silent
            
            if (currentOrder.status === newStatus) return;
            
            const allowed = transitions[currentOrder.status as OrderStatus] || [];
            if (!allowed.includes(newStatus)) return; // skip silent
            
            const updateResult = await tx.order.updateMany({
                where: { id, status: currentOrder.status, orgId },
                data: { status: newStatus }
            });
            if (updateResult.count === 0) return; // skip silent

            await tx.auditLog.create({
                data: { orgId, orderId: id, action: `BULK_UPDATE_STATUS_${newStatus}` }
            });

            updateCount++;
        });
      } catch (err) {
         // Silently skip transaction errors per requirements where invalid are skipped
      }
    }
    
    try { await this.redis.incr(`org:${orgId}:orders:v1`); } catch (err) { console.error(err); }
    return updateCount;
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string) {
    const where: any = { orgId };
    if (filters.status) where.status = filters.status;
    if (filters.dateRange) {
        where.createdAt = { gte: filters.dateRange.from, lte: filters.dateRange.to };
    }
    
    const orders = await this.prisma.order.findMany({
        where,
        take: 10000,
        include: {
            lineItems: true,
            customer: true,
            payments: true
        }
    });

    return orders;
  }
}
