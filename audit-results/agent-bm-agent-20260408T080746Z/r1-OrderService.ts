import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';

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

type RevenueByCurrency = { currency: string; total: number };

type OrderRecord = {
  id: string;
  status: OrderStatus;
  organizationId: string;
  customerId: string;
  currency: string;
  createdAt?: Date;
  updatedAt?: Date;
};

interface PrismaService {
  order: {
    findMany(args: unknown): Promise<OrderRecord[]>;
    findFirst(args: unknown): Promise<OrderRecord | null>;
    create(args: unknown): Promise<OrderRecord>;
    deleteMany(args: unknown): Promise<{ count: number }>;
    updateMany(args: unknown): Promise<{ count: number }>;
  };
  orderLineItem: {
    createMany(args: unknown): Promise<unknown>;
    deleteMany(args: unknown): Promise<unknown>;
  };
  auditLog: {
    create(args: unknown): Promise<unknown>;
  };
  $transaction<T>(fn: (tx: PrismaService) => Promise<T>): Promise<T>;
}

interface RedisService {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, ttlSeconds?: number): Promise<unknown>;
  del(key: string): Promise<unknown>;
  incr(key: string): Promise<number>;
}

interface EmailService {
  sendOrderShipped(args: {
    orderId: string;
    customerId: string;
    organizationId: string;
  }): Promise<unknown>;
}

interface PaymentGateway {
  noop?(): void;
}

