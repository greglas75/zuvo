import { BadRequestException, ConflictException, NotFoundException } from '@nestjs/common';

import { OrderService } from './r2-OrderService';

type OrderStatus = 'pending' | 'confirmed' | 'processing' | 'shipped' | 'delivered' | 'cancelled';

type MockOrder = {
  id: string;
  organizationId: string;
  customerId: string;
  status: OrderStatus;
  currency: string;
  totalAmount: number;
  createdAt: Date;
  lineItems?: Array<{ id: string; productId: string; quantity: number; unitPrice: number; createdAt?: Date }>;
  customer?: { id: string; name: string; email: string };
  payments?: Array<{ id: string; amount: number; currency: string; createdAt?: Date }>;
};

const ORG_ID = 'org-123';
const ORDER_ID = 'order-123';
const CUSTOMER_ID = 'customer-123';
const ISO_CREATED_AT = '2026-03-01T00:00:00.000Z';
const CREATED_AT = new Date(ISO_CREATED_AT);
const BASE_ORDER: MockOrder = {
  id: ORDER_ID,
  organizationId: ORG_ID,
  customerId: CUSTOMER_ID,
  status: 'pending',
  currency: 'USD',
  totalAmount: 120.5,
  createdAt: CREATED_AT,
};

const VALID_CREATE_DTO = {
  customerId: CUSTOMER_ID,
  currency: ' usd ',
  lineItems: [
    { productId: 'prod-1', quantity: 1, unitPrice: 12.5 },
    { productId: 'prod-2', quantity: 2, unitPrice: 15 },
  ],
};

const MONTH = new Date('2026-03-15T00:00:00.000Z');

function makeOrder(index: number, overrides: Partial<MockOrder> = {}): MockOrder {
  return {
    ...BASE_ORDER,
    id: `${ORDER_ID}-${index}`,
    createdAt: new Date(Date.UTC(2026, 2, index + 1)),
    ...overrides,
  };
}

function makeOrders(length: number, overridesByIndex: (index: number) => Partial<MockOrder> = () => ({})): MockOrder[] {
  return Array.from({ length }, (_, index) => makeOrder(index + 1, overridesByIndex(index + 1)));
}

function createPrismaMock() {
  const tx: any = {
    order: {
      findMany: jest.fn(),
      findFirst: jest.fn(),
      create: jest.fn(),
      delete: jest.fn(),
      deleteMany: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
    },
    orderLineItem: {
      deleteMany: jest.fn(),
    },
    auditLog: {
      create: jest.fn(),
    },
  };

  const prisma: any = {
    order: {
      findMany: jest.fn(),
      findFirst: jest.fn(),
      create: jest.fn(),
      delete: jest.fn(),
      deleteMany: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
    },
    orderLineItem: {
      deleteMany: jest.fn(),
    },
    auditLog: {
      create: jest.fn(),
    },
    tx,
    $transaction: jest.fn(async (callback: (client: any) => Promise<unknown>) => callback(tx)),
  };

  return prisma;
}

