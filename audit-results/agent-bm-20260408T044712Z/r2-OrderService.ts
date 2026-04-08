import { Injectable, NotFoundException, BadRequestException, ConflictException } from '@nestjs/common';
import { PrismaService } from './prisma.service';
import { RedisService } from './redis.service';
import { EmailService } from './email.service';
import { PaymentGateway } from './payment-gateway';

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

const EXPORT_MAX_ROWS = 10_000;
const CACHE_TTL_SECONDS = 60;
const ORDER_CACHE_PREFIX = 'orders:list:';

@Injectable()
export class OrderService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly email: EmailService,
    private readonly paymentGateway: PaymentGateway,
  ) {}

  private auditLog(action: string, payload: Record<string, unknown>): void {
    void Promise.resolve().then(() => {
      // eslint-disable-next-line no-console
      console.info(`[audit] ${action}`, payload);
    });
  }

  private safeInvalidateOrderCaches(orgId: string): void {
    void this.invalidateOrderCaches(orgId).catch((err: unknown) => {
      // eslint-disable-next-line no-console
      console.error('[redis] cache invalidation failed (best-effort)', err);
    });
  }

  private normalizeDateRange(range?: { from: Date; to: Date }): { from: Date; to: Date } | undefined {
    if (!range) return undefined;
    const fromT = range.from.getTime();
    const toT = range.to.getTime();
    if (!Number.isFinite(fromT) || !Number.isFinite(toT)) {
      throw new BadRequestException('dateRange contains invalid dates');
    }
    if (fromT > toT) {
      throw new BadRequestException('dateRange.from must be before or equal to dateRange.to');
    }
    return range;
  }

  private cacheKeyForList(orgId: string, filters: OrderFilters): string {
    const dr = this.normalizeDateRange(filters.dateRange);
    const stable = JSON.stringify({
      orgId,
      status: filters.status ?? null,
      from: dr?.from.toISOString() ?? null,
      to: dr?.to.toISOString() ?? null,
      customerId: filters.customerId ?? null,
      take: filters.take ?? null,
      skip: filters.skip ?? null,
    });
    return `${ORDER_CACHE_PREFIX}${orgId}:${Buffer.from(stable).toString('base64url')}`;
  }

  private async invalidateOrderCaches(orgId: string): Promise<void> {
    await this.redis.delByPattern(`${ORDER_CACHE_PREFIX}${orgId}:*`);
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
        throw new BadRequestException('Each line item requires productId');
      }
      if (!Number.isFinite(li.quantity) || li.quantity <= 0 || !Number.isInteger(li.quantity)) {
        throw new BadRequestException('quantity must be a positive integer');
      }
      if (!Number.isFinite(li.unitPrice) || li.unitPrice < 0) {
        throw new BadRequestException('unitPrice must be a non-negative finite number');
      }
    }
  }

  private isValidTransition(from: OrderStatus, to: OrderStatus): boolean {
    if (to === 'cancelled') {
      return from !== 'delivered';
    }
    const order: OrderStatus[] = [
      'pending',
      'confirmed',
      'processing',
      'shipped',
      'delivered',
    ];
    const i = order.indexOf(from);
    const j = order.indexOf(to);
    if (i === -1 || j === -1) return false;
    return j === i + 1;
  }

  private parseCachedOrders(cached: string): unknown {
    try {
      return JSON.parse(cached, (key, value) => {
        if (
          (key === 'createdAt' || key === 'updatedAt') &&
          typeof value === 'string'
        ) {
          const d = new Date(value);
          return Number.isFinite(d.getTime()) ? d : value;
        }
        return value;
      });
    } catch {
      return null;
    }
  }

  async findAll(filters: OrderFilters, orgId: string) {
    const take = Math.min(Math.max(filters.take ?? 50, 1), 500);
    const skip = Math.max(filters.skip ?? 0, 0);
    const key = this.cacheKeyForList(orgId, { ...filters, take, skip });
    const cached = await this.redis.get(key);
    if (cached) {
      const parsed = this.parseCachedOrders(cached);
      if (parsed !== null) {
        return parsed as unknown;
      }
      await this.redis.del(key).catch(() => undefined);
    }

    const dr = this.normalizeDateRange(filters.dateRange);
    const where: Record<string, unknown> = { organizationId: orgId };
    if (filters.status) where.status = filters.status;
    if (filters.customerId) where.customerId = filters.customerId;
    if (dr) {
      where.createdAt = {
        gte: dr.from,
        lte: dr.to,
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
      throw new NotFoundException(`Order ${id} not found for organization`);
    }
    return order;
  }

  async create(dto: CreateOrderDto, orgId: string) {
    this.validateCreateDto(dto);
    const totalAmount = dto.lineItems.reduce(
      (sum, li) => sum + li.quantity * li.unitPrice,
      0,
    );

    await (this.paymentGateway as { ensureOrgActive?: (o: string) => Promise<void> }).ensureOrgActive?.(
      orgId,
    );

    const created = await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.create({
        data: {
          organizationId: orgId,
          customerId: dto.customerId,
          currency: dto.currency,
          status: 'pending',
          totalAmount,
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

    this.safeInvalidateOrderCaches(orgId);
    this.auditLog('order.create', { orgId, orderId: created.id });
    return created;
  }

  async deleteOrder(id: string, orgId: string) {
    await this.prisma.$transaction(async (tx) => {
      const existing = await tx.order.findFirst({
        where: { id, organizationId: orgId },
      });
      if (!existing) {
        throw new NotFoundException(`Order ${id} not found for organization`);
      }
      await tx.payment.deleteMany({ where: { orderId: id } });
      await tx.orderLineItem.deleteMany({ where: { orderId: id } });
      const del = await tx.order.deleteMany({ where: { id, organizationId: orgId } });
      if (del.count !== 1) {
        throw new ConflictException('Order could not be deleted');
      }
    });

    this.safeInvalidateOrderCaches(orgId);
    this.auditLog('order.delete', { orgId, orderId: id });
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string) {
    let emailPayload: { orderId: string; orgId: string } | null = null;

    await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.findFirst({
        where: { id, organizationId: orgId },
      });
      if (!order) {
        throw new NotFoundException(`Order ${id} not found for organization`);
      }

      const current = order.status as OrderStatus;
      if (!this.isValidTransition(current, newStatus)) {
        throw new BadRequestException(
          `Invalid status transition from ${current} to ${newStatus}`,
        );
      }

      const updated = await tx.order.updateMany({
        where: { id, organizationId: orgId, status: current },
        data: { status: newStatus },
      });

      if (updated.count !== 1) {
        throw new ConflictException(
          'Order status changed concurrently; retry status update',
        );
      }

      if (newStatus === 'shipped') {
        emailPayload = { orderId: id, orgId };
      }
    });

    if (emailPayload) {
      await this.email
        .sendShippingNotification(emailPayload)
        .catch((err: unknown) => {
          // eslint-disable-next-line no-console
          console.error('[email] shipping notification failed', err);
        });
    }

    this.safeInvalidateOrderCaches(orgId);
    this.auditLog('order.status', { orgId, orderId: id, newStatus });

    const fresh = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
    });
    if (!fresh) {
      throw new NotFoundException(`Order ${id} not found for organization`);
    }
    return fresh;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string) {
    const start = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), 1));
    const end = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 1));

    const aggregates = await this.prisma.order.groupBy({
      by: ['currency'],
      where: {
        organizationId: orgId,
        createdAt: { gte: start, lt: end },
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
    let updated = 0;
    await this.prisma.$transaction(async (tx) => {
      for (const id of ids) {
        const order = await tx.order.findFirst({
          where: { id, organizationId: orgId },
        });
        if (!order) continue;
        const current = order.status as OrderStatus;
        if (!this.isValidTransition(current, newStatus)) continue;
        const r = await tx.order.updateMany({
          where: { id, organizationId: orgId, status: current },
          data: { status: newStatus },
        });
        if (r.count === 1) updated += 1;
      }
    });

    if (updated > 0) {
      this.safeInvalidateOrderCaches(orgId);
      this.auditLog('order.bulk_status', { orgId, count: updated, newStatus });
    }
    return updated;
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string) {
    const dr = this.normalizeDateRange(filters.dateRange);
    const where: Record<string, unknown> = { organizationId: orgId };
    if (filters.status) where.status = filters.status;
    if (dr) {
      where.createdAt = {
        gte: dr.from,
        lte: dr.to,
      };
    }

    return this.prisma.order.findMany({
      where,
      take: EXPORT_MAX_ROWS,
      orderBy: { createdAt: 'asc' },
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
    });
  }
}
