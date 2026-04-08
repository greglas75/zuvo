import {
  BadRequestException,
  Injectable,
  Logger,
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

interface OrderLineItem {
  id: string;
  orderId: string;
  productId: string;
  quantity: number;
  unitPrice: number;
  createdAt?: Date;
  updatedAt?: Date;
}

interface CustomerRecord {
  id: string;
  email?: string | null;
  name?: string | null;
}

interface PaymentRecord {
  id: string;
  amount: number;
  currency: string;
  status: string;
  createdAt: Date;
}

interface OrderRecord {
  id: string;
  organizationId: string;
  customerId: string;
  currency: string;
  status: OrderStatus;
  totalAmount: number;
  createdAt: Date;
  updatedAt: Date;
  lineItems?: OrderLineItem[];
  customer?: CustomerRecord | null;
  payments?: PaymentRecord[];
}

interface AuditLogInput {
  action: string;
  entityId: string;
  organizationId: string;
  metadata?: Record<string, unknown>;
}

interface PrismaMutationResult {
  count: number;
}

interface PrismaOrderDelegate {
  findMany(args: unknown): Promise<OrderRecord[]>;
  findFirst(args: unknown): Promise<OrderRecord | null>;
  create(args: unknown): Promise<OrderRecord>;
  update(args: unknown): Promise<OrderRecord>;
  updateMany(args: unknown): Promise<PrismaMutationResult>;
  delete(args: unknown): Promise<OrderRecord>;
  deleteMany(args: unknown): Promise<PrismaMutationResult>;
  count(args: unknown): Promise<number>;
  groupBy(args: unknown): Promise<
    Array<{ currency: string; _sum: { totalAmount: number | null } }>
  >;
}

interface PrismaOrderLineItemDelegate {
  deleteMany(args: unknown): Promise<PrismaMutationResult>;
}

interface PrismaAuditLogDelegate {
  create(args: unknown): Promise<unknown>;
  createMany(args: unknown): Promise<unknown>;
}

interface PrismaTransactionClient {
  order: PrismaOrderDelegate;
  orderLineItem: PrismaOrderLineItemDelegate;
  auditLog: PrismaAuditLogDelegate;
}

interface PrismaService extends PrismaTransactionClient {
  $transaction<T>(callback: (tx: PrismaTransactionClient) => Promise<T>): Promise<T>;
}

interface RedisService {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, ttlSeconds: number): Promise<void>;
  del?(key: string): Promise<number | void>;
}

interface EmailService {
  sendOrderShippedNotification(payload: {
    orderId: string;
    customerId: string;
    email?: string | null;
    organizationId: string;
  }): Promise<void>;
}

interface PaymentGateway {
  readonly name?: string;
}

const DEFAULT_TAKE = 50;
const MAX_TAKE = 100;
const MAX_SKIP = 10_000;
const MAX_LINE_ITEMS = 100;
const MAX_BULK_UPDATE_IDS = 100;
const MAX_QUANTITY = 10_000;
const MAX_UNIT_PRICE = 1_000_000;
const EXPORT_MAX_ROWS = 10_000;
const CACHE_TTL_SECONDS = 300;
const CACHE_VERSION_TTL_SECONDS = 30 * 24 * 60 * 60;
const MAX_MINOR_UNITS = Number.MAX_SAFE_INTEGER;
const DATE_KEYS = new Set(['createdAt', 'updatedAt', 'from', 'to']);
const ORDER_STATUSES: OrderStatus[] = [
  'pending',
  'confirmed',
  'processing',
  'shipped',
  'delivered',
  'cancelled',
];

const NEXT_STATUS: Record<Exclude<OrderStatus, 'cancelled'>, OrderStatus | null> = {
  pending: 'confirmed',
  confirmed: 'processing',
  processing: 'shipped',
  shipped: 'delivered',
  delivered: null,
};

@Injectable()
export class OrderService {
  private readonly logger = new Logger(OrderService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly redis: RedisService,
    private readonly emailService: EmailService,
    private readonly paymentGateway: PaymentGateway,
  ) {
    void this.paymentGateway;
  }

