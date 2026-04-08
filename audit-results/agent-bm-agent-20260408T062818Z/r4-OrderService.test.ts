import {
  BadRequestException,
  Logger,
  NotFoundException,
} from '@nestjs/common';

import { OrderService } from './r2-OrderService';

const ORGANIZATION_ID = 'org-123';
const ORDER_ID = 'order-123';
const SECOND_ORDER_ID = 'order-456';
const THIRD_ORDER_ID = 'order-789';
const CUSTOMER_ID = 'customer-123';
const CUSTOMER_EMAIL = 'buyer@example.com';
const CACHE_VERSION = '7';
const PAGE_TAKE = 25;
const PAGE_SKIP = 5;
const EXPORT_LIMIT = 10_000;
const EMAIL_FAILURE_MESSAGE = 'SMTP unavailable';
const TRANSACTION_FAILURE_MESSAGE = 'transaction failed';
const RANGE_FROM = new Date('2026-04-01T00:00:00.000Z');
const RANGE_TO = new Date('2026-05-01T00:00:00.000Z');
const MONTH = new Date('2026-04-15T00:00:00.000Z');
const ORDER_CREATED_AT = new Date('2026-04-08T08:00:00.000Z');
const ORDER_UPDATED_AT = new Date('2026-04-08T09:00:00.000Z');

const CREATE_ORDER_DTO = {
  customerId: CUSTOMER_ID,
  currency: 'usd',
  lineItems: [
    { productId: 'product-1', quantity: 2, unitPrice: 10.5 },
    { productId: 'product-2', quantity: 1, unitPrice: 5.25 },
  ],
};

const EXPECTED_TOTAL_AMOUNT = 26.25;

const buildOrder = (
  overrides: Partial<Record<string, unknown>> = {},
) => ({
  id: ORDER_ID,
  organizationId: ORGANIZATION_ID,
  customerId: CUSTOMER_ID,
  currency: 'USD',
  status: 'pending',
  totalAmount: EXPECTED_TOTAL_AMOUNT,
  createdAt: ORDER_CREATED_AT,
  updatedAt: ORDER_UPDATED_AT,
  lineItems: [
    {
      id: 'line-item-1',
      orderId: ORDER_ID,
      productId: 'product-1',
      quantity: 2,
      unitPrice: 10.5,
      createdAt: ORDER_CREATED_AT,
      updatedAt: ORDER_UPDATED_AT,
    },
  ],
  customer: {
    id: CUSTOMER_ID,
    email: CUSTOMER_EMAIL,
  },
  payments: [
    {
      id: 'payment-1',
      amount: EXPECTED_TOTAL_AMOUNT,
      currency: 'USD',
      status: 'captured',
      createdAt: ORDER_CREATED_AT,
    },
  ],
  ...overrides,
});

const createPrismaMock = () => {
  const prisma = {
    order: {
      findMany: jest.fn(),
      findFirst: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
      delete: jest.fn(),
      deleteMany: jest.fn(),
      count: jest.fn(),
      groupBy: jest.fn(),
    },
    orderLineItem: {
      deleteMany: jest.fn(),
    },
    auditLog: {
      create: jest.fn(),
      createMany: jest.fn(),
    },
    $transaction: jest.fn(),
  };

  prisma.$transaction.mockImplementation(
    async (
      callback: (tx: {
        order: typeof prisma.order;
        orderLineItem: typeof prisma.orderLineItem;
        auditLog: typeof prisma.auditLog;
      }) => Promise<unknown>,
    ) =>
      callback({
        order: prisma.order,
        orderLineItem: prisma.orderLineItem,
        auditLog: prisma.auditLog,
      }),
  );

  return prisma;
};

const createRedisMock = () => ({
  get: jest.fn(),
  set: jest.fn(),
  del: jest.fn(),
});

const createEmailServiceMock = () => ({
  sendOrderShippedNotification: jest.fn(),
});

const PAYMENT_GATEWAY = { name: 'stripe' };

