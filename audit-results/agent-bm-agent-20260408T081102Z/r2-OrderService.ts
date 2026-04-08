import {
  BadRequestException,
  ConflictException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { randomUUID } from 'crypto';

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

interface OrderLineItem {
  id?: string;
  productId: string;
  quantity: number;
  unitPrice: number;
  createdAt?: Date;
  updatedAt?: Date;
}

interface OrderCustomer {
  id: string;
  email?: string;
  name?: string;
}

interface OrderPayment {
  id: string;
  currency: string;
  amount: number;
  createdAt?: Date;
}

interface OrderRecord {
  id: string;
  organizationId: string;
  customerId: string;
  status: OrderStatus;
  currency: string;
  totalAmount: number;
  createdAt: Date;
  updatedAt?: Date;
  lineItems?: OrderLineItem[];
  customer?: OrderCustomer;
  payments?: OrderPayment[];
}

interface PrismaOrderRepository {
  findMany(args: Record<string, unknown>): Promise<OrderRecord[]>;
  findFirst(args: Record<string, unknown>): Promise<OrderRecord | null>;
  create(args: Record<string, unknown>): Promise<OrderRecord>;
  delete(args: Record<string, unknown>): Promise<OrderRecord>;
  deleteMany(args: Record<string, unknown>): Promise<{ count: number }>;
  update(args: Record<string, unknown>): Promise<OrderRecord>;
  updateMany(args: Record<string, unknown>): Promise<{ count: number }>;
}

interface PrismaOrderLineItemRepository {
  deleteMany(args: Record<string, unknown>): Promise<{ count: number }>;
}

interface PrismaAuditLogRepository {
  create(args: Record<string, unknown>): Promise<unknown>;
}

interface PrismaClientLike {
  order: PrismaOrderRepository;
  orderLineItem: PrismaOrderLineItemRepository;
  auditLog: PrismaAuditLogRepository;
  $transaction<T>(callback: (tx: PrismaClientLike) => Promise<T>): Promise<T>;
}

interface RedisServiceLike {
  get?(key: string): Promise<string | null>;
  set?(key: string, value: string): Promise<unknown>;
  setex?(key: string, ttlSeconds: number, value: string): Promise<unknown>;
}

interface EmailServiceLike {
  sendOrderShipped(payload: { orderId: string; customerId: string; orgId: string }): Promise<void>;
}

interface PaymentGatewayLike {
  validateCurrency?(currency: string): boolean;
}

const ORDER_STATUSES: ReadonlySet<OrderStatus> = new Set([
  'pending',
  'confirmed',
  'processing',
  'shipped',
  'delivered',
  'cancelled',
]);

const STATUS_TRANSITIONS: Record<Exclude<OrderStatus, 'cancelled'>, OrderStatus | null> = {
  pending: 'confirmed',
  confirmed: 'processing',
  processing: 'shipped',
  shipped: 'delivered',
  delivered: null,
};

const DEFAULT_LIST_TAKE = 50;
const MAX_LIST_TAKE = 100;
const LIST_CACHE_TTL_SECONDS = 300;
const MAX_EXPORT_ROWS = 10_000;
const DATE_KEY_PATTERN = /(At|Date|from|to)$/i;

@Injectable()
export class OrderService {
  private readonly logger = new Logger(OrderService.name);

  constructor(
    private readonly prisma: PrismaClientLike,
    private readonly redisService: RedisServiceLike,
    private readonly emailService: EmailServiceLike,
    private readonly paymentGateway: PaymentGatewayLike,
  ) {}

  async findAll(filters: OrderFilters, orgId: string): Promise<OrderRecord[]> {
    this.assertOrgId(orgId);
    const normalized = this.normalizeListFilters(filters);
    const version = await this.getCacheVersion(orgId);
    const cacheKey = this.buildCacheKey('findAll', orgId, version, normalized);
    const cached = await this.readCache<OrderRecord[]>(cacheKey);

    if (cached) {
      return cached;
    }

    const orders = await this.prisma.order.findMany({
      where: this.buildOrderWhere(normalized, orgId),
      orderBy: { createdAt: 'desc' },
      take: normalized.take,
      skip: normalized.skip,
    });

    await this.writeCache(cacheKey, orders, LIST_CACHE_TTL_SECONDS);
    return orders;
  }

  async findById(id: string, orgId: string): Promise<OrderRecord> {
    this.assertId(id);
    this.assertOrgId(orgId);
    const version = await this.getCacheVersion(orgId);
    const cacheKey = this.buildCacheKey('findById', orgId, version, { id });
    const cached = await this.readCache<OrderRecord>(cacheKey);

    if (cached) {
      return cached;
    }

    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
    });

    if (!order) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    await this.writeCache(cacheKey, order, LIST_CACHE_TTL_SECONDS);
    return order;
  }

  async create(dto: CreateOrderDto, orgId: string): Promise<OrderRecord> {
    this.assertOrgId(orgId);
    const validated = this.validateCreateDto(dto);

    const created = await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.create({
        data: {
          organizationId: orgId,
          customerId: validated.customerId,
          status: 'pending',
          currency: validated.currency,
          totalAmount: validated.totalAmount,
          lineItems: {
            create: validated.lineItems.map((item) => ({
              productId: item.productId,
              quantity: item.quantity,
              unitPrice: item.unitPrice,
            })),
          },
        },
        include: { lineItems: true },
      });

      await tx.auditLog.create({
        data: {
          action: 'order.create',
          organizationId: orgId,
          payload: {
            orderId: order.id,
            customerId: validated.customerId,
            currency: validated.currency,
            lineItemCount: validated.lineItems.length,
            totalAmount: validated.totalAmount,
          },
        },
      });

      return order;
    });

    await this.invalidateCache(orgId);
    return created;
  }

  async deleteOrder(id: string, orgId: string): Promise<void> {
    this.assertId(id);
    this.assertOrgId(orgId);

    await this.prisma.$transaction(async (tx) => {
      const current = await tx.order.findFirst({
        where: { id, organizationId: orgId },
        select: { id: true, customerId: true, status: true },
      });

      if (!current) {
        throw new NotFoundException(`Order ${id} not found`);
      }

      await tx.orderLineItem.deleteMany({
        where: { orderId: id, organizationId: orgId },
      });

      const deleteResult = await tx.order.deleteMany({
        where: { id, organizationId: orgId },
      });

      if (deleteResult.count === 0) {
        throw new NotFoundException(`Order ${id} not found`);
      }

      await tx.auditLog.create({
        data: {
          action: 'order.delete',
          organizationId: orgId,
          payload: {
            orderId: id,
            customerId: current.customerId,
            status: current.status,
          },
        },
      });
    });

    await this.invalidateCache(orgId);
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string): Promise<OrderRecord> {
    this.assertId(id);
    this.assertOrgId(orgId);
    this.assertStatus(newStatus);

    const updated = await this.prisma.$transaction(async (tx) => {
      const current = await tx.order.findFirst({
        where: { id, organizationId: orgId },
        select: { id: true, customerId: true, status: true, currency: true, totalAmount: true, createdAt: true },
      });

      if (!current) {
        throw new NotFoundException(`Order ${id} not found`);
      }

      if (!this.isTransitionAllowed(current.status, newStatus)) {
        throw new BadRequestException(`Invalid transition from ${current.status} to ${newStatus}`);
      }

      const result = await tx.order.updateMany({
        where: {
          id,
          organizationId: orgId,
          status: current.status,
        },
        data: { status: newStatus },
      });

      if (result.count === 0) {
        throw new ConflictException('Order status changed by another request');
      }

      await tx.auditLog.create({
        data: {
          action: 'order.update_status',
          organizationId: orgId,
          payload: {
            orderId: id,
            from: current.status,
            to: newStatus,
          },
        },
      });

      return { ...current, status: newStatus };
    });

    await this.invalidateCache(orgId);

    if (newStatus === 'shipped' && updated.status !== 'shipped') {
      await this.emailService
        .sendOrderShipped({ orderId: updated.id, customerId: updated.customerId, orgId })
        .catch((err: unknown) => {
          this.logger.warn(`Shipment email failed for order ${updated.id}: ${this.describeError(err)}`);
        });
    }

    return updated;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string): Promise<Array<{ currency: string; total: number }>> {
    this.assertOrgId(orgId);
    this.assertValidDate(month, 'month');

    const start = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), 1, 0, 0, 0, 0));
    const end = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 1, 0, 0, 0, 0));
    const orders = await this.prisma.order.findMany({
      where: {
        organizationId: orgId,
        createdAt: { gte: start, lt: end },
        status: { not: 'cancelled' },
      },
      select: { currency: true, totalAmount: true },
    });

    const totals = new Map<string, number>();
    for (const order of orders) {
      totals.set(order.currency, (totals.get(order.currency) ?? 0) + Number(order.totalAmount ?? 0));
    }

    return Array.from(totals.entries())
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([currency, total]) => ({ currency, total }));
  }

  async bulkUpdateStatus(ids: string[], newStatus: OrderStatus, orgId: string): Promise<number> {
    this.assertOrgId(orgId);
    this.assertStatus(newStatus);
    if (!Array.isArray(ids)) {
      throw new BadRequestException('ids must be an array');
    }

    const normalizedIds = Array.from(
      new Set(
        ids
          .filter((id): id is string => typeof id === 'string')
          .map((id) => id.trim())
          .filter((id) => id.length > 0),
      ),
    );

    if (normalizedIds.length === 0) {
      return 0;
    }

    const updatedCount = await this.prisma.$transaction(async (tx) => {
      const orders = await tx.order.findMany({
        where: {
          organizationId: orgId,
          id: { in: normalizedIds },
        },
        select: { id: true, status: true },
      });

      const validOrders = orders.filter((order) => this.isTransitionAllowed(order.status, newStatus));
      if (validOrders.length === 0) {
        return 0;
      }

      const sourceStatuses = Array.from(new Set(validOrders.map((order) => order.status)));
      const result = await tx.order.updateMany({
        where: {
          organizationId: orgId,
          id: { in: validOrders.map((order) => order.id) },
          status: { in: sourceStatuses },
        },
        data: { status: newStatus },
      });

      await tx.auditLog.create({
        data: {
          action: 'order.bulk_update_status',
          organizationId: orgId,
          payload: {
            requestedCount: normalizedIds.length,
            matchedCount: orders.length,
            updatedCount: result.count,
            targetStatus: newStatus,
          },
        },
      });

      return result.count;
    });

    if (updatedCount > 0) {
      await this.invalidateCache(orgId);
    }

    return updatedCount;
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string): Promise<OrderRecord[]> {
    this.assertOrgId(orgId);
    const normalized = this.normalizeExportFilters(filters);
    const rows = await this.prisma.order.findMany({
      where: this.buildOrderWhere(normalized, orgId),
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      orderBy: { createdAt: 'asc' },
      take: MAX_EXPORT_ROWS + 1,
    });

    if (rows.length > MAX_EXPORT_ROWS) {
      throw new BadRequestException(`Export row limit exceeded (${MAX_EXPORT_ROWS})`);
    }

    return rows;
  }

  private normalizeListFilters(filters: OrderFilters): Required<Pick<OrderFilters, 'take' | 'skip'>> & Pick<OrderFilters, 'status' | 'customerId' | 'dateRange'> {
    const normalized = this.normalizeCommonFilters(filters);
    return {
      ...normalized,
      take: this.normalizeTake(filters?.take),
      skip: this.normalizeSkip(filters?.skip),
    };
  }

  private normalizeExportFilters(filters: ExportFilters): Pick<OrderFilters, 'status' | 'dateRange'> {
    return this.normalizeCommonFilters(filters);
  }

  private normalizeCommonFilters(filters: Partial<OrderFilters>): Pick<OrderFilters, 'status' | 'customerId' | 'dateRange'> {
    if (filters == null || typeof filters !== 'object') {
      throw new BadRequestException('filters must be an object');
    }

    const normalized: Pick<OrderFilters, 'status' | 'customerId' | 'dateRange'> = {};

    if (filters.status !== undefined) {
      this.assertStatus(filters.status);
      normalized.status = filters.status;
    }

    if (filters.customerId !== undefined) {
      if (typeof filters.customerId !== 'string' || filters.customerId.trim().length === 0) {
        throw new BadRequestException('customerId must be a non-empty string');
      }
      normalized.customerId = filters.customerId.trim();
    }

    if (filters.dateRange !== undefined) {
      this.assertDateRange(filters.dateRange);
      normalized.dateRange = {
        from: new Date(filters.dateRange.from),
        to: new Date(filters.dateRange.to),
      };
    }

    return normalized;
  }

  private buildOrderWhere(filters: Pick<OrderFilters, 'status' | 'customerId' | 'dateRange'>, orgId: string): Record<string, unknown> {
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

  private isTransitionAllowed(from: OrderStatus, to: OrderStatus): boolean {
    if (from === to) {
      return true;
    }

    if (from === 'cancelled') {
      return false;
    }

    if (to === 'cancelled') {
      return from !== 'delivered';
    }

    return STATUS_TRANSITIONS[from] === to;
  }

  private validateCreateDto(dto: CreateOrderDto): { customerId: string; currency: string; lineItems: CreateOrderDto['lineItems']; totalAmount: number } {
    if (dto == null || typeof dto !== 'object') {
      throw new BadRequestException('dto is required');
    }

    if (typeof dto.customerId !== 'string' || dto.customerId.trim().length === 0) {
      throw new BadRequestException('customerId is required');
    }

    if (!Array.isArray(dto.lineItems) || dto.lineItems.length === 0) {
      throw new BadRequestException('lineItems must contain at least one item');
    }

    if (typeof dto.currency !== 'string' || dto.currency.trim().length === 0) {
      throw new BadRequestException('currency is required');
    }

    const currency = dto.currency.trim().toUpperCase();
    if (this.paymentGateway.validateCurrency && !this.paymentGateway.validateCurrency(currency)) {
      throw new BadRequestException(`unsupported currency: ${currency}`);
    }

    const lineItems = dto.lineItems.map((item) => this.validateLineItem(item));
    const totalAmount = lineItems.reduce((sum, item) => sum + item.quantity * item.unitPrice, 0);

    return {
      customerId: dto.customerId.trim(),
      currency,
      lineItems,
      totalAmount,
    };
  }

  private validateLineItem(item: CreateOrderDto['lineItems'][number]): CreateOrderDto['lineItems'][number] {
    if (item == null || typeof item !== 'object') {
      throw new BadRequestException('line item is required');
    }

    if (typeof item.productId !== 'string' || item.productId.trim().length === 0) {
      throw new BadRequestException('line item productId is required');
    }

    if (!Number.isFinite(item.quantity) || !Number.isInteger(item.quantity) || item.quantity <= 0) {
      throw new BadRequestException('line item quantity must be a positive integer');
    }

    if (!Number.isFinite(item.unitPrice) || item.unitPrice < 0) {
      throw new BadRequestException('line item unitPrice must be a finite number >= 0');
    }

    return {
      productId: item.productId.trim(),
      quantity: item.quantity,
      unitPrice: item.unitPrice,
    };
  }

  private normalizeTake(take: number | undefined): number {
    if (take === undefined) {
      return DEFAULT_LIST_TAKE;
    }

    if (!Number.isInteger(take) || take <= 0) {
      throw new BadRequestException('take must be a positive integer');
    }

    return Math.min(take, MAX_LIST_TAKE);
  }

  private normalizeSkip(skip: number | undefined): number {
    if (skip === undefined) {
      return 0;
    }

    if (!Number.isInteger(skip) || skip < 0) {
      throw new BadRequestException('skip must be a non-negative integer');
    }

    return skip;
  }

  private assertStatus(status: OrderStatus): void {
    if (!ORDER_STATUSES.has(status)) {
      throw new BadRequestException(`invalid status: ${status}`);
    }
  }

  private assertDateRange(range: { from: Date; to: Date }): void {
    this.assertValidDate(range.from, 'dateRange.from');
    this.assertValidDate(range.to, 'dateRange.to');

    if (range.from.getTime() > range.to.getTime()) {
      throw new BadRequestException('dateRange.from must be before or equal to dateRange.to');
    }
  }

  private assertValidDate(value: Date, fieldName: string): void {
    if (!(value instanceof Date) || Number.isNaN(value.getTime())) {
      throw new BadRequestException(`${fieldName} must be a valid Date`);
    }
  }

  private assertId(id: string): void {
    if (typeof id !== 'string' || id.trim().length === 0) {
      throw new BadRequestException('id is required');
    }
  }

  private assertOrgId(orgId: string): void {
    if (typeof orgId !== 'string' || orgId.trim().length === 0) {
      throw new BadRequestException('organizationId is required');
    }
  }

  private buildCacheKey(
    scope: 'findAll' | 'findById',
    orgId: string,
    version: string,
    payload: Record<string, unknown>,
  ): string {
    return `orders:${orgId}:${scope}:${version}:${JSON.stringify(payload)}`;
  }

  private async getCacheVersion(orgId: string): Promise<string> {
    const rawVersion = await this.redisService.get?.(this.buildVersionKey(orgId));
    return rawVersion?.trim() || '0';
  }

  private async invalidateCache(orgId: string): Promise<void> {
    const versionKey = this.buildVersionKey(orgId);
    const versionValue = `${Date.now()}:${randomUUID()}`;

    if (this.redisService.set) {
      await this.redisService.set(versionKey, versionValue);
      return;
    }

    if (this.redisService.setex) {
      await this.redisService.setex(versionKey, 86_400, versionValue);
    }
  }

  private buildVersionKey(orgId: string): string {
    return `orders:${orgId}:version`;
  }

  private async readCache<T>(key: string): Promise<T | null> {
    if (!this.redisService.get) {
      return null;
    }

    try {
      const raw = await this.redisService.get(key);
      if (!raw) {
        return null;
      }

      return this.hydrateDates(JSON.parse(raw)) as T;
    } catch {
      return null;
    }
  }

  private async writeCache(key: string, value: unknown, ttlSeconds: number): Promise<void> {
    const payload = JSON.stringify(value);
    if (this.redisService.setex) {
      await this.redisService.setex(key, ttlSeconds, payload);
      return;
    }

    await this.redisService.set?.(key, payload);
  }

  private hydrateDates<T>(value: T, key?: string): T {
    if (Array.isArray(value)) {
      return value.map((item) => this.hydrateDates(item)) as T;
    }

    if (value && typeof value === 'object') {
      const entries = Object.entries(value as Record<string, unknown>).map(([entryKey, entryValue]) => {
        return [entryKey, this.hydrateDates(entryValue, entryKey)] as const;
      });

      return Object.fromEntries(entries) as T;
    }

    if (typeof value === 'string' && key && DATE_KEY_PATTERN.test(key) && this.looksLikeIsoDate(value)) {
      return new Date(value) as T;
    }

    return value;
  }

  private looksLikeIsoDate(value: string): boolean {
    return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$/.test(value);
  }

  private describeError(error: unknown): string {
    if (error instanceof Error) {
      return error.message;
    }

    return String(error);
  }
}
