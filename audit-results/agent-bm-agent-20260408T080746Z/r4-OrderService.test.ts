import {
  BadRequestException,
  ConflictException,
  NotFoundException,
} from '@nestjs/common';
import { OrderService } from './r2-OrderService';

const ORG_ID = 'org-123';
const ORDER_ID = 'order-123';
const CUSTOMER_ID = 'customer-123';

function makeOrder(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id: ORDER_ID,
    organizationId: ORG_ID,
    customerId: CUSTOMER_ID,
    status: 'pending',
    currency: 'USD',
    createdAt: new Date('2026-01-10T00:00:00.000Z'),
    ...overrides,
  };
}

function createMockDeps() {
  const tx = {
    order: {
      findMany: jest.fn(),
      findFirst: jest.fn(),
      create: jest.fn(),
      deleteMany: jest.fn(),
      updateMany: jest.fn(),
    },
    orderLineItem: {
      findMany: jest.fn(),
      createMany: jest.fn(),
      deleteMany: jest.fn(),
    },
    auditLog: {
      create: jest.fn(),
    },
  };

  const prisma = {
    order: {
      findMany: jest.fn(),
      findFirst: jest.fn(),
      create: jest.fn(),
      deleteMany: jest.fn(),
      updateMany: jest.fn(),
    },
    orderLineItem: {
      findMany: jest.fn(),
      createMany: jest.fn(),
      deleteMany: jest.fn(),
    },
    auditLog: {
      create: jest.fn(),
    },
    $transaction: jest.fn(async (fn: (arg: any) => Promise<unknown>) => fn(tx)),
  };

  const redis = {
    get: jest.fn(),
    set: jest.fn(),
    del: jest.fn(),
    incr: jest.fn(),
  };

  const emailService = {
    sendOrderShipped: jest.fn(),
  };

  const paymentGateway = {
    authorize: jest.fn(),
  };

  return { prisma, redis, emailService, paymentGateway, tx };
}