describe('OrderService (round 3)', () => {
  let prisma: any;
  let redisService: any;
  let emailService: any;
  let paymentGateway: any;
  let service: OrderService;

  beforeEach(() => {
    jest.clearAllMocks();

    prisma = createPrismaMock();
    redisService = {
      get: jest.fn(),
      set: jest.fn(),
      setex: jest.fn(),
    };
    emailService = {
      sendOrderShipped: jest.fn().mockResolvedValue(undefined),
    };
    paymentGateway = {
      validateCurrency: jest.fn().mockReturnValue(true),
    };

    service = new OrderService(prisma, redisService, emailService, paymentGateway);
  });

  it('returns cached orders on cache hit and rehydrates date fields', async () => {
    const cachedOrder = { ...BASE_ORDER, createdAt: ISO_CREATED_AT };
    redisService.get.mockResolvedValueOnce('cache-v1').mockResolvedValueOnce(JSON.stringify([cachedOrder]));

    const result = await service.findAll({ take: 10, skip: 0 }, ORG_ID);

    expect(result).toHaveLength(1);
    expect(result[0].createdAt).toBeInstanceOf(Date);
    expect(result[0].createdAt.toISOString()).toBe(ISO_CREATED_AT);
    expect(prisma.order.findMany).not.toHaveBeenCalled();
    expect(redisService.get).toHaveBeenNthCalledWith(1, `orders:${ORG_ID}:version`);
  });

  it('queries the database and caches the list on cache miss', async () => {
    redisService.get.mockResolvedValueOnce('cache-v1').mockResolvedValueOnce(null);
    prisma.order.findMany.mockResolvedValueOnce([BASE_ORDER]);

    const filters = {
      status: 'pending' as const,
      customerId: CUSTOMER_ID,
      dateRange: {
        from: new Date('2026-03-01T00:00:00.000Z'),
        to: new Date('2026-03-31T23:59:59.000Z'),
      },
      take: 25,
      skip: 5,
    };

    const result = await service.findAll(filters, ORG_ID);

    expect(result).toEqual([BASE_ORDER]);
    expect(prisma.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_ID,
          status: 'pending',
          customerId: CUSTOMER_ID,
          createdAt: {
            gte: new Date('2026-03-01T00:00:00.000Z'),
            lte: new Date('2026-03-31T23:59:59.000Z'),
          },
        }),
        take: 25,
        skip: 5,
      }),
    );
    expect(redisService.setex).toHaveBeenCalledWith(
      expect.stringContaining(`orders:${ORG_ID}:findAll:`),
      300,
      expect.any(String),
    );
    expect(redisService.get).toHaveBeenNthCalledWith(
      2,
      `orders:${ORG_ID}:findAll:cache-v1:${JSON.stringify({
        status: 'pending',
        customerId: CUSTOMER_ID,
        dateRange: {
          from: '2026-03-01T00:00:00.000Z',
          to: '2026-03-31T23:59:59.000Z',
        },
        take: 25,
        skip: 5,
      })}`,
    );
    const cachedListPayload = JSON.parse(redisService.setex.mock.calls[0][2] as string);
    expect(cachedListPayload).toEqual([{ ...BASE_ORDER, createdAt: ISO_CREATED_AT }]);
  });

  it('throws NotFoundException when order not found in org', async () => {
    redisService.get.mockResolvedValueOnce('cache-v1').mockResolvedValueOnce(null);
    prisma.order.findFirst.mockResolvedValueOnce(null);

    const promise = service.findById(ORDER_ID, ORG_ID);
    await expect(promise).rejects.toBeInstanceOf(NotFoundException);
    await expect(promise).rejects.toThrow(`Order ${ORDER_ID} not found`);
  });

  it('rehydrates a cached order by id without hitting the database', async () => {
    const cachedOrder = {
      ...BASE_ORDER,
      createdAt: ISO_CREATED_AT,
      lineItems: [{ id: 'li-1', productId: 'prod-1', quantity: 1, unitPrice: 12.5, createdAt: ISO_CREATED_AT }],
    };
    redisService.get.mockResolvedValueOnce('cache-v1').mockResolvedValueOnce(JSON.stringify(cachedOrder));

    const result = await service.findById(ORDER_ID, ORG_ID);

    expect(result.createdAt).toBeInstanceOf(Date);
    expect(result.createdAt.toISOString()).toBe(ISO_CREATED_AT);
    expect(result.lineItems?.[0].createdAt).toBeInstanceOf(Date);
    expect(result.lineItems?.[0].createdAt?.toISOString()).toBe(ISO_CREATED_AT);
    expect(prisma.order.findFirst).not.toHaveBeenCalled();
    expect(redisService.get).toHaveBeenNthCalledWith(1, `orders:${ORG_ID}:version`);
    expect(redisService.get).toHaveBeenNthCalledWith(2, `orders:${ORG_ID}:findById:cache-v1:{"id":"${ORDER_ID}"}`);
  });

  it('returns an order by id when it exists in the tenant scope', async () => {
    redisService.get.mockResolvedValueOnce('cache-v1').mockResolvedValueOnce(null);
    prisma.order.findFirst.mockResolvedValueOnce(BASE_ORDER);

    const result = await service.findById(ORDER_ID, ORG_ID);

    expect(result).toEqual(BASE_ORDER);
    expect(prisma.order.findFirst).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_ID },
    });
    expect(redisService.setex).toHaveBeenCalledWith(
      expect.stringContaining(`orders:${ORG_ID}:findById:`),
      300,
      expect.any(String),
    );
    expect(redisService.get).toHaveBeenNthCalledWith(2, `orders:${ORG_ID}:findById:cache-v1:{"id":"${ORDER_ID}"}`);
  });

  it('creates an order with nested line items, audits the mutation, and invalidates cache', async () => {
    const createdOrder = { ...BASE_ORDER, id: 'order-created', status: 'pending' as const, totalAmount: 42.5 };
    prisma.tx.order.create.mockResolvedValueOnce(createdOrder);
    prisma.tx.auditLog.create.mockResolvedValueOnce({});

    const result = await service.create(VALID_CREATE_DTO, ORG_ID);

    expect(result).toEqual(createdOrder);
    expect(result.totalAmount).toBe(42.5);
    expect(paymentGateway.validateCurrency).toHaveBeenCalledWith('USD');
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.order.create).not.toHaveBeenCalled();
    expect(prisma.tx.order.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          organizationId: ORG_ID,
          customerId: CUSTOMER_ID,
          status: 'pending',
          currency: 'USD',
          totalAmount: 42.5,
          lineItems: {
            create: [
              { productId: 'prod-1', quantity: 1, unitPrice: 12.5 },
              { productId: 'prod-2', quantity: 2, unitPrice: 15 },
            ],
          },
        }),
        include: { lineItems: true },
      }),
    );
    expect(prisma.tx.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ action: 'order.create', organizationId: ORG_ID }),
      }),
    );
    expect(redisService.set).toHaveBeenCalledWith(
      `orders:${ORG_ID}:version`,
      expect.stringContaining(':'),
    );
  });

  it('throws BadRequestException before persistence when currency validation fails', async () => {
    paymentGateway.validateCurrency.mockReturnValueOnce(false);

    const promise = service.create(VALID_CREATE_DTO, ORG_ID);
    await expect(promise).rejects.toBeInstanceOf(BadRequestException);
    await expect(promise).rejects.toThrow('unsupported currency: USD');
    expect(prisma.$transaction).not.toHaveBeenCalled();
    expect(prisma.tx.order.create).not.toHaveBeenCalled();
    expect(prisma.tx.auditLog.create).not.toHaveBeenCalled();
    expect(redisService.set).not.toHaveBeenCalled();
  });

  it('propagates transaction rollback errors from create and does not invalidate cache', async () => {
    prisma.tx.order.create.mockResolvedValueOnce({
      ...BASE_ORDER,
      id: 'order-created',
      status: 'pending' as const,
      totalAmount: 42.5,
    });
    prisma.tx.auditLog.create.mockRejectedValueOnce(new Error('audit log failed'));

    await expect(service.create(VALID_CREATE_DTO, ORG_ID)).rejects.toThrow('audit log failed');
    expect(prisma.tx.order.create).toHaveBeenCalled();
    expect(prisma.tx.auditLog.create).toHaveBeenCalled();
    expect(redisService.set).not.toHaveBeenCalled();
  });

  it('deletes the order and its line items atomically within the tenant scope', async () => {
    prisma.tx.order.findFirst.mockResolvedValueOnce({ ...BASE_ORDER, status: 'confirmed' });
    prisma.tx.orderLineItem.deleteMany.mockResolvedValueOnce({ count: 2 });
    prisma.tx.order.deleteMany.mockResolvedValueOnce({ count: 1 });
    prisma.tx.auditLog.create.mockResolvedValueOnce({});

    await service.deleteOrder(ORDER_ID, ORG_ID);

    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.order.findFirst).not.toHaveBeenCalled();
    expect(prisma.orderLineItem.deleteMany).not.toHaveBeenCalled();
    expect(prisma.order.deleteMany).not.toHaveBeenCalled();
    expect(prisma.tx.order.findFirst).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_ID },
      select: { id: true, customerId: true, status: true },
    });
    expect(prisma.tx.orderLineItem.deleteMany).toHaveBeenCalledWith({
      where: { orderId: ORDER_ID, organizationId: ORG_ID },
    });
    expect(prisma.tx.order.deleteMany).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_ID },
    });
    expect(prisma.tx.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ action: 'order.delete', organizationId: ORG_ID }),
      }),
    );
    expect(redisService.set).toHaveBeenCalledWith(`orders:${ORG_ID}:version`, expect.any(String));
  });

  it('rolls back deleteOrder and skips cache invalidation when a transactional step fails', async () => {
    prisma.tx.order.findFirst.mockResolvedValueOnce({ ...BASE_ORDER, status: 'confirmed' });
    prisma.tx.orderLineItem.deleteMany.mockRejectedValueOnce(new Error('delete failure'));

    const promise = service.deleteOrder(ORDER_ID, ORG_ID);
    await expect(promise).rejects.toThrow('delete failure');
    expect(prisma.tx.order.deleteMany).not.toHaveBeenCalled();
    expect(prisma.tx.auditLog.create).not.toHaveBeenCalled();
    expect(redisService.set).not.toHaveBeenCalled();
  });

  it('throws NotFoundException when deleteOrder cannot find the tenant order', async () => {
    prisma.tx.order.findFirst.mockResolvedValueOnce(null);

    const promise = service.deleteOrder(ORDER_ID, ORG_ID);
    await expect(promise).rejects.toBeInstanceOf(NotFoundException);
    await expect(promise).rejects.toThrow(`Order ${ORDER_ID} not found`);
    expect(prisma.tx.orderLineItem.deleteMany).not.toHaveBeenCalled();
    expect(prisma.tx.order.deleteMany).not.toHaveBeenCalled();
    expect(prisma.tx.auditLog.create).not.toHaveBeenCalled();
    expect(redisService.set).not.toHaveBeenCalled();
  });

  it('updates status through a valid transition and sends shipment email when the order actually changes to shipped', async () => {
    prisma.tx.order.findFirst.mockResolvedValueOnce({
      ...BASE_ORDER,
      status: 'processing',
    });
    prisma.tx.order.updateMany.mockResolvedValueOnce({ count: 1 });
    prisma.tx.auditLog.create.mockResolvedValueOnce({});

    const result = await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

    expect(result.status).toBe('shipped');
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.order.findFirst).not.toHaveBeenCalled();
    expect(prisma.order.updateMany).not.toHaveBeenCalled();
    expect(prisma.tx.order.updateMany).toHaveBeenCalledWith({
      where: {
        id: ORDER_ID,
        organizationId: ORG_ID,
        status: 'processing',
      },
      data: { status: 'shipped' },
    });
    expect(emailService.sendOrderShipped).toHaveBeenCalledWith({
      orderId: ORDER_ID,
      customerId: CUSTOMER_ID,
      orgId: ORG_ID,
    });
    expect(redisService.set).toHaveBeenCalledWith(`orders:${ORG_ID}:version`, expect.any(String));
  });

  it('swallows shipment email errors after a successful shipped transition', async () => {
    prisma.tx.order.findFirst.mockResolvedValueOnce({
      ...BASE_ORDER,
      status: 'processing',
    });
    prisma.tx.order.updateMany.mockResolvedValueOnce({ count: 1 });
    prisma.tx.auditLog.create.mockResolvedValueOnce({});
    emailService.sendOrderShipped.mockRejectedValueOnce(new Error('SMTP unavailable'));
    const warnSpy = jest.spyOn((service as any).logger, 'warn').mockImplementation(() => undefined);

    await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).resolves.toMatchObject({
      id: ORDER_ID,
      status: 'shipped',
    });

    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining('SMTP unavailable'));
    expect(redisService.set).toHaveBeenCalledWith(`orders:${ORG_ID}:version`, expect.any(String));
  });

  it('throws BadRequestException on invalid status transition', async () => {
    prisma.tx.order.findFirst.mockResolvedValueOnce({
      ...BASE_ORDER,
      status: 'pending',
    });

    const promise = service.updateStatus(ORDER_ID, 'delivered', ORG_ID);
    await expect(promise).rejects.toBeInstanceOf(BadRequestException);
    await expect(promise).rejects.toThrow(
      'Invalid transition from pending to delivered',
    );
    expect(prisma.tx.order.updateMany).not.toHaveBeenCalled();
  });

  it('throws NotFoundException when updateStatus cannot find the tenant order', async () => {
    prisma.tx.order.findFirst.mockResolvedValueOnce(null);

    const promise = service.updateStatus(ORDER_ID, 'shipped', ORG_ID);
    await expect(promise).rejects.toBeInstanceOf(NotFoundException);
    await expect(promise).rejects.toThrow(`Order ${ORDER_ID} not found`);
    expect(prisma.tx.order.updateMany).not.toHaveBeenCalled();
    expect(prisma.tx.auditLog.create).not.toHaveBeenCalled();
    expect(emailService.sendOrderShipped).not.toHaveBeenCalled();
    expect(redisService.set).not.toHaveBeenCalled();
  });

  it('throws ConflictException when updateStatus loses a race after validation', async () => {
    prisma.tx.order.findFirst.mockResolvedValueOnce({
      ...BASE_ORDER,
      status: 'processing',
    });
    prisma.tx.order.updateMany.mockResolvedValueOnce({ count: 0 });

    const promise = service.updateStatus(ORDER_ID, 'shipped', ORG_ID);
    await expect(promise).rejects.toBeInstanceOf(ConflictException);
    await expect(promise).rejects.toThrow('Order status changed by another request');
    expect(prisma.tx.auditLog.create).not.toHaveBeenCalled();
    expect(emailService.sendOrderShipped).not.toHaveBeenCalled();
    expect(redisService.set).not.toHaveBeenCalled();
  });

  it('aggregates monthly revenue by currency for the given month', async () => {
    prisma.order.findMany.mockResolvedValueOnce([
      { currency: 'USD', totalAmount: 1250.25 },
      { currency: 'EUR', totalAmount: 99.99 },
      { currency: 'USD', totalAmount: 10 },
    ]);

    const result = await service.calculateMonthlyRevenue(MONTH, ORG_ID);

    expect(result).toEqual([
      { currency: 'EUR', total: 99.99 },
      { currency: 'USD', total: 1260.25 },
    ]);
    expect(prisma.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_ID,
          status: { not: 'cancelled' },
          createdAt: {
            gte: new Date('2026-03-01T00:00:00.000Z'),
            lt: new Date('2026-04-01T00:00:00.000Z'),
          },
        }),
        select: { currency: true, totalAmount: true },
      }),
    );
  });

  it('updates only valid source states in bulkUpdateStatus and skips invalid transitions silently', async () => {
    const requestedIds = ['order-123-1', 'order-123-2', 'order-123-3'];
    prisma.tx.order.findMany.mockResolvedValueOnce([
      makeOrder(1, { id: requestedIds[0], status: 'pending' }),
      makeOrder(2, { id: requestedIds[1], status: 'delivered' }),
      makeOrder(3, { id: requestedIds[2], status: 'processing' }),
    ]);
    prisma.tx.order.updateMany.mockResolvedValueOnce({ count: 2 });
    prisma.tx.auditLog.create.mockResolvedValueOnce({});

    const result = await service.bulkUpdateStatus(requestedIds, 'cancelled', ORG_ID);

    expect(result).toBe(2);
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.order.findMany).not.toHaveBeenCalled();
    expect(prisma.order.updateMany).not.toHaveBeenCalled();
    expect(prisma.tx.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_ID,
          id: { in: requestedIds },
        }),
      }),
    );
    expect(prisma.tx.order.updateMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_ID,
          id: { in: ['order-123-1', 'order-123-3'] },
          status: { in: ['pending', 'processing'] },
        }),
        data: { status: 'cancelled' },
      }),
    );
    expect(prisma.tx.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ action: 'order.bulk_update_status', organizationId: ORG_ID }),
      }),
    );
  });

  it('returns 0 for bulkUpdateStatus when every fetched order is an invalid transition', async () => {
    prisma.tx.order.findMany.mockResolvedValueOnce([
      makeOrder(1, { id: 'order-123-1', status: 'delivered' }),
      makeOrder(2, { id: 'order-123-2', status: 'cancelled' }),
    ]);

    const result = await service.bulkUpdateStatus(['order-123-1', 'order-123-2'], 'cancelled', ORG_ID);

    expect(result).toBe(0);
    expect(prisma.tx.order.updateMany).not.toHaveBeenCalled();
    expect(prisma.tx.auditLog.create).not.toHaveBeenCalled();
    expect(redisService.set).not.toHaveBeenCalled();
  });

  it('returns export payload at the maxRows boundary and includes relational data', async () => {
    const exportOrders = makeOrders(10_000).map((order, index) =>
      index === 0
        ? {
            ...order,
            lineItems: [
              { id: 'li-1', productId: 'prod-1', quantity: 2, unitPrice: 10, createdAt: new Date('2026-03-01T00:00:00.000Z') },
            ],
            customer: { id: 'cust-1', name: 'Ada', email: 'ada@example.com' },
            payments: [
              { id: 'pay-1', amount: 20, currency: 'USD', createdAt: new Date('2026-03-01T00:00:00.000Z') },
            ],
          }
        : order,
    );
    prisma.order.findMany.mockResolvedValueOnce(exportOrders);

    const result = await service.getOrdersForExport({}, ORG_ID);

    expect(result).toHaveLength(10_000);
    expect(result[0].lineItems).toEqual(exportOrders[0].lineItems);
    expect(result[0].customer).toEqual(exportOrders[0].customer);
    expect(result[0].payments).toEqual(exportOrders[0].payments);
    expect(prisma.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_ID,
        }),
        include: {
          lineItems: true,
          customer: true,
          payments: true,
        },
        take: 10_001,
      }),
    );
  });

  it('throws BadRequestException when export rows exceed maxRows', async () => {
    prisma.order.findMany.mockResolvedValueOnce(makeOrders(10_001));

    const promise = service.getOrdersForExport({}, ORG_ID);
    await expect(promise).rejects.toBeInstanceOf(BadRequestException);
    await expect(promise).rejects.toThrow('Export row limit exceeded (10000)');
    expect(prisma.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_ID,
        }),
      }),
    );
  });
});