@Injectable()
export class OrderService {
  private readonly cacheTtlSeconds = 120;
  private readonly maxListTake = 100;
  private readonly defaultTake = 50;
  private readonly maxExportRows = 10_000;

  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly emailService: EmailService,
    private readonly paymentGateway: PaymentGateway,
  ) {}

  async findAll(filters: OrderFilters, orgId: string): Promise<OrderRecord[]> {
    this.assertOrgId(orgId);
    const normalized = this.normalizeFilters(filters);
    const version = await this.getCacheVersion(orgId);
    const cacheKey = this.buildListCacheKey(orgId, version, normalized);

    const cached = await this.safeCacheGet<OrderRecord[]>(cacheKey);
    if (cached) {
      return cached;
    }

    const where: Record<string, unknown> = {
      organizationId: orgId,
      ...(normalized.status ? { status: normalized.status } : {}),
      ...(normalized.customerId ? { customerId: normalized.customerId } : {}),
      ...(normalized.dateRange
        ? {
            createdAt: {
              gte: normalized.dateRange.from,
              lte: normalized.dateRange.to,
            },
          }
        : {}),
    };

    const rows = await this.prisma.order.findMany({
      where,
      orderBy: { createdAt: 'desc' },
      take: normalized.take,
      skip: normalized.skip,
    });

    await this.safeCacheSet(cacheKey, rows, this.cacheTtlSeconds);
    return rows;
  }

  async findById(id: string, orgId: string): Promise<OrderRecord> {
    this.assertOrgId(orgId);
    this.assertNonEmpty(id, 'id');

    const version = await this.getCacheVersion(orgId);
    const cacheKey = this.buildByIdCacheKey(orgId, version, id);
    const cached = await this.safeCacheGet<OrderRecord>(cacheKey);
    if (cached) {
      return cached;
    }

    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
    });
    if (!order) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    await this.safeCacheSet(cacheKey, order, this.cacheTtlSeconds);
    return order;
  }

  async create(dto: CreateOrderDto, orgId: string): Promise<OrderRecord> {
    this.assertOrgId(orgId);
    this.validateCreateDto(dto);

    const created = await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.create({
        data: {
          organizationId: orgId,
          customerId: dto.customerId,
          currency: dto.currency,
          status: 'pending',
        },
      });

      await tx.orderLineItem.createMany({
        data: dto.lineItems.map((line) => ({
          orderId: order.id,
          productId: line.productId,
          quantity: line.quantity,
          unitPrice: line.unitPrice,
          organizationId: orgId,
        })),
      });

      return order;
    });

    void this.paymentGateway;
    await this.invalidateOrgCache(orgId);
    await this.writeAuditLog('order.created', orgId, created.id, {
      customerId: created.customerId,
      lineItemCount: dto.lineItems.length,
    });

    return created;
  }

  async deleteOrder(id: string, orgId: string): Promise<{ deleted: boolean }> {
    this.assertOrgId(orgId);
    this.assertNonEmpty(id, 'id');

    const result = await this.prisma.$transaction(async (tx) => {
      await tx.orderLineItem.deleteMany({
        where: { orderId: id, organizationId: orgId },
      });
      return tx.order.deleteMany({
        where: { id, organizationId: orgId },
      });
    });

    if (result.count === 0) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    await this.invalidateOrgCache(orgId, id);
    await this.writeAuditLog('order.deleted', orgId, id, {});
    return { deleted: true };
  }

  async updateStatus(
    id: string,
    newStatus: OrderStatus,
    orgId: string,
  ): Promise<OrderRecord> {
    this.assertOrgId(orgId);
    this.assertNonEmpty(id, 'id');

    const current = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
    });

    if (!current) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    if (!this.isValidTransition(current.status, newStatus)) {
      throw new ConflictException(
        `Invalid transition: ${current.status} -> ${newStatus}`,
      );
    }

    const updated = await this.prisma.$transaction(async (tx) => {
      const casResult = await tx.order.updateMany({
        where: {
          id,
          organizationId: orgId,
          status: current.status,
        },
        data: { status: newStatus },
      });

      if (casResult.count !== 1) {
        throw new ConflictException('Order status changed concurrently');
      }

      const order = await tx.order.findFirst({
        where: { id, organizationId: orgId },
      });

      if (!order) {
        throw new NotFoundException(`Order ${id} not found after update`);
      }

      return order;
    });

    if (newStatus === 'shipped') {
      await this.emailService
        .sendOrderShipped({
          orderId: updated.id,
          customerId: updated.customerId,
          organizationId: orgId,
        })
        .catch((error: unknown) => {
          console.error('Failed to send shipped email', error);
        });
    }

    await this.invalidateOrgCache(orgId, id);
    await this.writeAuditLog('order.status_updated', orgId, id, {
      from: current.status,
      to: newStatus,
    });

    return updated;
  }

  async calculateMonthlyRevenue(
    month: Date,
    orgId: string,
  ): Promise<RevenueByCurrency[]> {
    this.assertOrgId(orgId);
    if (!(month instanceof Date) || Number.isNaN(month.getTime())) {
      throw new BadRequestException('month must be a valid date');
    }

    const from = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), 1));
    const to = new Date(
      Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 1),
    );

    const orders = await this.prisma.order.findMany({
      where: {
        organizationId: orgId,
        createdAt: { gte: from, lt: to },
      },
      include: { lineItems: true },
    });

    const bucket = new Map<string, number>();
    for (const order of orders as Array<OrderRecord & { lineItems?: Array<{ quantity: number; unitPrice: number }> }>) {
      const total = (order.lineItems ?? []).reduce(
        (acc, line) => acc + line.quantity * line.unitPrice,
        0,
      );
      bucket.set(order.currency, (bucket.get(order.currency) ?? 0) + total);
    }

    return [...bucket.entries()].map(([currency, total]) => ({ currency, total }));
  }

  async bulkUpdateStatus(
    ids: string[],
    newStatus: OrderStatus,
    orgId: string,
  ): Promise<{ updatedCount: number }> {
    this.assertOrgId(orgId);
    if (!Array.isArray(ids) || ids.length === 0) {
      throw new BadRequestException('ids must be a non-empty array');
    }

    let updatedCount = 0;
    for (const id of ids) {
      if (!id || typeof id !== 'string') {
        continue;
      }

      const current = await this.prisma.order.findFirst({
        where: { id, organizationId: orgId },
        select: { status: true },
      });
      if (!current) {
        continue;
      }
      if (!this.isValidTransition(current.status as OrderStatus, newStatus)) {
        continue;
      }

      const res = await this.prisma.order.updateMany({
        where: {
          id,
          organizationId: orgId,
          status: current.status,
        },
        data: { status: newStatus },
      });
      updatedCount += res.count;
    }

    if (updatedCount > 0) {
      await this.invalidateOrgCache(orgId);
      await this.writeAuditLog('order.bulk_status_updated', orgId, null, {
        ids: ids.length,
        updatedCount,
        to: newStatus,
      });
    }

    return { updatedCount };
  }

  async getOrdersForExport(
    filters: ExportFilters,
    orgId: string,
  ): Promise<Array<Record<string, unknown>>> {
    this.assertOrgId(orgId);

    return this.prisma.order.findMany({
      where: {
        organizationId: orgId,
        ...(filters.status ? { status: filters.status } : {}),
        ...(filters.dateRange
          ? {
              createdAt: {
                gte: filters.dateRange.from,
                lte: filters.dateRange.to,
              },
            }
          : {}),
      },
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      orderBy: { createdAt: 'asc' },
      take: this.maxExportRows,
    });
  }

  private validateCreateDto(dto: CreateOrderDto): void {
    if (!dto || typeof dto !== 'object') {
      throw new BadRequestException('dto is required');
    }

    this.assertNonEmpty(dto.customerId, 'customerId');
    this.assertNonEmpty(dto.currency, 'currency');

    if (!Array.isArray(dto.lineItems) || dto.lineItems.length === 0) {
      throw new BadRequestException('lineItems must be a non-empty array');
    }

    for (const [index, line] of dto.lineItems.entries()) {
      this.assertNonEmpty(line.productId, `lineItems[${index}].productId`);
      this.assertPositiveInteger(line.quantity, `lineItems[${index}].quantity`);
      this.assertFiniteNumberAtLeast(
        line.unitPrice,
        0,
        `lineItems[${index}].unitPrice`,
      );
    }
  }

  private normalizeFilters(filters: OrderFilters): Required<Pick<OrderFilters, 'take' | 'skip'>> & Omit<OrderFilters, 'take' | 'skip'> {
    const take =
      typeof filters.take === 'number'
        ? Math.min(Math.max(Math.trunc(filters.take), 1), this.maxListTake)
        : this.defaultTake;
    const skip =
      typeof filters.skip === 'number'
        ? Math.max(Math.trunc(filters.skip), 0)
        : 0;

    if (filters.dateRange) {
      if (
        !(filters.dateRange.from instanceof Date) ||
        Number.isNaN(filters.dateRange.from.getTime()) ||
        !(filters.dateRange.to instanceof Date) ||
        Number.isNaN(filters.dateRange.to.getTime()) ||
        filters.dateRange.from > filters.dateRange.to
      ) {
        throw new BadRequestException('Invalid dateRange');
      }
    }

    return { ...filters, take, skip };
  }

  private isValidTransition(from: OrderStatus, to: OrderStatus): boolean {
    if (from === to) {
      return true;
    }
    if (to === 'cancelled') {
      return from !== 'delivered';
    }

    const transitions: Record<OrderStatus, OrderStatus[]> = {
      pending: ['confirmed'],
      confirmed: ['processing'],
      processing: ['shipped'],
      shipped: ['delivered'],
      delivered: [],
      cancelled: [],
    };

    return transitions[from].includes(to);
  }

  private async writeAuditLog(
    action: string,
    orgId: string,
    orderId: string | null,
    metadata: Record<string, unknown>,
  ): Promise<void> {
    try {
      await this.prisma.auditLog.create({
        data: {
          action,
          organizationId: orgId,
          orderId,
          metadata,
        },
      });
    } catch (error) {
      console.error('Audit log write failed', error);
    }
  }

  private async getCacheVersion(orgId: string): Promise<number> {
    const key = this.buildVersionKey(orgId);
    const raw = await this.redis.get(key).catch(() => null);
    const parsed = raw ? Number.parseInt(raw, 10) : 1;
    if (Number.isFinite(parsed) && parsed > 0) {
      return parsed;
    }
    return 1;
  }

  private async invalidateOrgCache(orgId: string, id?: string): Promise<void> {
    const versionKey = this.buildVersionKey(orgId);
    await this.redis.incr(versionKey).catch(async () => {
      await this.redis.set(versionKey, '2', 86400).catch(() => null);
    });

    if (id) {
      const version = await this.getCacheVersion(orgId);
      await this.redis.del(this.buildByIdCacheKey(orgId, version, id)).catch(() => null);
    }
  }

  private buildVersionKey(orgId: string): string {
    return `orders:version:${orgId}`;
  }

  private buildByIdCacheKey(orgId: string, version: number, id: string): string {
    return `orders:${orgId}:v${version}:id:${id}`;
  }

  private buildListCacheKey(
    orgId: string,
    version: number,
    filters: OrderFilters,
  ): string {
    const serialized = JSON.stringify({
      ...filters,
      dateRange: filters.dateRange
        ? {
            from: filters.dateRange.from.toISOString(),
            to: filters.dateRange.to.toISOString(),
          }
        : undefined,
    });
    return `orders:${orgId}:v${version}:list:${this.hashString(serialized)}`;
  }

  private hashString(input: string): string {
    let hash = 0;
    for (let i = 0; i < input.length; i += 1) {
      hash = (hash << 5) - hash + input.charCodeAt(i);
      hash |= 0;
    }
    return Math.abs(hash).toString(36);
  }

  private async safeCacheGet<T>(key: string): Promise<T | null> {
    const raw = await this.redis.get(key).catch(() => null);
    if (!raw) {
      return null;
    }

    try {
      return this.reviveDates(JSON.parse(raw)) as T;
    } catch {
      await this.redis.del(key).catch(() => null);
      return null;
    }
  }

  private async safeCacheSet(
    key: string,
    payload: unknown,
    ttlSeconds: number,
  ): Promise<void> {
    await this.redis
      .set(key, JSON.stringify(payload), ttlSeconds)
      .catch((error: unknown) => {
        console.error('Cache set failed', error);
      });
  }

  private reviveDates<T>(value: T): T {
    if (Array.isArray(value)) {
      return value.map((item) => this.reviveDates(item)) as T;
    }
    if (value && typeof value === 'object') {
      const out: Record<string, unknown> = {};
      for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
        if (
          typeof item === 'string' &&
          key.toLowerCase().includes('at') &&
          /^\d{4}-\d{2}-\d{2}T/.test(item)
        ) {
          out[key] = new Date(item);
        } else {
          out[key] = this.reviveDates(item);
        }
      }
      return out as T;
    }

    return value;
  }

  private assertOrgId(orgId: string): void {
    this.assertNonEmpty(orgId, 'orgId');
  }

  private assertNonEmpty(value: unknown, field: string): void {
    if (typeof value !== 'string' || value.trim() === '') {
      throw new BadRequestException(`${field} must be a non-empty string`);
    }
  }

  private assertPositiveInteger(value: unknown, field: string): void {
    if (
      typeof value !== 'number' ||
      !Number.isInteger(value) ||
      !Number.isFinite(value) ||
      value <= 0
    ) {
      throw new BadRequestException(`${field} must be a positive integer`);
    }
  }

  private assertFiniteNumberAtLeast(
    value: unknown,
    minimum: number,
    field: string,
  ): void {
    if (
      typeof value !== 'number' ||
      !Number.isFinite(value) ||
      Number.isNaN(value) ||
      value < minimum
    ) {
      throw new BadRequestException(`${field} must be a finite number >= ${minimum}`);
    }
  }
}
