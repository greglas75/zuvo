// Tests for benchmark corpus — code under test: r2-OrderService.ts
import { BadRequestException, ConflictException, NotFoundException } from '@nestjs/common';
import { OrderService } from './r2-OrderService';

const ORG_A = 'org-a';
const ORG_B = 'org-b';
const ORDER_ID = 'order-1';

function makeOrder(over: Record<string, unknown> = {}) {
  return {
    id: ORDER_ID,
    organizationId: ORG_A,
    customerId: 'cust-1',
    currency: 'USD',
    status: 'pending',
    totalAmount: 100,
    createdAt: new Date('2026-01-15T12:00:00.000Z'),
    ...over,
  };
}

describe('OrderService', () => {
  const prisma = {
    order: {
      findMany: jest.fn(),
      findFirst: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
      deleteMany: jest.fn(),
      groupBy: jest.fn(),
    },
    lineItem: {
      deleteMany: jest.fn(),
    },
    auditLog: {
      create: jest.fn().mockResolvedValue({ id: 'audit-1' }),
    },
    $transaction: jest.fn((fn: (tx: typeof prisma) => Promise<unknown>) => fn(prisma)),
  };

  const redis = {
    get: jest.fn(),
    set: jest.fn(),
    del: jest.fn(),
    delByPattern: jest.fn(),
  };

  const email = {
    sendOrderShipped: jest.fn().mockResolvedValue(undefined),
  };

  const paymentGateway = {
    ensureReady: jest.fn().mockResolvedValue(undefined),
  };

  let service: OrderService;

  beforeEach(() => {
    jest.clearAllMocks();
    prisma.$transaction.mockImplementation((fn: (tx: typeof prisma) => Promise<unknown>) =>
      fn(prisma),
    );
    service = new OrderService(
      prisma as never,
      redis as never,
      email as never,
      paymentGateway as never,
    );
  });

  it('findAll returns cached rows on cache hit', async () => {
    const cached = JSON.stringify([makeOrder()]);
    redis.get.mockResolvedValue(cached);

    const rows = await service.findAll({ take: 10, skip: 0 }, ORG_A);

    expect(redis.get).toHaveBeenCalled();
    expect(prisma.order.findMany).not.toHaveBeenCalled();
    expect(rows).toHaveLength(1);
  });

  it('findAll falls back to DB when cache JSON is corrupt', async () => {
    redis.get.mockResolvedValue('not-json{');
    prisma.order.findMany.mockResolvedValue([makeOrder()]);
    redis.del.mockResolvedValue(undefined);
    redis.set.mockResolvedValue(undefined);

    const rows = await service.findAll({}, ORG_A);

    expect(redis.del).toHaveBeenCalled();
    expect(prisma.order.findMany).toHaveBeenCalled();
    expect(rows).toHaveLength(1);
  });

  it('findAll applies org scope and pagination', async () => {
    redis.get.mockResolvedValue(null);
    prisma.order.findMany.mockResolvedValue([makeOrder()]);

    await service.findAll({ status: 'pending', take: 5, skip: 2 }, ORG_A);

    expect(prisma.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({ organizationId: ORG_A, status: 'pending' }),
        take: 5,
        skip: 2,
      }),
    );
  });

  it('throws BadRequestException when take is not finite', async () => {
    await expect(service.findAll({ take: Number.NaN }, ORG_A)).rejects.toBeInstanceOf(BadRequestException);
    await expect(service.findAll({ take: Number.NaN }, ORG_A)).rejects.toMatchObject({
      message: 'take and skip must be finite numbers',
    });
  });

  it('findById throws NotFoundException when order missing in org', async () => {
    prisma.order.findFirst.mockResolvedValue(null);

    await expect(service.findById(ORDER_ID, ORG_A)).rejects.toBeInstanceOf(NotFoundException);
    await expect(service.findById(ORDER_ID, ORG_A)).rejects.toMatchObject({
      message: `Order ${ORDER_ID} not found`,
    });
  });

  it('findById returns order when scoped to org', async () => {
    prisma.order.findFirst.mockResolvedValue(makeOrder());

    const order = await service.findById(ORDER_ID, ORG_A);

    expect(order.id).toBe(ORDER_ID);
    expect(prisma.order.findFirst).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_A },
    });
  });

  it('create validates dto and runs transaction', async () => {
    prisma.order.create.mockResolvedValue(makeOrder({ lineItems: [] }));

    const dto = {
      customerId: 'c1',
      currency: 'USD',
      lineItems: [{ productId: 'p1', quantity: 2, unitPrice: 10 }],
    };

    await service.create(dto, ORG_A);
    await Promise.resolve();

    expect(paymentGateway.ensureReady).toHaveBeenCalled();
    expect(prisma.order.create).toHaveBeenCalled();
    expect(redis.delByPattern).toHaveBeenCalled();
    expect(prisma.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          action: 'order.created',
          organizationId: ORG_A,
        }),
      }),
    );
  });

  it('create throws BadRequestException for empty line items', async () => {
    await expect(
      service.create({ customerId: 'c', currency: 'USD', lineItems: [] }, ORG_A),
    ).rejects.toBeInstanceOf(BadRequestException);
  });

  it('deleteOrder throws NotFoundException when order missing', async () => {
    prisma.order.findFirst.mockResolvedValue(null);

    await expect(service.deleteOrder(ORDER_ID, ORG_A)).rejects.toBeInstanceOf(NotFoundException);
  });

  it('deleteOrder deletes line items and order scoped by org', async () => {
    prisma.order.findFirst.mockResolvedValue(makeOrder());
    prisma.lineItem.deleteMany.mockResolvedValue({ count: 1 });
    prisma.order.deleteMany.mockResolvedValue({ count: 1 });

    await service.deleteOrder(ORDER_ID, ORG_A);

    expect(prisma.lineItem.deleteMany).toHaveBeenCalledWith({
      where: { orderId: ORDER_ID, order: { organizationId: ORG_A } },
    });
    expect(prisma.order.deleteMany).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_A },
    });
  });

  it('updateStatus transitions pending to confirmed atomically', async () => {
    prisma.order.findFirst
      .mockResolvedValueOnce(makeOrder({ status: 'pending' }))
      .mockResolvedValueOnce(makeOrder({ status: 'confirmed' }));
    prisma.order.updateMany.mockResolvedValue({ count: 1 });

    const updated = await service.updateStatus(ORDER_ID, 'confirmed', ORG_A);

    expect(updated.status).toBe('confirmed');
    expect(prisma.order.updateMany).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_A, status: 'pending' },
      data: { status: 'confirmed' },
    });
  });

  it('throws BadRequestException on invalid transition', async () => {
    prisma.order.findFirst.mockResolvedValue(makeOrder({ status: 'delivered' }));

    await expect(service.updateStatus(ORDER_ID, 'confirmed', ORG_A)).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });

  it('throws ConflictException when optimistic update races', async () => {
    prisma.order.findFirst.mockResolvedValue(makeOrder({ status: 'pending' }));
    prisma.order.updateMany.mockResolvedValue({ count: 0 });

    await expect(service.updateStatus(ORDER_ID, 'confirmed', ORG_A)).rejects.toBeInstanceOf(
      ConflictException,
    );
  });

  it('sends shipped email with error handling and catches failures', async () => {
    prisma.order.findFirst
      .mockResolvedValueOnce(makeOrder({ status: 'processing' }))
      .mockResolvedValueOnce(makeOrder({ status: 'shipped' }));
    prisma.order.updateMany.mockResolvedValue({ count: 1 });
    email.sendOrderShipped.mockRejectedValueOnce(new Error('smtp down'));

    const logSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    await service.updateStatus(ORDER_ID, 'shipped', ORG_A);

    expect(email.sendOrderShipped).toHaveBeenCalledWith('cust-1', ORDER_ID);
    expect(logSpy).toHaveBeenCalled();
    logSpy.mockRestore();
  });

  it('calculateMonthlyRevenue aggregates with exclusive month end', async () => {
    prisma.order.groupBy.mockResolvedValue([{ currency: 'USD', _sum: { totalAmount: 50 } }]);

    const month = new Date(Date.UTC(2026, 2, 15));
    const rows = await service.calculateMonthlyRevenue(month, ORG_A);

    expect(prisma.order.groupBy).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_A,
          createdAt: {
            gte: new Date(Date.UTC(2026, 2, 1)),
            lt: new Date(Date.UTC(2026, 3, 1)),
          },
        }),
      }),
    );
    expect(rows[0].total).toBe(50);
  });

  it('bulkUpdateStatus skips invalid transitions silently', async () => {
    prisma.order.findFirst
      .mockResolvedValueOnce(makeOrder({ id: 'o1', status: 'delivered' }))
      .mockResolvedValueOnce(makeOrder({ id: 'o2', status: 'pending' }));
    prisma.order.updateMany.mockResolvedValueOnce({ count: 0 }).mockResolvedValueOnce({ count: 1 });

    const n = await service.bulkUpdateStatus(['o1', 'o2'], 'confirmed', ORG_A);

    expect(n).toBe(1);
  });

  it('bulkUpdateStatus invalidates cache in finally on error', async () => {
    prisma.$transaction.mockRejectedValueOnce(new Error('db fail'));

    await expect(service.bulkUpdateStatus(['o1'], 'confirmed', ORG_A)).rejects.toThrow('db fail');
    expect(redis.delByPattern).toHaveBeenCalled();
  });

  it('getOrdersForExport caps at 10000 rows', async () => {
    prisma.order.findMany.mockResolvedValue([]);

    await service.getOrdersForExport({}, ORG_A);

    expect(prisma.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        take: 10000,
        include: expect.objectContaining({
          lineItems: true,
          customer: true,
          payments: true,
        }),
      }),
    );
  });
});
