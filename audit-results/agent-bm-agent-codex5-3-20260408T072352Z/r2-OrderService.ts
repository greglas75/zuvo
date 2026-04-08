import { BadRequestException, ConflictException, Injectable, Logger, NotFoundException } from '@nestjs/common';

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

interface Order {
  id: string;
  organizationId: string;
  customerId: string;
  status: OrderStatus;
  currency: string;
  totalAmount: number;
  createdAt: Date;
}

interface PrismaOrderRepository {
  findMany(args: Record<string, unknown>): Promise<Order[]>;
  findFirst(args: Record<string, unknown>): Promise<Order | null>;
  create(args: Record<string, unknown>): Promise<Order>;
  delete(args: Record<string, unknown>): Promise<Order>;
  update(args: Record<string, unknown>): Promise<Order>;
  updateMany(args: Record<string, unknown>): Promise<{ count: number }>;
  groupBy?(args: Record<string, unknown>): Promise<Array<{ currency: string; _sum: { totalAmount: number | null } }>>;
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
  set?(key: string, value: string, ttlSeconds?: number): Promise<unknown>;
  setex?(key: string, ttlSeconds: number, value: string): Promise<unknown>;
  deleteByPrefix?(prefix: string): Promise<unknown>;
  scanDel?(pattern: string): Promise<unknown>;
}

interface EmailServiceLike {
  sendOrderShipped?(payload: { orderId: string; customerId: string; orgId: string }): Promise<void>;
}

interface PaymentGatewayLike {
  validateCurrency?(currency: string): boolean;
}

@Injectable()
export class OrderService {
  private readonly logger = new Logger(OrderService.name);
  private readonly listCacheTtlSeconds = 120;
  private readonly maxPageSize = 200;
  private readonly maxExportRows = 10_000;

  constructor(
    private readonly prisma: PrismaClientLike,
    private readonly redisService: RedisServiceLike,
    private readonly emailService: EmailServiceLike,
    private readonly paymentGateway: PaymentGatewayLike,
  ) {}

  async findAll(filters: OrderFilters, orgId: string): Promise<Order[]> {
    this.assertOrgId(orgId);
    this.validateDateRange(filters.dateRange);

    const normalizedTake = this.normalizeTake(filters.take);
    const normalizedSkip = this.normalizeSkip(filters.skip);
    const where = this.buildWhere(filters, orgId);
    const cacheKey = this.buildListCacheKey({
      orgId,
      filters: { ...filters, take: normalizedTake, skip: normalizedSkip },
    });

    const cachedValue = await this.getCache<Order[]>(cacheKey);
    if (cachedValue) {
      return cachedValue.map((order) => this.rehydrateOrder(order));
    }

    const orders = await this.prisma.order.findMany({
      where,
      orderBy: { createdAt: 'desc' },
      take: normalizedTake,
      skip: normalizedSkip,
    });

    await this.setCache(cacheKey, orders, this.listCacheTtlSeconds);
    return orders;
  }