  async findAll(filters: OrderFilters = {}, orgId: string): Promise<OrderRecord[]> {
    this.assertOrganizationId(orgId);
    this.validateDateRange(filters.dateRange);

    const take = this.normalizeTake(filters.take);
    const skip = this.normalizeSkip(filters.skip);
    const where = this.buildWhereClause(filters, orgId);
    const cacheVersion = await this.getCacheVersion(orgId);
    const cacheKey = this.buildCacheKey('orders:list', orgId, cacheVersion, {
      ...this.serializeFilters(filters),
      take,
      skip,
    });

    const cached = await this.redis.get(cacheKey);
    if (cached) {
      const cachedOrders = await this.tryParseCachedValue<OrderRecord[]>(
        cacheKey,
        cached,
      );
      if (cachedOrders) {
        return cachedOrders;
      }
    }

    const orders = await this.prisma.order.findMany({
      where,
      orderBy: { createdAt: 'desc' },
      skip,
      take,
    });

    await this.redis.set(cacheKey, JSON.stringify(orders), CACHE_TTL_SECONDS);
    return orders;
  }

  async findById(id: string, orgId: string): Promise<OrderRecord> {
    this.assertOrderId(id);
    this.assertOrganizationId(orgId);

    const order = await this.prisma.order.findFirst({
      where: { id, organizationId: orgId },
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
    });

    if (!order) {
      throw new NotFoundException(`Order ${id} was not found in this organization`);
    }

    return order;
  }

  async create(dto: CreateOrderDto, orgId: string): Promise<OrderRecord> {
    this.assertOrganizationId(orgId);
    const validatedDto = this.validateCreateDto(dto);

    const order = await this.prisma.$transaction(async (tx) => {
      const totalAmount = this.calculateOrderTotal(validatedDto.lineItems);

      const createdOrder = await tx.order.create({
        data: {
          organizationId: orgId,
          customerId: validatedDto.customerId,
          currency: validatedDto.currency,
          status: 'pending',
          totalAmount,
          lineItems: {
            create: validatedDto.lineItems.map((item) => ({
              productId: item.productId,
              quantity: item.quantity,
              unitPrice: item.unitPrice,
            })),
          },
        },
        include: {
          lineItems: true,
        },
      });

      await this.emitAuditLog(tx, {
        action: 'order.created',
        entityId: createdOrder.id,
        organizationId: orgId,
        metadata: {
          customerId: createdOrder.customerId,
          currency: createdOrder.currency,
          lineItemCount:
            createdOrder.lineItems?.length ?? validatedDto.lineItems.length,
          totalAmount,
        },
      });

      return createdOrder;
    });

    await this.invalidateOrdersCache(orgId);
    return order;
  }

