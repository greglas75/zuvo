import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
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

/** Single source of truth — includes cancellation from any non-delivered state (spec). */
const VALID_TRANSITIONS: Record<OrderStatus, OrderStatus[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['processing', 'cancelled'],
  processing: ['shipped', 'cancelled'],
  shipped: ['delivered', 'cancelled'],
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

  private stableStringify(value: unknown): string {
    if (value === null || typeof value !== 'object') {
      return JSON.stringify(value);
    }
    if (value instanceof Date) {
      return value.toISOString();
    }
    if (Array.isArray(value)) {
      return `[${value.map((v) => this.stableStringify(v)).join(',')}]`;
    }
    const obj = value as Record<string, unknown>;
    const keys = Object.keys(obj).sort();
    const parts = keys.map((k) => `${JSON.stringify(k)}:${this.stableStringify(obj[k])}`);
    return `{${parts.join(',')}}`;
  }

  private cacheKey(orgId: string, filters: OrderFilters): string {
    return `${CACHE_PREFIX}${orgId}:${this.stableStringify(filters)}`;
  }

  private async invalidateOrderCaches(orgId: string): Promise<void> {
    const pattern = `${CACHE_PREFIX}${orgId}:*`;
    await this.redis.delByPattern(pattern);
  }

  private emitAuditLog(action: string, orgId: string, payload: Record<string, unknown>): void {
    void this.prisma.auditLog
      .create({
        data: {
          action,
          organizationId: orgId,
          payload: payload as object,
        },
      })
      .catch((err: unknown) => {
        console.error('[audit]', action, orgId, err);
      });
  }

  private validatePagination(filters: OrderFilters): { take: number; skip: number } {
    const rawTake = filters.take ?? 50;
    const rawSkip = filters.skip ?? 0;
    if (!Number.isFinite(rawTake) || !Number.isFinite(rawSkip)) {
      throw new BadRequestException('take and skip must be finite numbers');
    }
    const take = Math.max(1, Math.min(Math.floor(rawTake), 500));
    const skip = Math.max(0, Math.floor(rawSkip));
    return { take, skip };
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
    return VALID_TRANSITIONS[from]?.includes(to) ?? false;
  }

  async findAll(filters: OrderFilters, orgId: string) {
    const { take, skip } = this.validatePagination(filters);
    const normalized: OrderFilters = { ...filters, take, skip };
    const key = this.cacheKey(orgId, normalized);

    const cached = await this.redis.get(key);
    if (cached) {
      try {
        return JSON.parse(cached) as unknown[];
      } catch {
        await this.redis.del(key);
      }
    }

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
    await this.paymentGateway.ensureReady();

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
      await tx.lineItem.deleteMany({ where: { orderId: id, order: { organizationId: orgId } } });
      await tx.order.deleteMany({ where: { id, organizationId: orgId } });
    });

    await this.invalidateOrderCaches(orgId);
    this.emitAuditLog('order.deleted', orgId, { orderId: id });
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string) {
    const updated = await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.findFirst({
        where: { id, organizationId: orgId },
      });
      if (!order) {
        throw new NotFoundException(`Order ${id} not found`);
      }
      const current = order.status as OrderStatus;
      if (!this.canTransition(current, newStatus)) {
        throw new BadRequestException(`Invalid status transition from ${current} to ${newStatus}`);
      }

      const result = await tx.order.updateMany({
        where: { id, organizationId: orgId, status: order.status },
        data: { status: newStatus },
      });
      if (result.count === 0) {
        throw new ConflictException('Order was modified by another request; retry');
      }

      const fresh = await tx.order.findFirst({
        where: { id, organizationId: orgId },
      });
      if (!fresh) {
        throw new NotFoundException(`Order ${id} not found`);
      }
      return { order: fresh, previousStatus: current };
    });

    if (newStatus === 'shipped') {
      this.email
        .sendOrderShipped(updated.order.customerId, id)
        .catch((err: unknown) => {
          console.error('Failed to send shipped email', err);
        });
    }

    await this.invalidateOrderCaches(orgId);
    this.emitAuditLog('order.status_updated', orgId, {
      orderId: id,
      from: updated.previousStatus,
      to: newStatus,
    });

    return updated.order;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string) {
    const y = month.getUTCFullYear();
    const m = month.getUTCMonth();
    const start = new Date(Date.UTC(y, m, 1));
    const endExclusive = new Date(Date.UTC(y, m + 1, 1));

    const aggregates = await this.prisma.order.groupBy({
      by: ['currency'],
      where: {
        organizationId: orgId,
        createdAt: { gte: start, lt: endExclusive },
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
    try {
      await this.prisma.$transaction(async (tx) => {
        for (const id of ids) {
          const order = await tx.order.findFirst({
            where: { id, organizationId: orgId },
          });
          if (!order) {
            continue;
          }
          const current = order.status as OrderStatus;
          if (!this.canTransition(current, newStatus)) {
            continue;
          }
          const result = await tx.order.updateMany({
            where: { id, organizationId: orgId, status: order.status },
            data: { status: newStatus },
          });
          if (result.count > 0) {
            count += 1;
            this.emitAuditLog('order.status_bulk', orgId, { orderId: id, to: newStatus });
          }
        }
      });
    } finally {
      await this.invalidateOrderCaches(orgId);
    }
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
