// FILE: OrderService.ts
import { Injectable, NotFoundException, BadRequestException, ConflictException } from '@nestjs/common';

// --- Types ---

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

// --- State Machine ---

const VALID_TRANSITIONS: Record<OrderStatus, OrderStatus[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['processing', 'cancelled'],
  processing: ['shipped', 'cancelled'],
  shipped: ['delivered', 'cancelled'],
  delivered: [],
  cancelled: [],
};

const NON_DELETABLE_STATUSES: OrderStatus[] = ['shipped', 'delivered'];

const MAX_BULK_IDS = 100;

// --- Service ---

@Injectable()
export class OrderService {
  private readonly CACHE_TTL = 300; // 5 minutes
  private readonly CACHE_VERSION_KEY_PREFIX = 'orders:version:';
  private readonly MAX_EXPORT_ROWS = 10_000;

  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly email: EmailService,
    private readonly paymentGateway: PaymentGateway,
  ) {}

  // --- Queries ---

  async findAll(filters: OrderFilters, orgId: string) {
    this.validateOrgId(orgId);
    const take = this.clampPagination(filters.take, 1, 100, 20);
    const skip = this.clampPagination(filters.skip, 0, 10_000, 0);

    const version = await this.getCacheVersion(orgId);
    const cacheKey = this.buildListCacheKey(orgId, version, filters, take, skip);
    const cached = await this.getCached(cacheKey);
    if (cached) return cached;

    const where = this.buildWhereClause(filters, orgId);
    const [items, total] = await Promise.all([
      this.prisma.order.findMany({
        where,
        take,
        skip,
        include: { lineItems: true },
        orderBy: { createdAt: 'desc' },
      }),
      this.prisma.order.count({ where }),
    ]);

    const result = { items, total, take, skip };
    await this.setCache(cacheKey, result);
    return result;
  }

  async findById(id: string, orgId: string) {
    this.validateOrgId(orgId);
    const version = await this.getCacheVersion(orgId);
    const cacheKey = this.buildItemCacheKey(orgId, version, id);
    const cached = await this.getCached(cacheKey);
    if (cached) return cached;

    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
      include: { lineItems: true, customer: true, payments: true },
    });

    if (!order) {
      throw new NotFoundException(`Order ${id} not found in organization ${orgId}`);
    }

    await this.setCache(cacheKey, order);
    return order;
  }

  // --- Mutations ---

  async create(dto: CreateOrderDto, orgId: string) {
    this.validateOrgId(orgId);
    this.validateCreateDto(dto);

    const order = await this.prisma.$transaction(async (tx) => {
      const totalAmount = dto.lineItems.reduce(
        (sum, item) => sum + item.quantity * item.unitPrice,
        0,
      );

      const created = await tx.order.create({
        data: {
          customerId: dto.customerId,
          organizationId: orgId,
          status: 'pending',
          currency: dto.currency,
          totalAmount,
          lineItems: {
            create: dto.lineItems.map((item) => ({
              productId: item.productId,
              quantity: item.quantity,
              unitPrice: item.unitPrice,
              subtotal: item.quantity * item.unitPrice,
            })),
          },
        },
        include: { lineItems: true },
      });

      await tx.auditLog.create({
        data: {
          action: 'ORDER_CREATED',
          entityId: created.id,
          entityType: 'Order',
          organizationId: orgId,
          metadata: { customerId: dto.customerId, totalAmount },
        },
      });

      return created;
    });

    await this.invalidateCache(orgId);
    return order;
  }

  async deleteOrder(id: string, orgId: string) {
    this.validateOrgId(orgId);

    await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.findFirst({
        where: { id, organizationId: orgId },
      });

      if (!order) {
        throw new NotFoundException(`Order ${id} not found in organization ${orgId}`);
      }

      // Guard: cannot delete shipped or delivered orders
      if (NON_DELETABLE_STATUSES.includes(order.status as OrderStatus)) {
        throw new ConflictException(
          `Cannot delete order in '${order.status}' status`,
        );
      }

      await tx.lineItem.deleteMany({ where: { orderId: id } });
      await tx.order.delete({ where: { id } });

      await tx.auditLog.create({
        data: {
          action: 'ORDER_DELETED',
          entityId: id,
          entityType: 'Order',
          organizationId: orgId,
          metadata: { deletedStatus: order.status },
        },
      });
    });

    await this.invalidateCache(orgId);
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string) {
    this.validateOrgId(orgId);

    const order = await this.prisma.$transaction(async (tx) => {
      const current = await tx.order.findFirst({
        where: { id, organizationId: orgId },
      });

      if (!current) {
        throw new NotFoundException(`Order ${id} not found in organization ${orgId}`);
      }

      const allowed = VALID_TRANSITIONS[current.status as OrderStatus];
      if (!allowed || !allowed.includes(newStatus)) {
        throw new ConflictException(
          `Cannot transition order from '${current.status}' to '${newStatus}'`,
        );
      }

      // TOCTOU protection: updateMany with status WHERE clause
      const result = await tx.order.updateMany({
        where: { id, organizationId: orgId, status: current.status },
        data: { status: newStatus },
      });

      if (result.count === 0) {
        throw new ConflictException(
          `Order ${id} status changed concurrently, please retry`,
        );
      }

      await tx.auditLog.create({
        data: {
          action: 'ORDER_STATUS_CHANGED',
          entityId: id,
          entityType: 'Order',
          organizationId: orgId,
          metadata: { from: current.status, to: newStatus },
        },
      });

      // Re-fetch to return fresh data with all relations
      return tx.order.findFirstOrThrow({
        where: { id },
        include: { lineItems: true, customer: true, payments: true },
      });
    });

    // Send email notification on shipped — never let email failure break the flow
    if (newStatus === 'shipped') {
      await this.email
        .sendShippingNotification(order.customerId, order.id)
        .catch((err: Error) => {
          console.error(`Failed to send shipping email for order ${id}:`, {
            error: err.message,
            orderId: id,
            customerId: order.customerId,
          });
        });
    }

    await this.invalidateCache(orgId);
    return order;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string) {
    this.validateOrgId(orgId);

    // Use UTC boundaries to avoid timezone-dependent date shifts
    const year = month.getUTCFullYear();
    const monthIndex = month.getUTCMonth();
    const startOfMonth = new Date(Date.UTC(year, monthIndex, 1));
    const endOfMonth = new Date(Date.UTC(year, monthIndex + 1, 0, 23, 59, 59, 999));

    const result = await this.prisma.order.groupBy({
      by: ['currency'],
      where: {
        organizationId: orgId,
        status: { not: 'cancelled' },
        createdAt: { gte: startOfMonth, lte: endOfMonth },
      },
      _sum: { totalAmount: true },
    });

    return result.map((row) => ({
      currency: row.currency,
      total: row._sum.totalAmount ?? 0,
    }));
  }

  async bulkUpdateStatus(ids: string[], newStatus: OrderStatus, orgId: string) {
    this.validateOrgId(orgId);

    if (!ids.length) return { updatedCount: 0 };

    if (ids.length > MAX_BULK_IDS) {
      throw new BadRequestException(
        `Maximum ${MAX_BULK_IDS} orders per bulk update, received ${ids.length}`,
      );
    }

    let updatedCount = 0;

    await this.prisma.$transaction(async (tx) => {
      for (const id of ids) {
        const order = await tx.order.findFirst({
          where: { id, organizationId: orgId },
        });

        if (!order) continue;

        const allowed = VALID_TRANSITIONS[order.status as OrderStatus];
        if (!allowed || !allowed.includes(newStatus)) continue;

        const result = await tx.order.updateMany({
          where: { id, organizationId: orgId, status: order.status },
          data: { status: newStatus },
        });

        if (result.count > 0) {
          updatedCount += result.count;

          await tx.auditLog.create({
            data: {
              action: 'ORDER_STATUS_CHANGED',
              entityId: id,
              entityType: 'Order',
              organizationId: orgId,
              metadata: { from: order.status, to: newStatus, bulk: true },
            },
          });
        }
      }
    });

    await this.invalidateCache(orgId);
    return { updatedCount };
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string) {
    this.validateOrgId(orgId);

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

    const [items, total] = await Promise.all([
      this.prisma.order.findMany({
        where,
        take: this.MAX_EXPORT_ROWS,
        include: { lineItems: true, customer: true, payments: true },
        orderBy: { createdAt: 'desc' },
      }),
      this.prisma.order.count({ where }),
    ]);

    return {
      items,
      total,
      truncated: total > this.MAX_EXPORT_ROWS,
    };
  }

  // --- Private Helpers ---

  private validateOrgId(orgId: string) {
    if (!orgId || typeof orgId !== 'string' || !orgId.trim()) {
      throw new BadRequestException('organizationId is required');
    }
  }

  private validateCreateDto(dto: CreateOrderDto) {
    if (!dto.customerId || typeof dto.customerId !== 'string' || !dto.customerId.trim()) {
      throw new BadRequestException('customerId is required');
    }

    if (!dto.currency || typeof dto.currency !== 'string' || !dto.currency.trim()) {
      throw new BadRequestException('currency is required');
    }

    if (dto.currency.trim().length < 3 || dto.currency.trim().length > 3) {
      throw new BadRequestException('currency must be a 3-letter code');
    }

    if (!Array.isArray(dto.lineItems) || dto.lineItems.length === 0) {
      throw new BadRequestException('At least one line item is required');
    }

    for (const item of dto.lineItems) {
      if (!item.productId || typeof item.productId !== 'string') {
        throw new BadRequestException('Each line item must have a productId');
      }
      if (
        typeof item.quantity !== 'number' ||
        !Number.isFinite(item.quantity) ||
        !Number.isInteger(item.quantity) ||
        item.quantity <= 0
      ) {
        throw new BadRequestException(
          'Each line item quantity must be a positive finite integer',
        );
      }
      if (
        typeof item.unitPrice !== 'number' ||
        !Number.isFinite(item.unitPrice) ||
        item.unitPrice < 0
      ) {
        throw new BadRequestException(
          'Each line item unitPrice must be a non-negative finite number',
        );
      }
    }
  }

  private clampPagination(value: number | undefined, min: number, max: number, fallback: number): number {
    if (value === undefined || value === null) return fallback;
    if (typeof value !== 'number' || !Number.isFinite(value)) return fallback;
    return Math.max(min, Math.min(max, Math.floor(value)));
  }

  private buildWhereClause(filters: OrderFilters, orgId: string) {
    const where: Record<string, unknown> = { organizationId: orgId };

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

    return where;
  }

  // --- Cache Helpers (Redis-based versioning) ---

  private async getCacheVersion(orgId: string): Promise<number> {
    try {
      const val = await this.redis.get(`${this.CACHE_VERSION_KEY_PREFIX}${orgId}`);
      return val ? parseInt(val, 10) : 0;
    } catch {
      return 0;
    }
  }

  private buildListCacheKey(
    orgId: string,
    version: number,
    filters: OrderFilters,
    take: number,
    skip: number,
  ): string {
    const parts = [
      `orders:v${version}:${orgId}:list`,
      filters.status ?? '',
      filters.customerId ?? '',
      filters.dateRange
        ? `${filters.dateRange.from.toISOString()}-${filters.dateRange.to.toISOString()}`
        : '',
      `${take}:${skip}`,
    ];
    return parts.join(':');
  }

  private buildItemCacheKey(orgId: string, version: number, id: string): string {
    return `orders:v${version}:${orgId}:item:${id}`;
  }

  private async getCached<T>(key: string): Promise<T | null> {
    try {
      const raw = await this.redis.get(key);
      if (!raw) return null;

      const parsed = JSON.parse(raw);
      return this.reviveDates(parsed) as T;
    } catch {
      // Malformed cache — treat as miss
      return null;
    }
  }

  private async setCache(key: string, value: unknown): Promise<void> {
    try {
      await this.redis.set(key, JSON.stringify(value), 'EX', this.CACHE_TTL);
    } catch (err) {
      console.error(`Cache set failed for key ${key}: ${(err as Error).message}`);
    }
  }

  private async invalidateCache(orgId: string): Promise<void> {
    try {
      // Atomic increment in Redis — all instances see the new version immediately
      await this.redis.incr(`${this.CACHE_VERSION_KEY_PREFIX}${orgId}`);
    } catch (err) {
      console.error(`Cache version increment failed for org ${orgId}: ${(err as Error).message}`);
    }
  }

  private reviveDates(obj: unknown): unknown {
    if (typeof obj === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(obj)) {
      const d = new Date(obj);
      return isNaN(d.getTime()) ? obj : d;
    }
    if (Array.isArray(obj)) {
      return obj.map((item) => this.reviveDates(item));
    }
    if (obj && typeof obj === 'object') {
      const result: Record<string, unknown> = {};
      for (const [key, value] of Object.entries(obj)) {
        result[key] = this.reviveDates(value);
      }
      return result;
    }
    return obj;
  }
}
