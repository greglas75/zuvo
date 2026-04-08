// FILE: OrderService.ts

import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '@nestjs/prisma';

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

interface RedisService {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, ttl?: number): Promise<void>;
  del(key: string): Promise<void>;
}

interface EmailService {
  sendEmail(to: string, subject: string, body: string): Promise<void>;
}

interface PaymentGateway {
  processPayment(orderId: string, amount: number): Promise<{ success: boolean; transactionId: string }>;
}

@Injectable()
export class OrderService {
  constructor(
    private prisma: PrismaService,
    private redis: RedisService,
    private email: EmailService,
    private payment: PaymentGateway,
  ) {}

  async findAll(filters: OrderFilters, orgId: string) {
    const cacheKey = `orders:${orgId}:${JSON.stringify(filters)}`;
    const cached = await this.redis.get(cacheKey);
    if (cached) {
      return JSON.parse(cached);
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
      take: filters.take || 10,
      skip: filters.skip || 0,
      include: { lineItems: true },
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
      throw new NotFoundException('Order not found');
    }

    return order;
  }

  async create(dto: CreateOrderDto, orgId: string) {
    if (!dto.customerId || !Array.isArray(dto.lineItems) || dto.lineItems.length === 0) {
      throw new Error('Invalid order data');
    }

    const order = await this.prisma.$transaction(async (tx) => {
      const newOrder = await tx.order.create({
        data: {
          customerId: dto.customerId,
          organizationId: orgId,
          currency: dto.currency,
          status: 'pending',
          total: dto.lineItems.reduce((sum, item) => sum + item.quantity * item.unitPrice, 0),
          lineItems: {
            create: dto.lineItems,
          },
        },
        include: { lineItems: true },
      });

      await this.emitAuditLog(orgId, 'ORDER_CREATED', newOrder.id);
      return newOrder;
    });

    await this.invalidateCache(orgId);
    return order;
  }

  async deleteOrder(id: string, orgId: string) {
    const order = await this.findById(id, orgId);

    await this.prisma.$transaction(async (tx) => {
      await tx.lineItem.deleteMany({ where: { orderId: id } });
      await tx.order.delete({ where: { id } });
    });

    await this.emitAuditLog(orgId, 'ORDER_DELETED', id);
    await this.invalidateCache(orgId);
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string) {
    const order = await this.findById(id, orgId);

    if (!this.isValidTransition(order.status, newStatus)) {
      throw new Error(`Invalid status transition from ${order.status} to ${newStatus}`);
    }

    const updated = await this.prisma.order.update({
      where: { id },
      data: { status: newStatus },
    });

    if (newStatus === 'shipped') {
      try {
        await this.email.sendEmail(order.customerId, 'Order Shipped', `Your order ${id} has been shipped`);
      } catch (error) {
        console.error('Email send failed:', error);
      }
    }

    await this.emitAuditLog(orgId, 'ORDER_STATUS_UPDATED', id, { newStatus });
    await this.invalidateCache(orgId);

    return updated;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string) {
    const startOfMonth = new Date(month.getFullYear(), month.getMonth(), 1);
    const endOfMonth = new Date(month.getFullYear(), month.getMonth() + 1, 0);

    const orders = await this.prisma.order.findMany({
      where: {
        organizationId: orgId,
        createdAt: { gte: startOfMonth, lte: endOfMonth },
        status: { in: ['shipped', 'delivered'] },
      },
    });

    const grouped = orders.reduce(
      (acc, order) => {
        const existing = acc.find((r) => r.currency === order.currency);
        if (existing) {
          existing.total += order.total;
        } else {
          acc.push({ currency: order.currency, total: order.total });
        }
        return acc;
      },
      [] as Array<{ currency: string; total: number }>,
    );

    return grouped;
  }

  async bulkUpdateStatus(ids: string[], newStatus: OrderStatus, orgId: string) {
    let updated = 0;

    for (const id of ids) {
      try {
        const order = await this.prisma.order.findUnique({
          where: { id },
        });
        if (order && order.organizationId === orgId && this.isValidTransition(order.status, newStatus)) {
          await this.prisma.order.update({
            where: { id },
            data: { status: newStatus },
          });
          updated++;
        }
      } catch {
        // Skip invalid transitions silently
      }
    }

    await this.emitAuditLog(orgId, 'BULK_STATUS_UPDATE', JSON.stringify(ids), { count: updated });
    await this.invalidateCache(orgId);

    return updated;
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string) {
    const maxRows = 10000;
    const where: any = { organizationId: orgId };

    if (filters.status) where.status = filters.status;
    if (filters.dateRange) {
      where.createdAt = {
        gte: filters.dateRange.from,
        lte: filters.dateRange.to,
      };
    }

    const orders = await this.prisma.order.findMany({
      where,
      take: maxRows,
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
    });

    return orders;
  }

  private isValidTransition(from: OrderStatus, to: OrderStatus): boolean {
    const transitions: Record<OrderStatus, OrderStatus[]> = {
      pending: ['confirmed', 'cancelled'],
      confirmed: ['processing', 'cancelled'],
      processing: ['shipped', 'cancelled'],
      shipped: ['delivered'],
      delivered: [],
      cancelled: [],
    };

    return transitions[from]?.includes(to) || false;
  }

  private async invalidateCache(orgId: string) {
    const pattern = `orders:${orgId}:*`;
    // In real Redis, would use SCAN pattern matching
    // For simplicity, just clear the main key
    await this.redis.del(`orders:${orgId}:*`);
  }

  private async emitAuditLog(orgId: string, action: string, resourceId: string, metadata?: any) {
    // Stub for audit logging
    console.log(`[AUDIT] ${orgId}: ${action} on ${resourceId}`, metadata);
  }
}