  async deleteOrder(id: string, orgId: string): Promise<void> {
    this.assertOrderId(id);
    this.assertOrganizationId(orgId);

    await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.findFirst({
        where: { id, organizationId: orgId },
        include: { lineItems: true },
      });

      if (!order) {
        throw new NotFoundException(`Order ${id} was not found in this organization`);
      }

      await tx.orderLineItem.deleteMany({
        where: { orderId: id },
      });

      const deletedOrder = await tx.order.deleteMany({
        where: { id, organizationId: orgId },
      });

      if (deletedOrder.count !== 1) {
        throw new BadRequestException(
          `Order ${id} changed during deletion; retry the request`,
        );
      }

      await this.emitAuditLog(tx, {
        action: 'order.deleted',
        entityId: id,
        organizationId: orgId,
        metadata: {
          lineItemCount: order.lineItems?.length ?? 0,
          previousStatus: order.status,
        },
      });
    });

    await this.invalidateOrdersCache(orgId);
  }

  async updateStatus(
    id: string,
    newStatus: OrderStatus,
    orgId: string,
  ): Promise<OrderRecord> {
    this.assertOrderId(id);
    this.assertOrganizationId(orgId);
    this.assertOrderStatus(newStatus);

    const updatedOrder = await this.prisma.$transaction(async (tx) => {
      const existingOrder = await tx.order.findFirst({
        where: { id, organizationId: orgId },
        include: { customer: true },
      });

      if (!existingOrder) {
        throw new NotFoundException(`Order ${id} was not found in this organization`);
      }

      if (existingOrder.status === newStatus) {
        throw new BadRequestException(
          `Order ${id} is already in status ${newStatus}`,
        );
      }

      if (!this.canTransition(existingOrder.status, newStatus)) {
        throw new BadRequestException(
          `Cannot transition order ${id} from ${existingOrder.status} to ${newStatus}`,
        );
      }

      const updateResult = await tx.order.updateMany({
        where: {
          id,
          organizationId: orgId,
          status: existingOrder.status,
        },
        data: { status: newStatus },
      });

      if (updateResult.count !== 1) {
        throw new BadRequestException(
          `Order ${id} changed during status update; retry the request`,
        );
      }

      const order = await tx.order.findFirst({
        where: { id, organizationId: orgId },
        include: {
          lineItems: true,
          customer: true,
          payments: true,
        },
      });

      if (!order) {
        throw new NotFoundException(`Order ${id} was not found in this organization`);
      }

      await this.emitAuditLog(tx, {
        action: 'order.status_updated',
        entityId: id,
        organizationId: orgId,
        metadata: {
          previousStatus: existingOrder.status,
          newStatus,
        },
      });

      return order;
    });

    await this.invalidateOrdersCache(orgId);

    if (newStatus === 'shipped') {
      await this.emailService
        .sendOrderShippedNotification({
          orderId: updatedOrder.id,
          customerId: updatedOrder.customerId,
          email: updatedOrder.customer?.email,
          organizationId: orgId,
        })
        .catch((error: unknown) => {
          const message = error instanceof Error ? error.message : String(error);
          this.logger.error(
            `Failed to send shipped notification for order ${updatedOrder.id}: ${message}`,
          );
        });
    }

    return updatedOrder;
  }

  async calculateMonthlyRevenue(
    month: Date,
    orgId: string,
  ): Promise<Array<{ currency: string; total: number }>> {
    this.assertValidDate(month, 'month');
    this.assertOrganizationId(orgId);

    const rangeStart = new Date(
      Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), 1, 0, 0, 0, 0),
    );
    const rangeEnd = new Date(
      Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 1, 0, 0, 0, 0),
    );

    const rows = await this.prisma.order.groupBy({
      by: ['currency'],
      where: {
        organizationId: orgId,
        createdAt: {
          gte: rangeStart,
          lt: rangeEnd,
        },
        status: {
          not: 'cancelled',
        },
      },
      _sum: {
        totalAmount: true,
      },
    });

    return rows.map((row) => ({
      currency: row.currency,
      total: row._sum.totalAmount ?? 0,
    }));
  }

  async bulkUpdateStatus(
    ids: string[],
    newStatus: OrderStatus,
    orgId: string,
  ): Promise<number> {
    this.assertOrganizationId(orgId);
    this.assertOrderStatus(newStatus);

    const uniqueIds = this.validateBulkIds(ids);
    if (uniqueIds.length === 0) {
      return 0;
    }

    const transitionableOrders = await this.prisma.$transaction(async (tx) => {
      const existingOrders = await tx.order.findMany({
        where: {
          id: { in: uniqueIds },
          organizationId: orgId,
        },
        include: { customer: true },
      });

      const validOrders = existingOrders.filter(
        (order) =>
          order.status !== newStatus && this.canTransition(order.status, newStatus),
      );

      const updatedOrders: OrderRecord[] = [];
      for (const order of validOrders) {
        const updateResult = await tx.order.updateMany({
          where: {
            id: order.id,
            organizationId: orgId,
            status: order.status,
          },
          data: { status: newStatus },
        });

        if (updateResult.count === 1) {
          updatedOrders.push(order);
        }
      }

      if (updatedOrders.length > 0) {
        await tx.auditLog.createMany({
          data: updatedOrders.map((order) => ({
            action: 'order.bulk_status_updated',
            entityType: 'order',
            entityId: order.id,
            organizationId: orgId,
            metadata: {
              previousStatus: order.status,
              newStatus,
            },
          })),
        });
      }

      return updatedOrders;
    });

    if (transitionableOrders.length > 0) {
      await this.invalidateOrdersCache(orgId);
    }

    if (newStatus === 'shipped' && transitionableOrders.length > 0) {
      const notificationResults = await Promise.allSettled(
        transitionableOrders.map((order) =>
          this.emailService.sendOrderShippedNotification({
            orderId: order.id,
            customerId: order.customerId,
            email: order.customer?.email,
            organizationId: orgId,
          }),
        ),
      );

      notificationResults.forEach((result, index) => {
        if (result.status === 'rejected') {
          const orderId = transitionableOrders[index]?.id ?? 'unknown';
          const message =
            result.reason instanceof Error
              ? result.reason.message
              : String(result.reason);
          this.logger.error(
            `Failed to send shipped notification for order ${orderId}: ${message}`,
          );
        }
      });
    }

    return transitionableOrders.length;
  }

  async getOrdersForExport(
    filters: ExportFilters = {},
    orgId: string,
  ): Promise<OrderRecord[]> {
    this.assertOrganizationId(orgId);
    this.validateDateRange(filters.dateRange);

    const where = this.buildWhereClause(filters, orgId);
    const totalRows = await this.prisma.order.count({ where });

    if (totalRows > EXPORT_MAX_ROWS) {
      throw new BadRequestException(
        `Export exceeds the maximum row limit of ${EXPORT_MAX_ROWS}`,
      );
    }

    return this.prisma.order.findMany({
      where,
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      orderBy: { createdAt: 'desc' },
      take: EXPORT_MAX_ROWS,
    });
  }

  private buildWhereClause(
    filters: Pick<OrderFilters, 'status' | 'dateRange' | 'customerId'>,
    orgId: string,
  ): Record<string, unknown> {
    const where: Record<string, unknown> = { organizationId: orgId };

    if (filters.status) {
      where.status = filters.status;
    }

    if (filters.customerId?.trim()) {
      where.customerId = filters.customerId.trim();
    }

    if (filters.dateRange) {
      where.createdAt = {
        gte: filters.dateRange.from,
        lt: filters.dateRange.to,
      };
    }

    return where;
  }

  private validateCreateDto(dto: CreateOrderDto): CreateOrderDto {
    if (!dto || typeof dto !== 'object') {
      throw new BadRequestException('Order payload is required');
    }

    const customerId = dto.customerId?.trim();
    if (!customerId) {
      throw new BadRequestException('customerId is required');
    }

    const currency = dto.currency?.trim().toUpperCase();
    if (!currency) {
      throw new BadRequestException('currency is required');
    }

    if (!Array.isArray(dto.lineItems) || dto.lineItems.length === 0) {
      throw new BadRequestException('At least one line item is required');
    }

    if (dto.lineItems.length > MAX_LINE_ITEMS) {
      throw new BadRequestException(
        `lineItems must contain no more than ${MAX_LINE_ITEMS} entries`,
      );
    }

    const lineItems = dto.lineItems.map((item, index) => {
      if (!item.productId?.trim()) {
        throw new BadRequestException(
          `lineItems[${index}].productId is required`,
        );
      }

      if (!Number.isInteger(item.quantity) || item.quantity <= 0) {
        throw new BadRequestException(
          `lineItems[${index}].quantity must be a positive integer`,
        );
      }

      if (item.quantity > MAX_QUANTITY) {
        throw new BadRequestException(
          `lineItems[${index}].quantity exceeds the maximum of ${MAX_QUANTITY}`,
        );
      }

      if (!Number.isFinite(item.unitPrice) || item.unitPrice < 0) {
        throw new BadRequestException(
          `lineItems[${index}].unitPrice must be a non-negative number`,
        );
      }

      if (item.unitPrice > MAX_UNIT_PRICE) {
        throw new BadRequestException(
          `lineItems[${index}].unitPrice exceeds the maximum of ${MAX_UNIT_PRICE}`,
        );
      }

      this.toMinorUnits(item.unitPrice, `lineItems[${index}].unitPrice`);

      return {
        productId: item.productId.trim(),
        quantity: item.quantity,
        unitPrice: item.unitPrice,
      };
    });

    return {
      customerId,
      currency,
      lineItems,
    };
  }

  private calculateOrderTotal(
    lineItems: CreateOrderDto['lineItems'],
  ): number {
    const totalMinorUnits = lineItems.reduce((sum, item) => {
      const lineItemMinorUnits =
        this.toMinorUnits(item.unitPrice, 'unitPrice') * item.quantity;

      if (lineItemMinorUnits > MAX_MINOR_UNITS - sum) {
        throw new BadRequestException('Order total exceeds safe numeric bounds');
      }

      return sum + lineItemMinorUnits;
    }, 0);

    return totalMinorUnits / 100;
  }

  private validateDateRange(dateRange?: { from: Date; to: Date }): void {
    if (!dateRange) {
      return;
    }

    this.assertValidDate(dateRange.from, 'dateRange.from');
    this.assertValidDate(dateRange.to, 'dateRange.to');

    if (dateRange.from > dateRange.to) {
      throw new BadRequestException('dateRange.from must be before dateRange.to');
    }
  }

  private assertValidDate(value: Date, fieldName: string): void {
    if (!(value instanceof Date) || Number.isNaN(value.getTime())) {
      throw new BadRequestException(`${fieldName} must be a valid Date`);
    }
  }

  private normalizeTake(value?: number): number {
    if (value === undefined) {
      return DEFAULT_TAKE;
    }

    if (!Number.isInteger(value) || value <= 0) {
      throw new BadRequestException('take must be a positive integer');
    }

    return Math.min(value, MAX_TAKE);
  }

  private normalizeSkip(value?: number): number {
    if (value === undefined) {
      return 0;
    }

    if (!Number.isInteger(value) || value < 0) {
      throw new BadRequestException('skip must be a non-negative integer');
    }

    return Math.min(value, MAX_SKIP);
  }

  private canTransition(from: OrderStatus, to: OrderStatus): boolean {
    if (to === 'cancelled') {
      return from !== 'delivered';
    }

    if (from === 'cancelled') {
      return false;
    }

    return NEXT_STATUS[from] === to;
  }

  private async emitAuditLog(
    tx: PrismaTransactionClient,
    input: AuditLogInput,
  ): Promise<void> {
    await tx.auditLog.create({
      data: {
        action: input.action,
        entityType: 'order',
        entityId: input.entityId,
        organizationId: input.organizationId,
        metadata: input.metadata ?? {},
      },
    });
  }

  private buildCacheKey(
    prefix: string,
    orgId: string,
    version: string,
    filters: Record<string, unknown>,
  ): string {
    return `${prefix}:${orgId}:v${version}:${JSON.stringify(filters)}`;
  }

  private async getCacheVersion(orgId: string): Promise<string> {
    const versionKey = this.getCacheVersionKey(orgId);
    const version = await this.redis.get(versionKey);
    return version && version.trim().length > 0 ? version : '1';
  }

  private async invalidateOrdersCache(orgId: string): Promise<void> {
    const versionKey = this.getCacheVersionKey(orgId);
    await this.redis.set(
      versionKey,
      String(Date.now()),
      CACHE_VERSION_TTL_SECONDS,
    );
  }

  private getCacheVersionKey(orgId: string): string {
    return `orders:cache-version:${orgId}`;
  }

  private serializeFilters(
    filters: Pick<OrderFilters, 'status' | 'dateRange' | 'customerId'>,
  ): Record<string, unknown> {
    return {
      status: filters.status ?? null,
      customerId: filters.customerId?.trim() ?? null,
      dateRange: filters.dateRange
        ? {
            from: filters.dateRange.from.toISOString(),
            to: filters.dateRange.to.toISOString(),
          }
        : null,
    };
  }

  private async tryParseCachedValue<T>(
    cacheKey: string,
    payload: string,
  ): Promise<T | null> {
    try {
      return JSON.parse(payload, (key, value) => {
        if (
          DATE_KEYS.has(key) &&
          typeof value === 'string' &&
          /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(value)
        ) {
          return new Date(value);
        }

        return value;
      }) as T;
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger.warn(
        `Ignoring malformed cache entry for ${cacheKey}: ${message}`,
      );
      await this.redis.del?.(cacheKey);
      return null;
    }
  }

  private assertOrganizationId(orgId: string): void {
    if (!orgId?.trim()) {
      throw new BadRequestException('orgId is required');
    }
  }

  private assertOrderId(id: string): void {
    if (!id?.trim()) {
      throw new BadRequestException('id is required');
    }
  }

  private assertOrderStatus(status: OrderStatus): void {
    if (!ORDER_STATUSES.includes(status)) {
      throw new BadRequestException('status is invalid');
    }
  }

  private validateBulkIds(ids: string[]): string[] {
    if (!Array.isArray(ids)) {
      throw new BadRequestException('ids must be an array of order IDs');
    }

    if (ids.length > MAX_BULK_UPDATE_IDS) {
      throw new BadRequestException(
        `ids must contain no more than ${MAX_BULK_UPDATE_IDS} entries`,
      );
    }

    const normalizedIds = ids.map((id, index) => {
      if (typeof id !== 'string' || id.trim().length === 0) {
        throw new BadRequestException(
          `ids[${index}] must be a non-empty string`,
        );
      }

      return id.trim();
    });

    return Array.from(new Set(normalizedIds));
  }

  private toMinorUnits(value: number, fieldName: string): number {
    const scaledValue = value * 100;
    const roundedValue = Math.round(scaledValue);

    if (!Number.isFinite(scaledValue) || !Number.isSafeInteger(roundedValue)) {
      throw new BadRequestException(`${fieldName} exceeds safe numeric bounds`);
    }

    if (Math.abs(roundedValue - scaledValue) > 1e-6) {
      throw new BadRequestException(`${fieldName} must have at most 2 decimal places`);
    }

    return roundedValue;
  }
}
