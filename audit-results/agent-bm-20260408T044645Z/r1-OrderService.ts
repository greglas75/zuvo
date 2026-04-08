import { Injectable, NotFoundException, BadRequestException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { RedisService } from '../redis/redis.service';
import { EmailService } from '../email/email.service';
import { PaymentGateway } from '../payment/payment.gateway';

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

const CACHE_PREFIX = 'orders:list:';
const CACHE_TTL_SECONDS = 60;
const EXPORT_MAX_ROWS = 10_000;

const VALID_TRANSITIONS: Record<OrderStatus, OrderStatus[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['processing', 'cancelled'],
  processing: ['shipped', 'cancelled'],
  shipped: ['delivered'],
  delivered: [],
  cancelled: [],
};

@Injectable()
export class OrderService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly email: EmailService,
    private readonly paymentGateway: PaymentGateway,
  ) {}

  private cacheKey(orgId: string, filters: OrderFilters): string {
    return `${CACHE_PREFIX}${orgId}:${JSON.stringify(filters)}`;
  }

  private async invalidateOrderCaches(orgId: string): Promise<void> {
    const pattern = `${CACHE_PREFIX}${orgId}:*`;
    await this.redis.delByPattern(pattern);
  }

  private emitAuditLog(action: string, orgId: string, payload: Record<string, unknown>): void {
    // Structured audit — implementation delegates to org audit sink
    void this.prisma.auditLog
      .create({
        data: {
          action,
          organizationId: orgId,
          payload: payload as object,
        },
      })
      .catch(() => {
        /* logged elsewhere */
      });
  }

  private validateCreateDto(dto: CreateOrderDto): void {
    if (!dto.customerId?.trim()) {
      throw new BadRequestException('customerId is required');
    }
    if (!dto.currency?.trim()) {
      throw new BadRequestException('currency is required');
    }
    if (!dto.lineItems?.length) {
      throw new BadRequestException('lineItems must not be empty');
    }
    for (const li of dto.lineItems) {
      if (!li.productId?.trim()) {
        throw new BadRequestException('Each line item needs productId');
      }
      if (!Number.isFinite(li.quantity) || li.quantity <= 0) {
        throw new BadRequestException('quantity must be a positive number');
      }
      if (!Number.isFinite(li.unitPrice) || li.unitPrice < 0) {
        throw new BadRequestException('unitPrice must be a non-negative number');
      }
    }
  }

  private canTransition(from: OrderStatus, to: OrderStatus): boolean {
    if (to === 'cancelled' && from !== 'delivered') {
      return true;
    }
    return VALID_TRANSITIONS[from]?.includes(to) ?? false;
  }

  async findAll(filters: OrderFilters, orgId: string) {
    const key = this.cacheKey(orgId, filters);
    const cached = await this.redis.get(key);
    if (cached) {
      return JSON.parse(cached) as unknown[];
    }

    const take = Math.min(filters.take ?? 50, 500);
    const skip = filters.skip ?? 0;

    const where: Record<string, unknown> = {
      organizationId: orgId,
    };
    if (filters.status) {
      where.status = filters.status;
    }
    if (filters.customerId) {
      where.customerId = filters.customerId;
    }
    if (filters.dateRange) {
      where.createdAt = {
        gte: filters.dateRange.from,
        lte: filters.dateRange.to,
      };
    }

    const rows = await this.prisma.order.findMany({
      where,
      take,
      skip,
      orderBy: { createdAt: 'desc' },
    });

    await this.redis.set(key, JSON.stringify(rows), CACHE_TTL_SECONDS);
    return rows;
  }

  async findById(id: string, orgId: string) {
    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
    });
    if (!order) {
      throw new NotFoundException(`Order ${id} not found`);
    }
    return order;
  }

  async create(dto: CreateOrderDto, orgId: string) {
    this.validateCreateDto(dto);

    const created = await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.create({
        data: {
          organizationId: orgId,
          customerId: dto.customerId,
          currency: dto.currency,
          status: 'pending',
          lineItems: {
            create: dto.lineItems.map((li) => ({
              productId: li.productId,
              quantity: li.quantity,
              unitPrice: li.unitPrice,
            })),
          },
        },
        include: { lineItems: true },
      });
      return order;
    });

    await this.invalidateOrderCaches(orgId);
    this.emitAuditLog('order.created', orgId, { orderId: created.id });
    return created;
  }

  async deleteOrder(id: string, orgId: string) {
    await this.prisma.$transaction(async (tx) => {
      const existing = await tx.order.findFirst({
        where: { id, organizationId: orgId },
      });
      if (!existing) {
        throw new NotFoundException(`Order ${id} not found`);
      }
      await tx.lineItem.deleteMany({ where: { orderId: id } });
      await tx.order.delete({ where: { id } });
    });

    await this.invalidateOrderCaches(orgId);
    this.emitAuditLog('order.deleted', orgId, { orderId: id });
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string) {
    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
    });
    if (!order) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    if (!this.canTransition(order.status as OrderStatus, newStatus)) {
      throw new BadRequestException(
        `Invalid status transition from ${order.status} to ${newStatus}`,
      );
    }

    const updated = await this.prisma.order.update({
      where: { id },
      data: { status: newStatus },
    });

    if (newStatus === 'shipped') {
      this.email
        .sendOrderShipped(order.customerId, id)
        .catch((err: unknown) => {
          console.error('Failed to send shipped email', err);
        });
    }

    await this.invalidateOrderCaches(orgId);
    this.emitAuditLog('order.status_updated', orgId, {
      orderId: id,
      from: order.status,
      to: newStatus,
    });

    return updated;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string) {
    const start = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), 1));
    const end = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 0, 23, 59, 59, 999));

    const aggregates = await this.prisma.order.groupBy({
      by: ['currency'],
      where: {
        organizationId: orgId,
        createdAt: { gte: start, lte: end },
        status: { not: 'cancelled' },
      },
      _sum: { totalAmount: true },
    });

    return aggregates.map((a) => ({
      currency: a.currency,
      total: Number(a._sum.totalAmount ?? 0),
    }));
  }

  async bulkUpdateStatus(ids: string[], newStatus: OrderStatus, orgId: string) {
    let count = 0;
    for (const id of ids) {
      const order = await this.prisma.order.findFirst({
        where: { id, organizationId: orgId },
      });
      if (!order) {
        continue;
      }
      if (!this.canTransition(order.status as OrderStatus, newStatus)) {
        continue;
      }
      await this.prisma.order.update({
        where: { id },
        data: { status: newStatus },
      });
      count += 1;
      this.emitAuditLog('order.status_bulk', orgId, { orderId: id, to: newStatus });
    }
    await this.invalidateOrderCaches(orgId);
    return count;
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
      orderBy: { createdAt: 'asc' },
    });
  }
}