describe('OrderService', () => {
  let prisma: ReturnType<typeof createPrismaMock>;
  let redis: ReturnType<typeof createRedisMock>;
  let emailService: ReturnType<typeof createEmailServiceMock>;
  let service: OrderService;

  beforeEach(() => {
    jest.clearAllMocks();
    prisma = createPrismaMock();
    redis = createRedisMock();
    emailService = createEmailServiceMock();
    service = new OrderService(
      prisma as never,
      redis as never,
      emailService as never,
      PAYMENT_GATEWAY as never,
    );
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('returns cached orders when redis has a valid paginated entry', async () => {
    const cachedOrder = buildOrder();
    const expectedCacheKey = buildExpectedListCacheKey({
      take: PAGE_TAKE,
      skip: PAGE_SKIP,
    });

    redis.get
      .mockResolvedValueOnce(CACHE_VERSION)
      .mockResolvedValueOnce(JSON.stringify([cachedOrder]));

    const result = await service.findAll(
      { take: PAGE_TAKE, skip: PAGE_SKIP },
      ORGANIZATION_ID,
    );

    expect(result).toEqual([cachedOrder]);
    expect(redis.get).toHaveBeenNthCalledWith(
      1,
      `orders:cache-version:${ORGANIZATION_ID}`,
    );
    expect(redis.get).toHaveBeenNthCalledWith(2, expectedCacheKey);
    expect(prisma.order.findMany).not.toHaveBeenCalled();
    expect(redis.set).not.toHaveBeenCalled();
  });

  it('queries prisma and populates redis when the cache misses', async () => {
    const prismaOrders = [buildOrder()];
    const expectedCacheKey = buildExpectedListCacheKey({
      status: 'pending',
      customerId: CUSTOMER_ID,
      dateRange: { from: RANGE_FROM, to: RANGE_TO },
      take: PAGE_TAKE,
      skip: PAGE_SKIP,
    });

    redis.get.mockResolvedValueOnce(CACHE_VERSION).mockResolvedValueOnce(null);
    prisma.order.findMany.mockResolvedValueOnce(prismaOrders);

    const result = await service.findAll(
      {
        status: 'pending',
        customerId: CUSTOMER_ID,
        dateRange: { from: RANGE_FROM, to: RANGE_TO },
        take: PAGE_TAKE,
        skip: PAGE_SKIP,
      },
      ORGANIZATION_ID,
    );

    expect(result).toEqual(prismaOrders);
    expect(redis.get).toHaveBeenNthCalledWith(
      1,
      `orders:cache-version:${ORGANIZATION_ID}`,
    );
    expect(redis.get).toHaveBeenNthCalledWith(2, expectedCacheKey);
    expect(prisma.order.findMany).toHaveBeenCalledWith({
      where: {
        organizationId: ORGANIZATION_ID,
        status: 'pending',
        customerId: CUSTOMER_ID,
        createdAt: {
          gte: RANGE_FROM,
          lt: RANGE_TO,
        },
      },
      orderBy: { createdAt: 'desc' },
      skip: PAGE_SKIP,
      take: PAGE_TAKE,
    });
    expect(redis.set).toHaveBeenCalledWith(
      expectedCacheKey,
      JSON.stringify(prismaOrders),
      300,
    );
  });

  it('falls back to prisma and clears the cache when the cached payload is malformed', async () => {
    const prismaOrders = [buildOrder()];
    const expectedCacheKey = buildExpectedListCacheKey({
      take: PAGE_TAKE,
      skip: PAGE_SKIP,
    });

    redis.get.mockResolvedValueOnce(CACHE_VERSION).mockResolvedValueOnce('{bad-json');
    prisma.order.findMany.mockResolvedValueOnce(prismaOrders);

    const result = await service.findAll(
      { take: PAGE_TAKE, skip: PAGE_SKIP },
      ORGANIZATION_ID,
    );

    expect(result).toEqual(prismaOrders);
    expect(redis.del).toHaveBeenCalledWith(expectedCacheKey);
    expect(prisma.order.findMany).toHaveBeenCalledTimes(1);
  });

  it('finds a single order scoped to the organization', async () => {
    const order = buildOrder();
    prisma.order.findFirst.mockResolvedValueOnce(order);

    const result = await service.findById(ORDER_ID, ORGANIZATION_ID);

    expect(result).toEqual(order);
    expect(prisma.order.findFirst).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORGANIZATION_ID },
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
    });
  });

  it('throws NotFoundException when order not found in org', async () => {
    prisma.order.findFirst.mockResolvedValueOnce(null);

    await expectReject(
      () => service.findById(ORDER_ID, ORGANIZATION_ID),
      NotFoundException,
      `Order ${ORDER_ID} was not found in this organization`,
    );
  });

  it('creates an order with nested line items inside a transaction', async () => {
    const createdOrder = buildOrder({
      lineItems: [
        {
          id: 'line-item-1',
          orderId: ORDER_ID,
          productId: 'product-1',
          quantity: 2,
          unitPrice: 10.5,
        },
        {
          id: 'line-item-2',
          orderId: ORDER_ID,
          productId: 'product-2',
          quantity: 1,
          unitPrice: 5.25,
        },
      ],
    });
    prisma.order.create.mockResolvedValueOnce(createdOrder);

    const result = await service.create(CREATE_ORDER_DTO, ORGANIZATION_ID);

    expect(result).toEqual(createdOrder);
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.order.create).toHaveBeenCalledWith({
      data: {
        organizationId: ORGANIZATION_ID,
        customerId: CUSTOMER_ID,
        currency: 'USD',
        status: 'pending',
        totalAmount: EXPECTED_TOTAL_AMOUNT,
        lineItems: {
          create: [
            { productId: 'product-1', quantity: 2, unitPrice: 10.5 },
            { productId: 'product-2', quantity: 1, unitPrice: 5.25 },
          ],
        },
      },
      include: {
        lineItems: true,
      },
    });
    expect(prisma.auditLog.create).toHaveBeenCalledWith({
      data: {
        action: 'order.created',
        entityType: 'order',
        entityId: ORDER_ID,
        organizationId: ORGANIZATION_ID,
        metadata: {
          customerId: CUSTOMER_ID,
          currency: 'USD',
          lineItemCount: 2,
          totalAmount: EXPECTED_TOTAL_AMOUNT,
        },
      },
    });
    expect(redis.set).toHaveBeenCalledWith(
      `orders:cache-version:${ORGANIZATION_ID}`,
      expect.any(String),
      30 * 24 * 60 * 60,
    );
  });

  it('bubbles transaction errors from create without invalidating cache', async () => {
    const transactionError = new Error(TRANSACTION_FAILURE_MESSAGE);
    prisma.$transaction.mockRejectedValueOnce(transactionError);

    await expect(service.create(CREATE_ORDER_DTO, ORGANIZATION_ID)).rejects.toThrow(
      transactionError,
    );

    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.auditLog.create).not.toHaveBeenCalled();
    expect(prisma.order.create).not.toHaveBeenCalled();
    expect(redis.set).not.toHaveBeenCalled();
  });

  it('deletes an order and its line items atomically', async () => {
    const existingOrder = buildOrder();
    prisma.order.findFirst.mockResolvedValueOnce(existingOrder);
    prisma.orderLineItem.deleteMany.mockResolvedValueOnce({ count: 1 });
    prisma.order.deleteMany.mockResolvedValueOnce({ count: 1 });

    await service.deleteOrder(ORDER_ID, ORGANIZATION_ID);

    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.orderLineItem.deleteMany).toHaveBeenCalledWith({
      where: { orderId: ORDER_ID },
    });
    expect(prisma.order.deleteMany).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORGANIZATION_ID },
    });
    expect(prisma.auditLog.create).toHaveBeenCalledWith({
      data: {
        action: 'order.deleted',
        entityType: 'order',
        entityId: ORDER_ID,
        organizationId: ORGANIZATION_ID,
        metadata: {
          lineItemCount: existingOrder.lineItems.length,
          previousStatus: existingOrder.status,
        },
      },
    });
    expect(redis.set).toHaveBeenCalledWith(
      `orders:cache-version:${ORGANIZATION_ID}`,
      expect.any(String),
      30 * 24 * 60 * 60,
    );
  });

  it('updates status through a valid transition and logs email delivery failures', async () => {
    const processingOrder = buildOrder({
      status: 'processing',
      customer: { id: CUSTOMER_ID, email: CUSTOMER_EMAIL },
    });
    const shippedOrder = buildOrder({
      status: 'shipped',
      customer: { id: CUSTOMER_ID, email: CUSTOMER_EMAIL },
    });
    const loggerSpy = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => undefined);

    prisma.order.findFirst
      .mockResolvedValueOnce(processingOrder)
      .mockResolvedValueOnce(shippedOrder);
    prisma.order.updateMany.mockResolvedValueOnce({ count: 1 });
    emailService.sendOrderShippedNotification.mockRejectedValueOnce(
      new Error(EMAIL_FAILURE_MESSAGE),
    );

    const result = await service.updateStatus(
      ORDER_ID,
      'shipped',
      ORGANIZATION_ID,
    );

    expect(result).toEqual(shippedOrder);
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.order.updateMany).toHaveBeenCalledWith({
      where: {
        id: ORDER_ID,
        organizationId: ORGANIZATION_ID,
        status: 'processing',
      },
      data: { status: 'shipped' },
    });
    expect(emailService.sendOrderShippedNotification).toHaveBeenCalledWith({
      orderId: ORDER_ID,
      customerId: CUSTOMER_ID,
      email: CUSTOMER_EMAIL,
      organizationId: ORGANIZATION_ID,
    });
    expect(loggerSpy).toHaveBeenCalledWith(
      `Failed to send shipped notification for order ${ORDER_ID}: ${EMAIL_FAILURE_MESSAGE}`,
    );
    expect(prisma.auditLog.create).toHaveBeenCalledWith({
      data: {
        action: 'order.status_updated',
        entityType: 'order',
        entityId: ORDER_ID,
        organizationId: ORGANIZATION_ID,
        metadata: {
          previousStatus: 'processing',
          newStatus: 'shipped',
        },
      },
    });
    expect(redis.set).toHaveBeenCalledWith(
      `orders:cache-version:${ORGANIZATION_ID}`,
      expect.any(String),
      30 * 24 * 60 * 60,
    );
  });

  it('throws when a concurrent status change makes the compare-and-swap fail', async () => {
    prisma.order.findFirst.mockResolvedValueOnce(
      buildOrder({
        status: 'processing',
        customer: { id: CUSTOMER_ID, email: CUSTOMER_EMAIL },
      }),
    );
    prisma.order.updateMany.mockResolvedValueOnce({ count: 0 });

    await expectReject(
      () => service.updateStatus(ORDER_ID, 'shipped', ORGANIZATION_ID),
      BadRequestException,
      `Order ${ORDER_ID} changed during status update; retry the request`,
    );

    expect(prisma.auditLog.create).not.toHaveBeenCalled();
    expect(emailService.sendOrderShippedNotification).not.toHaveBeenCalled();
    expect(redis.set).not.toHaveBeenCalled();
  });

  it('throws BadRequestException on invalid state transitions', async () => {
    prisma.order.findFirst.mockResolvedValueOnce(
      buildOrder({
        status: 'shipped',
      }),
    );

    await expectReject(
      () => service.updateStatus(ORDER_ID, 'processing', ORGANIZATION_ID),
      BadRequestException,
      `Cannot transition order ${ORDER_ID} from shipped to processing`,
    );

    expect(prisma.order.updateMany).not.toHaveBeenCalled();
  });

  it('calculates monthly revenue by currency for the requested month', async () => {
    const expectedMonthStart = new Date(
      Date.UTC(MONTH.getUTCFullYear(), MONTH.getUTCMonth(), 1, 0, 0, 0, 0),
    );
    const expectedMonthEnd = new Date(
      Date.UTC(MONTH.getUTCFullYear(), MONTH.getUTCMonth() + 1, 1, 0, 0, 0, 0),
    );

    prisma.order.groupBy.mockResolvedValueOnce([
      { currency: 'USD', _sum: { totalAmount: 1200 } },
      { currency: 'EUR', _sum: { totalAmount: 350 } },
    ]);

    const result = await service.calculateMonthlyRevenue(MONTH, ORGANIZATION_ID);

    expect(result).toEqual([
      { currency: 'USD', total: 1200 },
      { currency: 'EUR', total: 350 },
    ]);
    expect(prisma.order.groupBy).toHaveBeenCalledWith({
      by: ['currency'],
      where: {
        organizationId: ORGANIZATION_ID,
        createdAt: {
          gte: expectedMonthStart,
          lt: expectedMonthEnd,
        },
        status: {
          not: 'cancelled',
        },
      },
      _sum: {
        totalAmount: true,
      },
    });
  });

  it('bulk updates only orders with valid transitions', async () => {
    prisma.order.findMany.mockResolvedValueOnce([
      buildOrder({
        id: ORDER_ID,
        status: 'confirmed',
        customer: { id: CUSTOMER_ID, email: CUSTOMER_EMAIL },
      }),
      buildOrder({
        id: SECOND_ORDER_ID,
        status: 'delivered',
      }),
      buildOrder({
        id: THIRD_ORDER_ID,
        status: 'cancelled',
      }),
    ]);
    prisma.order.updateMany.mockResolvedValueOnce({ count: 1 });

    const result = await service.bulkUpdateStatus(
      [ORDER_ID, SECOND_ORDER_ID, THIRD_ORDER_ID],
      'cancelled',
      ORGANIZATION_ID,
    );

    expect(result).toBe(1);
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.order.updateMany).toHaveBeenCalledTimes(1);
    expect(prisma.order.updateMany).toHaveBeenCalledWith({
      where: {
        id: ORDER_ID,
        organizationId: ORGANIZATION_ID,
        status: 'confirmed',
      },
      data: { status: 'cancelled' },
    });
    expect(prisma.auditLog.createMany).toHaveBeenCalledWith({
      data: [
        {
          action: 'order.bulk_status_updated',
          entityType: 'order',
          entityId: ORDER_ID,
          organizationId: ORGANIZATION_ID,
          metadata: {
            previousStatus: 'confirmed',
            newStatus: 'cancelled',
          },
        },
      ],
    });
    expect(redis.set).toHaveBeenCalledWith(
      `orders:cache-version:${ORGANIZATION_ID}`,
      expect.any(String),
      30 * 24 * 60 * 60,
    );
  });

  it('sends bulk shipped notifications for every updated order and logs individual failures', async () => {
    const firstProcessingOrder = buildOrder({
      id: ORDER_ID,
      status: 'processing',
      customer: { id: CUSTOMER_ID, email: CUSTOMER_EMAIL },
    });
    const secondProcessingOrder = buildOrder({
      id: SECOND_ORDER_ID,
      status: 'processing',
      customer: { id: 'customer-456', email: 'second@example.com' },
    });
    const loggerSpy = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => undefined);

    prisma.order.findMany.mockResolvedValueOnce([
      firstProcessingOrder,
      secondProcessingOrder,
    ]);
    prisma.order.updateMany
      .mockResolvedValueOnce({ count: 1 })
      .mockResolvedValueOnce({ count: 1 });
    emailService.sendOrderShippedNotification
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error(EMAIL_FAILURE_MESSAGE));

    const result = await service.bulkUpdateStatus(
      [ORDER_ID, SECOND_ORDER_ID],
      'shipped',
      ORGANIZATION_ID,
    );

    expect(result).toBe(2);
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.order.updateMany).toHaveBeenCalledTimes(2);
    expect(prisma.auditLog.createMany).toHaveBeenCalledWith({
      data: [
        {
          action: 'order.bulk_status_updated',
          entityType: 'order',
          entityId: ORDER_ID,
          organizationId: ORGANIZATION_ID,
          metadata: {
            previousStatus: 'processing',
            newStatus: 'shipped',
          },
        },
        {
          action: 'order.bulk_status_updated',
          entityType: 'order',
          entityId: SECOND_ORDER_ID,
          organizationId: ORGANIZATION_ID,
          metadata: {
            previousStatus: 'processing',
            newStatus: 'shipped',
          },
        },
      ],
    });
    expect(emailService.sendOrderShippedNotification).toHaveBeenNthCalledWith(1, {
      orderId: ORDER_ID,
      customerId: CUSTOMER_ID,
      email: CUSTOMER_EMAIL,
      organizationId: ORGANIZATION_ID,
    });
    expect(emailService.sendOrderShippedNotification).toHaveBeenNthCalledWith(2, {
      orderId: SECOND_ORDER_ID,
      customerId: 'customer-456',
      email: 'second@example.com',
      organizationId: ORGANIZATION_ID,
    });
    expect(loggerSpy).toHaveBeenCalledWith(
      `Failed to send shipped notification for order ${SECOND_ORDER_ID}: ${EMAIL_FAILURE_MESSAGE}`,
    );
  });

  it('returns export rows with relations when the count is within maxRows', async () => {
    const exportRows = [buildOrder()];
    prisma.order.count.mockResolvedValueOnce(EXPORT_LIMIT);
    prisma.order.findMany.mockResolvedValueOnce(exportRows);

    const result = await service.getOrdersForExport(
      {
        status: 'pending',
        dateRange: { from: RANGE_FROM, to: RANGE_TO },
      },
      ORGANIZATION_ID,
    );

    expect(result).toEqual(exportRows);
    expect(prisma.order.count).toHaveBeenCalledWith({
      where: {
        organizationId: ORGANIZATION_ID,
        status: 'pending',
        createdAt: {
          gte: RANGE_FROM,
          lt: RANGE_TO,
        },
      },
    });
    expect(prisma.order.findMany).toHaveBeenCalledWith({
      where: {
        organizationId: ORGANIZATION_ID,
        status: 'pending',
        createdAt: {
          gte: RANGE_FROM,
          lt: RANGE_TO,
        },
      },
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      orderBy: { createdAt: 'desc' },
      take: EXPORT_LIMIT,
    });
  });

  it('throws when export count exceeds maxRows before loading relations', async () => {
    prisma.order.count.mockResolvedValueOnce(EXPORT_LIMIT + 1);

    await expectReject(
      () =>
        service.getOrdersForExport(
          {
            status: 'pending',
            dateRange: { from: RANGE_FROM, to: RANGE_TO },
          },
          ORGANIZATION_ID,
        ),
      BadRequestException,
      `Export exceeds the maximum row limit of ${EXPORT_LIMIT}`,
    );

    expect(prisma.order.findMany).not.toHaveBeenCalled();
  });
});

function buildExpectedListCacheKey(filters: {
  status?: string;
  customerId?: string;
  dateRange?: { from: Date; to: Date };
  take: number;
  skip: number;
}): string {
  return `orders:list:${ORGANIZATION_ID}:v${CACHE_VERSION}:${JSON.stringify({
    status: filters.status ?? null,
    customerId: filters.customerId?.trim() ?? null,
    dateRange: filters.dateRange
      ? {
          from: filters.dateRange.from.toISOString(),
          to: filters.dateRange.to.toISOString(),
        }
      : null,
    take: filters.take,
    skip: filters.skip,
  })}`;
}

async function expectReject(
  callback: () => Promise<unknown>,
  errorType: new (...args: never[]) => Error,
  expectedMessage: string,
): Promise<void> {
  expect.assertions(2);

  try {
    await callback();
    throw new Error('Expected the promise to reject');
  } catch (error: unknown) {
    expect(error).toBeInstanceOf(errorType);
    expect((error as Error).message).toBe(expectedMessage);
  }
}