describe('OrderService (R4)', () => {
  let deps: ReturnType<typeof createMockDeps>;
  let service: OrderService;

  beforeEach(() => {
    jest.clearAllMocks();
    deps = createMockDeps();
    service = new OrderService(
      deps.prisma as any,
      deps.redis as any,
      deps.emailService as any,
      deps.paymentGateway as any,
    );

    deps.redis.get.mockResolvedValue('1');
    deps.redis.set.mockResolvedValue('OK');
    deps.redis.del.mockResolvedValue(1);
    deps.redis.incr.mockResolvedValue(2);
    deps.tx.auditLog.create.mockResolvedValue({ id: 'audit-1' });
  });

  it('findAll returns cached rows on cache hit', async () => {
    deps.redis.get
      .mockResolvedValueOnce('1')
      .mockResolvedValueOnce(JSON.stringify([makeOrder()]));

    const result = await service.findAll({ take: 10, skip: 0 }, ORG_ID);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe(ORDER_ID);
    expect(deps.prisma.order.findMany).not.toHaveBeenCalled();
  });

  it('findAll falls back when cache is malformed and invalidates key', async () => {
    deps.redis.get
      .mockResolvedValueOnce('1')
      .mockResolvedValueOnce('{bad-json}');
    deps.prisma.order.findMany.mockResolvedValue([makeOrder()]);

    const result = await service.findAll({}, ORG_ID);

    expect(result).toHaveLength(1);
    expect(deps.redis.del).toHaveBeenCalledWith(expect.stringContaining(':list:'));
  });

  it('findById throws NotFoundException with expected message', async () => {
    deps.redis.get.mockResolvedValueOnce('1').mockResolvedValueOnce(null);
    deps.prisma.order.findFirst.mockResolvedValue(null);

    const promise = service.findById(ORDER_ID, ORG_ID);
    await expect(promise).rejects.toThrow(NotFoundException);
    await expect(promise).rejects.toThrow(`Order ${ORDER_ID} not found`);
  });

  it('create writes order and line items in transaction, then audit log', async () => {
    deps.paymentGateway.authorize.mockResolvedValue({ authId: 'a1' });
    deps.tx.order.create.mockResolvedValue(makeOrder());
    deps.tx.orderLineItem.createMany.mockResolvedValue({ count: 1 });

    const dto = {
      customerId: CUSTOMER_ID,
      currency: 'USD',
      lineItems: [{ productId: 'p1', quantity: 2, unitPrice: 10 }],
    };

    const result = await service.create(dto, ORG_ID);

    expect(result.id).toBe(ORDER_ID);
    expect(deps.paymentGateway.authorize).toHaveBeenCalledWith({
      organizationId: ORG_ID,
      customerId: CUSTOMER_ID,
      currency: 'USD',
      amount: 2000,
    });
    expect(deps.tx.orderLineItem.createMany).toHaveBeenCalledWith(
      expect.objectContaining({
        data: [
          expect.objectContaining({
            orderId: ORDER_ID,
            organizationId: ORG_ID,
            productId: 'p1',
            quantity: 2,
            unitPrice: 10,
          }),
        ],
      }),
    );
    expect(deps.tx.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          action: 'order.created',
          orderId: ORDER_ID,
          organizationId: ORG_ID,
        }),
      }),
    );
  });

  it('create propagates payment authorization failure and avoids db writes', async () => {
    deps.paymentGateway.authorize.mockRejectedValue(new Error('declined'));

    const dto = {
      customerId: CUSTOMER_ID,
      currency: 'USD',
      lineItems: [{ productId: 'p1', quantity: 1, unitPrice: 10 }],
    };

    await expect(service.create(dto, ORG_ID)).rejects.toThrow('declined');
    expect(deps.prisma.$transaction).not.toHaveBeenCalled();
  });

  it('deleteOrder checks parent existence before deleting children', async () => {
    deps.tx.order.findFirst.mockResolvedValue(null);

    const promise = service.deleteOrder(ORDER_ID, ORG_ID);
    await expect(promise).rejects.toThrow(NotFoundException);
    await expect(promise).rejects.toThrow(`Order ${ORDER_ID} not found`);
    expect(deps.tx.orderLineItem.deleteMany).not.toHaveBeenCalled();
  });

  it('updateStatus enforces invalid transition guard', async () => {
    deps.prisma.order.findFirst.mockResolvedValue({ status: 'pending' });

    const promise = service.updateStatus(ORDER_ID, 'shipped', ORG_ID);
    await expect(promise).rejects.toThrow(ConflictException);
    await expect(promise).rejects.toThrow('Invalid transition: pending -> shipped');
  });

  it('updateStatus sends shipped email and handles email provider error', async () => {
    deps.prisma.order.findFirst.mockResolvedValue({ status: 'processing' });
    deps.tx.order.updateMany.mockResolvedValue({ count: 1 });
    deps.tx.order.findFirst.mockResolvedValue(makeOrder({ status: 'shipped' }));
    deps.emailService.sendOrderShipped.mockRejectedValue(new Error('smtp down'));

    const result = await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

    expect(result.status).toBe('shipped');
    expect(deps.emailService.sendOrderShipped).toHaveBeenCalledWith({
      orderId: ORDER_ID,
      customerId: CUSTOMER_ID,
      organizationId: ORG_ID,
    });
  });

  it('calculateMonthlyRevenue aggregates by currency with precision-safe matcher', async () => {
    deps.tx.orderLineItem.findMany
      .mockResolvedValueOnce([
        { quantity: 3, unitPrice: 10.1, order: { currency: 'USD' } },
        { quantity: 1, unitPrice: 5, order: { currency: 'EUR' } },
      ])
      .mockResolvedValueOnce([]);

    const result = await service.calculateMonthlyRevenue(
      new Date('2026-01-01T00:00:00.000Z'),
      ORG_ID,
    );

    const usd = result.find((x) => x.currency === 'USD');
    const eur = result.find((x) => x.currency === 'EUR');

    expect(usd).toBeDefined();
    expect(eur).toBeDefined();
    expect(usd!.total).toBeCloseTo(30.3, 2);
    expect(eur!.total).toBeCloseTo(5, 2);
    expect(deps.tx.orderLineItem.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_ID,
          order: expect.objectContaining({
            status: { in: ['shipped', 'delivered'] },
          }),
        }),
      }),
    );
  });

  it('bulkUpdateStatus updates only eligible rows and audits result', async () => {
    deps.tx.order.findMany.mockResolvedValue([
      { id: 'a', status: 'pending' },
      { id: 'b', status: 'delivered' },
    ]);
    deps.tx.order.updateMany.mockResolvedValueOnce({ count: 1 });

    const result = await service.bulkUpdateStatus(['a', 'b'], 'confirmed', ORG_ID);

    expect(result).toEqual({ updatedCount: 1 });
    expect(deps.tx.order.updateMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          id: 'a',
          organizationId: ORG_ID,
          status: 'pending',
        }),
      }),
    );
    expect(deps.tx.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          action: 'order.bulk_status_updated',
          requestedCount: 2,
          updatedCount: 1,
        }),
      }),
    );
  });

  it('bulkUpdateStatus rejects oversized id arrays with explicit message', async () => {
    const ids = Array.from({ length: 501 }, (_, idx) => `o-${idx}`);

    const promise = service.bulkUpdateStatus(ids, 'confirmed', ORG_ID);
    await expect(promise).rejects.toThrow(BadRequestException);
    await expect(promise).rejects.toThrow('ids length must be <= 500');
  });

  it('getOrdersForExport applies org, status, date filters and maxRows boundary', async () => {
    deps.prisma.order.findMany.mockResolvedValue([makeOrder()]);

    const from = new Date('2026-01-01T00:00:00.000Z');
    const to = new Date('2026-01-31T23:59:59.999Z');

    const result = await service.getOrdersForExport(
      { status: 'pending', dateRange: { from, to } },
      ORG_ID,
    );

    expect(result).toHaveLength(1);
    expect(deps.prisma.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_ID,
          status: 'pending',
          createdAt: {
            gte: from,
            lte: to,
          },
        }),
        include: {
          lineItems: true,
          customer: true,
          payments: true,
        },
        take: 10000,
      }),
    );
  });

  it('create fails when audit log write fails in transaction', async () => {
    deps.paymentGateway.authorize.mockResolvedValue({ authId: 'a1' });
    deps.tx.order.create.mockResolvedValue(makeOrder());
    deps.tx.orderLineItem.createMany.mockResolvedValue({ count: 1 });
    deps.tx.auditLog.create.mockRejectedValue(new Error('audit db down'));

    const dto = {
      customerId: CUSTOMER_ID,
      currency: 'USD',
      lineItems: [{ productId: 'p1', quantity: 1, unitPrice: 10 }],
    };

    await expect(service.create(dto, ORG_ID)).rejects.toThrow(
      'Failed to write audit log',
    );
  });
});
