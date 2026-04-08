import {
  BadRequestException,
  ConflictException,
  Injectable,
  InternalServerErrorException,
  NotFoundException,
} from '@nestjs/common';
import { createHash } from 'crypto';

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
    findMany(args: unknown): Promise<Array<{ quantity: number; unitPrice: number; order: { currency: string } }>>;
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
  authorize?(args: {
    organizationId: string;
    customerId: string;
    currency: string;
    amount: number;
  }): Promise<unknown>;
}

@Injectable()
export class OrderService {
  private readonly cacheTtlSeconds = 120;
  private readonly maxListTake = 100;
  private readonly defaultTake = 50;
  private readonly maxBulkIds = 500;
  private readonly maxExportRows = 10_000;

  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly emailService: EmailService,
    private readonly paymentGateway: PaymentGateway,
  ) {}

  async findAll(filters: OrderFilters = {}, orgId: string): Promise<OrderRecord[]> {
    this.assertOrgId(orgId);
    const normalized = this.normalizeFilters(filters);

    const version = await this.getCacheVersion(orgId);
    const cacheKey =
      version === null ? null : this.buildListCacheKey(orgId, version, normalized);

    if (cacheKey) {
      const cached = await this.safeCacheGet<OrderRecord[]>(cacheKey);
      if (cached) {
        return cached;
      }
    }

    const rows = await this.prisma.order.findMany({
      where: this.buildWhere(normalized, orgId),
      orderBy: { createdAt: 'desc' },
      take: normalized.take,
      skip: normalized.skip,
    });

    if (cacheKey) {
      await this.safeCacheSet(cacheKey, rows, this.cacheTtlSeconds);
    }
    return rows;
  }

  async findById(id: string, orgId: string): Promise<OrderRecord> {
    this.assertOrgId(orgId);
    this.assertNonEmpty(id, 'id');

    const version = await this.getCacheVersion(orgId);
    const cacheKey =
      version === null ? null : this.buildByIdCacheKey(orgId, version, id);

    if (cacheKey) {
      const cached = await this.safeCacheGet<OrderRecord>(cacheKey);
      if (cached) {
        return cached;
      }
    }

    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
    });
    if (!order) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    if (cacheKey) {
      await this.safeCacheSet(cacheKey, order, this.cacheTtlSeconds);
    }
    return order;
  }

  async create(dto: CreateOrderDto, orgId: string): Promise<OrderRecord> {
    this.assertOrgId(orgId);
    this.validateCreateDto(dto);

    const authorizedTotal = dto.lineItems.reduce(
      (acc, line) => acc + Math.round(line.unitPrice * 100) * line.quantity,
      0,
    );
    if (this.paymentGateway.authorize) {
      await this.paymentGateway.authorize({
        organizationId: orgId,
        customerId: dto.customerId,
        currency: dto.currency,
        amount: authorizedTotal,
      });
    }

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

      await this.writeAuditLogOrThrow(tx, 'order.created', orgId, order.id, {
        customerId: dto.customerId,
        lineItemCount: dto.lineItems.length,
      });

      return order;
    });

    await this.invalidateOrgCache(orgId);
    return created;
  }

  async deleteOrder(id: string, orgId: string): Promise<{ deleted: boolean }> {
    this.assertOrgId(orgId);
    this.assertNonEmpty(id, 'id');

    await this.prisma.$transaction(async (tx) => {
      const existing = await tx.order.findFirst({
        where: { id, organizationId: orgId },
        select: { id: true },
      });
      if (!existing) {
        throw new NotFoundException(`Order ${id} not found`);
      }

      await tx.order.deleteMany({ where: { id, organizationId: orgId } });
      await tx.orderLineItem.deleteMany({ where: { orderId: id, organizationId: orgId } });

      await this.writeAuditLogOrThrow(tx, 'order.deleted', orgId, id, {});
    });

    await this.invalidateOrgCache(orgId, id);
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
      select: { status: true },
    });
    if (!current) {
      throw new NotFoundException(`Order ${id} not found`);
    }
    if (!this.isValidTransition(current.status as OrderStatus, newStatus)) {
      throw new ConflictException(
        `Invalid transition: ${current.status} -> ${newStatus}`,
      );
    }

    const updated = await this.prisma.$transaction(async (tx) => {
      const cas = await tx.order.updateMany({
        where: { id, organizationId: orgId, status: current.status },
        data: { status: newStatus },
      });
      if (cas.count !== 1) {
        throw new ConflictException('Order status changed concurrently');
      }

      const row = await tx.order.findFirst({ where: { id, organizationId: orgId } });
      if (!row) {
        throw new NotFoundException(`Order ${id} not found`);
      }

      await this.writeAuditLogOrThrow(tx, 'order.status_updated', orgId, id, {
        from: current.status,
        to: newStatus,
      });
      return row;
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
    const to = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 1));

    const totalsInCents = new Map<string, number>();
    const pageSize = 1000;
    let skip = 0;

    while (true) {
      const lineItems = await this.prisma.orderLineItem.findMany({
        where: {
          organizationId: orgId,
          order: {
            createdAt: { gte: from, lt: to },
            status: { in: ['shipped', 'delivered'] },
          },
        },
        include: {
          order: { select: { currency: true } },
        },
        take: pageSize,
        skip,
      });

      if (lineItems.length === 0) {
        break;
      }

      for (const item of lineItems) {
        const lineTotalCents =
          Math.round(item.unitPrice * 100) * Math.trunc(item.quantity);
        const currency = item.order.currency;
        totalsInCents.set(currency, (totalsInCents.get(currency) ?? 0) + lineTotalCents);
      }

      skip += pageSize;
    }

    return [...totalsInCents.entries()].map(([currency, cents]) => ({
      currency,
      total: cents / 100,
    }));
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
    if (ids.length > this.maxBulkIds) {
      throw new BadRequestException(`ids length must be <= ${this.maxBulkIds}`);
    }

    const deduped = [...new Set(ids.filter((id) => typeof id === 'string' && id.trim() !== ''))];

    const updatedCount = await this.prisma.$transaction(async (tx) => {
      const currentRows = await tx.order.findMany({
        where: { organizationId: orgId, id: { in: deduped } },
        select: { id: true, status: true },
      });

      let count = 0;
      for (const row of currentRows) {
        if (!this.isValidTransition(row.status as OrderStatus, newStatus)) {
          continue;
        }

        const res = await tx.order.updateMany({
          where: {
            id: row.id,
            organizationId: orgId,
            status: row.status,
          },
          data: { status: newStatus },
        });
        count += res.count;
      }

      await this.writeAuditLogOrThrow(tx, 'order.bulk_status_updated', orgId, null, {
        requestedCount: deduped.length,
        updatedCount: count,
        to: newStatus,
      });

      return count;
    });

    if (updatedCount > 0) {
      await this.invalidateOrgCache(orgId);
    }

    return { updatedCount };
  }

  async getOrdersForExport(
    filters: ExportFilters,
    orgId: string,
  ): Promise<Array<Record<string, unknown>>> {
    this.assertOrgId(orgId);
    this.validateExportFilters(filters);

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

  private buildWhere(filters: OrderFilters, orgId: string): Record<string, unknown> {
    return {
      organizationId: orgId,
      ...(filters.status ? { status: filters.status } : {}),
      ...(filters.customerId ? { customerId: filters.customerId } : {}),
      ...(filters.dateRange
        ? {
            createdAt: {
              gte: filters.dateRange.from,
              lte: filters.dateRange.to,
            },
          }
        : {}),
    };
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

  private validateExportFilters(filters: ExportFilters): void {
    if (filters.dateRange) {
      this.validateDateRange(filters.dateRange);
    }
  }

  private normalizeFilters(filters: OrderFilters): Required<Pick<OrderFilters, 'take' | 'skip'>> & Omit<OrderFilters, 'take' | 'skip'> {
    if (!filters || typeof filters !== 'object') {
      throw new BadRequestException('filters must be an object');
    }

    const take =
      typeof filters.take === 'number'
        ? Math.min(Math.max(Math.trunc(filters.take), 1), this.maxListTake)
        : this.defaultTake;
    const skip =
      typeof filters.skip === 'number'
        ? Math.max(Math.trunc(filters.skip), 0)
        : 0;

    if (filters.dateRange) {
      this.validateDateRange(filters.dateRange);
    }

    return { ...filters, take, skip };
  }

  private validateDateRange(range: { from: Date; to: Date }): void {
    if (
      !(range.from instanceof Date) ||
      Number.isNaN(range.from.getTime()) ||
      !(range.to instanceof Date) ||
      Number.isNaN(range.to.getTime()) ||
      range.from > range.to
    ) {
      throw new BadRequestException('Invalid dateRange');
    }
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

  private async writeAuditLogOrThrow(
    tx: PrismaService,
    action: string,
    orgId: string,
    orderId: string | null,
    metadata: Record<string, unknown>,
  ): Promise<void> {
    try {
      await tx.auditLog.create({
        data: {
          action,
          organizationId: orgId,
          orderId,
          metadata,
        },
      });
    } catch (error) {
      console.error('Audit log write failed', error);
      throw new InternalServerErrorException('Failed to write audit log');
    }
  }

  private async getCacheVersion(orgId: string): Promise<number | null> {
    const key = this.buildVersionKey(orgId);

    try {
      const raw = await this.redis.get(key);
      if (raw === null) {
        await this.redis.set(key, '1', 86_400).catch(() => null);
        return 1;
      }

      const parsed = Number.parseInt(raw, 10);
      if (!Number.isFinite(parsed) || parsed <= 0) {
        return null;
      }
      return parsed;
    } catch {
      return null;
    }
  }

  private async invalidateOrgCache(orgId: string, id?: string): Promise<void> {
    const versionKey = this.buildVersionKey(orgId);
    const previousVersion = await this.getCacheVersion(orgId);

    if (id && previousVersion !== null) {
      const staleByIdKey = this.buildByIdCacheKey(orgId, previousVersion, id);
      await this.redis.del(staleByIdKey).catch(() => null);
    }

    await this.redis.incr(versionKey).catch(async () => {
      await this.redis.set(versionKey, String(Date.now()), 86_400).catch(() => null);
    });
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
    const digest = createHash('sha256').update(serialized).digest('hex').slice(0, 20);
    return `orders:${orgId}:v${version}:list:${digest}`;
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