  async findById(id: string, orgId: string): Promise<Order> {
    this.assertId(id);
    this.assertOrgId(orgId);

    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
    });

    if (!order) {
      throw new NotFoundException(`Order ${id} not found`);
    }

    return order;
  }

  async create(dto: CreateOrderDto, orgId: string): Promise<Order> {
    this.assertOrgId(orgId);
    this.validateCreateDto(dto);

    const normalizedCurrency = this.normalizeCurrency(dto.currency);
    const totalMinor = dto.lineItems.reduce((sum, item) => {
      const lineMinor = Math.round(item.unitPrice * 100) * item.quantity;
      return sum + lineMinor;
    }, 0);
    const totalAmount = totalMinor / 100;

    const createdOrder = await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.create({
        data: {
          organizationId: orgId,
          customerId: dto.customerId,
          status: 'pending',
          currency: normalizedCurrency,
          totalAmount,
          lineItems: {
            create: dto.lineItems.map((item) => ({
              productId: item.productId,
              quantity: item.quantity,
              unitPrice: Math.round(item.unitPrice * 100) / 100,
            })),
          },
        },
        include: {
          lineItems: true,
        },
      });

      await this.audit(tx, 'order.create', orgId, {
        orderId: order.id,
        customerId: dto.customerId,
        itemCount: dto.lineItems.length,
        totalAmount,
        currency: normalizedCurrency,
      });

      return order;
    });

    await this.safeInvalidateOrderCache(orgId);
    return createdOrder;
  }

  async deleteOrder(id: string, orgId: string): Promise<void> {
    this.assertId(id);
    this.assertOrgId(orgId);

    await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.findFirst({
        where: { id, organizationId: orgId },
      });
      if (!order) {
        throw new NotFoundException(`Order ${id} not found`);
      }

      await tx.orderLineItem.deleteMany({
        where: { orderId: id, organizationId: orgId },
      });

      await tx.order.delete({
        where: { id: order.id, organizationId: orgId },
      });

      await this.audit(tx, 'order.delete', orgId, {
        orderId: id,
        customerId: order.customerId,
      });
    });

    await this.safeInvalidateOrderCache(orgId);
  }

  async updateStatus(id: string, newStatus: OrderStatus, orgId: string): Promise<Order> {
    this.assertId(id);
    this.assertOrgId(orgId);

    const order = await this.findById(id, orgId);
    if (order.status === newStatus) {
      return order;
    }

    if (!this.isTransitionAllowed(order.status, newStatus)) {
      throw new BadRequestException(`Invalid transition from ${order.status} to ${newStatus}`);
    }

    const updatedOrder = await this.prisma.$transaction(async (tx) => {
      const updateResult = await tx.order.updateMany({
        where: {
          id: order.id,
          organizationId: orgId,
          status: order.status,
        },
        data: { status: newStatus },
      });

      if (updateResult.count !== 1) {
        throw new ConflictException('Order status changed by another request');
      }

      const freshOrder = await tx.order.findFirst({
        where: { id: order.id, organizationId: orgId },
      });
      if (!freshOrder) {
        throw new NotFoundException(`Order ${id} not found`);
      }

      await this.audit(tx, 'order.update_status', orgId, {
        orderId: freshOrder.id,
        from: order.status,
        to: newStatus,
      });

      return freshOrder;
    });

    if (newStatus === 'shipped') {
      await this.emailService
        .sendOrderShipped?.({
          orderId: updatedOrder.id,
          customerId: updatedOrder.customerId,
          orgId,
        })
        .catch((error: unknown) => {
          this.logger.error('Failed to send shipment email', error);
        });
    }

    await this.safeInvalidateOrderCache(orgId);
    return updatedOrder;
  }

  async calculateMonthlyRevenue(month: Date, orgId: string): Promise<Array<{ currency: string; total: number }>> {
    this.assertOrgId(orgId);
    if (!(month instanceof Date) || Number.isNaN(month.getTime())) {
      throw new BadRequestException('month must be a valid Date');
    }

    const from = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), 1, 0, 0, 0, 0));
    const to = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 1, 0, 0, 0, 0));

    if (this.prisma.order.groupBy) {
      const grouped = await this.prisma.order.groupBy({
        by: ['currency'],
        where: {
          organizationId: orgId,
          createdAt: { gte: from, lt: to },
          status: { not: 'cancelled' },
        },
        _sum: { totalAmount: true },
      });

      return grouped.map((row) => ({
        currency: row.currency,
        total: Number(row._sum.totalAmount ?? 0),
      }));
    }

    const orders = await this.prisma.order.findMany({
      where: {
        organizationId: orgId,
        createdAt: { gte: from, lt: to },
        status: { not: 'cancelled' },
      },
      select: {
        currency: true,
        totalAmount: true,
      },
    });

    const totals = new Map<string, number>();
    for (const order of orders) {
      const previous = totals.get(order.currency) ?? 0;
      totals.set(order.currency, previous + Number(order.totalAmount ?? 0));
    }

    return Array.from(totals.entries()).map(([currency, total]) => ({ currency, total }));
  }

  async bulkUpdateStatus(ids: string[], newStatus: OrderStatus, orgId: string): Promise<number> {
    this.assertOrgId(orgId);
    if (!Array.isArray(ids) || ids.length === 0) {
      return 0;
    }

    const uniqueIds = Array.from(new Set(ids.filter((id) => typeof id === 'string' && id.trim().length > 0)));
    if (uniqueIds.length === 0) {
      return 0;
    }

    const allowedFromStates = this.allowedFromStatesFor(newStatus);
    if (allowedFromStates.length === 0) {
      return 0;
    }

    const updateCount = await this.prisma.$transaction(async (tx) => {
      const result = await tx.order.updateMany({
        where: {
          organizationId: orgId,
          id: { in: uniqueIds },
          status: { in: allowedFromStates },
        },
        data: { status: newStatus },
      });

      await this.audit(tx, 'order.bulk_update_status', orgId, {
        targetStatus: newStatus,
        requestedCount: uniqueIds.length,
        updatedCount: result.count,
      });

      return result.count;
    });

    await this.safeInvalidateOrderCache(orgId);
    return updateCount;
  }

  async getOrdersForExport(filters: ExportFilters, orgId: string): Promise<Order[]> {
    this.assertOrgId(orgId);
    this.validateDateRange(filters.dateRange);
    const where = this.buildWhere(filters, orgId);

    const rows = await this.prisma.order.findMany({
      where,
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      orderBy: { createdAt: 'asc' },
      take: this.maxExportRows + 1,
    });

    if (rows.length > this.maxExportRows) {
      throw new BadRequestException(`Export row limit exceeded (${this.maxExportRows})`);
    }

    return rows;
  }

  private buildWhere(filters: Partial<OrderFilters>, orgId: string): Record<string, unknown> {
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
    if (to === 'cancelled') {
      return from !== 'delivered';
    }

    const nextState: Record<
      Exclude<OrderStatus, 'cancelled'>,
      Exclude<OrderStatus, 'pending' | 'cancelled'> | null
    > = {
      pending: 'confirmed',
      confirmed: 'processing',
      processing: 'shipped',
      shipped: 'delivered',
      delivered: null,
    };

    return nextState[from as Exclude<OrderStatus, 'cancelled'>] === to;
  }

  private allowedFromStatesFor(target: OrderStatus): OrderStatus[] {
    if (target === 'confirmed') {
      return ['pending'];
    }
    if (target === 'processing') {
      return ['confirmed'];
    }
    if (target === 'shipped') {
      return ['processing'];
    }
    if (target === 'delivered') {
      return ['shipped'];
    }
    if (target === 'cancelled') {
      return ['pending', 'confirmed', 'processing', 'shipped'];
    }
    return [];
  }

  private async safeInvalidateOrderCache(orgId: string): Promise<void> {
    try {
      await this.invalidateOrderCache(orgId);
    } catch (error) {
      this.logger.error('Cache invalidation failed', error);
    }
  }

  private async invalidateOrderCache(orgId: string): Promise<void> {
    const prefix = `orders:${orgId}:`;

    if (this.redisService.deleteByPrefix) {
      await this.redisService.deleteByPrefix(prefix);
      return;
    }

    if (this.redisService.scanDel) {
      await this.redisService.scanDel(`${prefix}*`);
    }
  }

  private buildListCacheKey(input: { orgId: string; filters: OrderFilters }): string {
    const normalized = {
      status: input.filters.status ?? null,
      customerId: input.filters.customerId ?? null,
      from: input.filters.dateRange?.from?.toISOString() ?? null,
      to: input.filters.dateRange?.to?.toISOString() ?? null,
      take: this.normalizeTake(input.filters.take),
      skip: this.normalizeSkip(input.filters.skip),
    };

    return `orders:${input.orgId}:findAll:${JSON.stringify(normalized)}`;
  }

  private async getCache<T>(key: string): Promise<T | null> {
    if (!this.redisService.get) {
      return null;
    }

    const raw = await this.redisService.get(key);
    if (!raw) {
      return null;
    }

    try {
      return JSON.parse(raw) as T;
    } catch (error) {
      this.logger.warn(`Failed to parse cache payload for key ${key}`, error);
      return null;
    }
  }

  private async setCache(key: string, value: unknown, ttlSeconds: number): Promise<void> {
    const payload = JSON.stringify(value);
    if (this.redisService.setex) {
      await this.redisService.setex(key, ttlSeconds, payload);
      return;
    }

    if (this.redisService.set) {
      await this.redisService.set(key, payload, ttlSeconds);
    }
  }

  private rehydrateOrder(order: Order): Order {
    const candidate = order as unknown as { createdAt?: Date | string };
    if (typeof candidate.createdAt === 'string') {
      const parsedDate = new Date(candidate.createdAt);
      if (!Number.isNaN(parsedDate.getTime())) {
        return { ...order, createdAt: parsedDate };
      }
    }
    return order;
  }

  private validateCreateDto(dto: CreateOrderDto): void {
    if (!dto || typeof dto !== 'object') {
      throw new BadRequestException('dto is required');
    }

    if (!dto.customerId?.trim()) {
      throw new BadRequestException('customerId is required');
    }

    const normalizedCurrency = this.normalizeCurrency(dto.currency);
    if (this.paymentGateway.validateCurrency && !this.paymentGateway.validateCurrency(normalizedCurrency)) {
      throw new BadRequestException(`unsupported currency: ${normalizedCurrency}`);
    }

    if (!Array.isArray(dto.lineItems) || dto.lineItems.length === 0) {
      throw new BadRequestException('lineItems must contain at least one item');
    }

    for (const item of dto.lineItems) {
      if (!item.productId?.trim()) {
        throw new BadRequestException('line item productId is required');
      }
      if (!Number.isFinite(item.quantity) || item.quantity <= 0) {
        throw new BadRequestException('line item quantity must be greater than 0');
      }
      if (!Number.isFinite(item.unitPrice) || item.unitPrice < 0) {
        throw new BadRequestException('line item unitPrice must be >= 0');
      }
      if (!Number.isFinite(item.unitPrice * item.quantity)) {
        throw new BadRequestException('line item total is invalid');
      }
    }
  }

  private validateDateRange(dateRange: { from: Date; to: Date } | undefined): void {
    if (!dateRange) {
      return;
    }

    const { from, to } = dateRange;
    if (!(from instanceof Date) || Number.isNaN(from.getTime())) {
      throw new BadRequestException('dateRange.from must be a valid Date');
    }
    if (!(to instanceof Date) || Number.isNaN(to.getTime())) {
      throw new BadRequestException('dateRange.to must be a valid Date');
    }
    if (from.getTime() > to.getTime()) {
      throw new BadRequestException('dateRange.from must be <= dateRange.to');
    }
  }

  private normalizeCurrency(currency: string): string {
    if (!currency || typeof currency !== 'string') {
      throw new BadRequestException('currency is required');
    }

    const normalized = currency.trim().toUpperCase();
    if (!normalized) {
      throw new BadRequestException('currency is required');
    }
    return normalized;
  }

  private normalizeTake(take: number | undefined): number {
    if (!Number.isInteger(take)) {
      return 50;
    }

    if (take < 1) {
      return 1;
    }

    return Math.min(take, this.maxPageSize);
  }

  private normalizeSkip(skip: number | undefined): number {
    if (!Number.isInteger(skip) || (skip ?? 0) < 0) {
      return 0;
    }

    return skip as number;
  }

  private assertId(id: string): void {
    if (!id || typeof id !== 'string' || id.trim().length === 0) {
      throw new BadRequestException('id is required');
    }
  }

  private assertOrgId(orgId: string): void {
    if (!orgId || typeof orgId !== 'string' || orgId.trim().length === 0) {
      throw new BadRequestException('organization id is required');
    }
  }

  private async audit(
    tx: PrismaClientLike,
    action: string,
    orgId: string,
    payload: Record<string, unknown>,
  ): Promise<void> {
    await tx.auditLog.create({
      data: {
        action,
        organizationId: orgId,
        payload,
        createdAt: new Date(),
      },
    });
  }
}
