import {
  BadRequestException,
  ConflictException,
  NotFoundException,
} from '@nestjs/common';
import { OrderService } from './r2-OrderService';

const ORG_ID = 'org-123';
const ORDER_ID = 'order-123';
const CUSTOMER_ID = 'customer-123';
const CREATED_AT = new Date('2026-01-10T00:00:00.000Z');

function makeOrder(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    id: ORDER_ID,
    organizationId: ORG_ID,
    customerId: CUSTOMER_ID,
    status: 'pending',
    currency: 'USD',
    createdAt: CREATED_AT,
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
    ...tx,
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

describe('OrderService', () => {
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

  it('returns cached rows on findAll cache hit', async () => {
    const CACHED = [makeOrder()];
    deps.redis.get
      .mockResolvedValueOnce('1')
      .mockResolvedValueOnce(JSON.stringify(CACHED));

    const result = await service.findAll({ take: 10, skip: 0 }, ORG_ID);

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe(ORDER_ID);
    expect(deps.prisma.order.findMany).not.toHaveBeenCalled();
  });

  it('queries db and caches on findAll cache miss', async () => {
    const DB_ROWS = [makeOrder()];
    deps.redis.get
      .mockResolvedValueOnce('1')
      .mockResolvedValueOnce(null);
    deps.prisma.order.findMany.mockResolvedValue(DB_ROWS);

    const result = await service.findAll({ status: 'pending', take: 5 }, ORG_ID);

    expect(result).toEqual(DB_ROWS);
    expect(deps.prisma.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_ID,
          status: 'pending',
        }),
        take: 5,
      }),
    );
    expect(deps.redis.set).toHaveBeenCalledWith(
      expect.stringContaining(`orders:${ORG_ID}:v1:list:`),
      expect.any(String),
      120,
    );
  });

  it('findById throws NotFoundException when order not found in org', async () => {
    deps.redis.get.mockResolvedValueOnce('1').mockResolvedValueOnce(null);
    deps.prisma.order.findFirst.mockResolvedValue(null);

    await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(NotFoundException);
    await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(
      `Order ${ORDER_ID} not found`,
    );
  });

  it('creates order and line items in transaction and writes audit log', async () => {
    const CREATED = makeOrder();
    deps.tx.order.create.mockResolvedValue(CREATED);
    deps.tx.orderLineItem.createMany.mockResolvedValue({ count: 1 });
    deps.paymentGateway.authorize.mockResolvedValue({ authId: 'a1' });

    const dto = {
      customerId: CUSTOMER_ID,
      currency: 'USD',
      lineItems: [{ productId: 'p1', quantity: 2, unitPrice: 10 }],
    };

    const result = await service.create(dto, ORG_ID);

    expect(result).toEqual(CREATED);
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
            productId: 'p1',
            quantity: 2,
            unitPrice: 10,
            organizationId: ORG_ID,
          }),
        ],
      }),
    );
    expect(deps.tx.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          action: 'order.created',
          organizationId: ORG_ID,
          orderId: ORDER_ID,
        }),
      }),
    );
  });

  it('deleteOrder throws NotFoundException before deleting line items when parent missing', async () => {
    deps.tx.order.findFirst.mockResolvedValue(null);

    await expect(service.deleteOrder(ORDER_ID, ORG_ID)).rejects.toThrow(NotFoundException);
    await expect(service.deleteOrder(ORDER_ID, ORG_ID)).rejects.toThrow(
      `Order ${ORDER_ID} not found`,
    );
    expect(deps.tx.orderLineItem.deleteMany).not.toHaveBeenCalled();
  });

  it('deleteOrder deletes order and children atomically and invalidates cache', async () => {
    deps.tx.order.findFirst.mockResolvedValue({ id: ORDER_ID });
    deps.tx.order.deleteMany.mockResolvedValue({ count: 1 });
    deps.tx.orderLineItem.deleteMany.mockResolvedValue({ count: 2 });

    const result = await service.deleteOrder(ORDER_ID, ORG_ID);

    expect(result).toEqual({ deleted: true });
    expect(deps.tx.order.deleteMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: { id: ORDER_ID, organizationId: ORG_ID } }),
    );
    expect(deps.redis.incr).toHaveBeenCalledWith(`orders:version:${ORG_ID}`);
  });

  it('updateStatus enforces state machine and throws ConflictException on invalid transition', async () => {
    deps.prisma.order.findFirst.mockResolvedValue({ status: 'pending' });

    await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).rejects.toThrow(
      ConflictException,
    );
    await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).rejects.toThrow(
      'Invalid transition: pending -> shipped',
    );
  });

  it('updateStatus sends shipped email and swallows email failure', async () => {
    deps.prisma.order.findFirst.mockResolvedValueOnce({ status: 'processing' });
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

  it('calculateMonthlyRevenue returns totals by currency and excludes cancelled statuses', async () => {
    deps.tx.orderLineItem.findMany
      .mockResolvedValueOnce([
        { quantity: 2, unitPrice: 10.1, order: { currency: 'USD' } },
        { quantity: 1, unitPrice: 5, order: { currency: 'EUR' } },
      ])
      .mockResolvedValueOnce([]);

    const result = await service.calculateMonthlyRevenue(new Date('2026-01-01T00:00:00.000Z'), ORG_ID);

    expect(result).toEqual(
      expect.arrayContaining([
        { currency: 'USD', total: 20.2 },
        { currency: 'EUR', total: 5 },
      ]),
    );
    expect(deps.tx.orderLineItem.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          organizationId: ORG_ID,
          order: expect.objectContaining({ status: { in: ['shipped', 'delivered'] } }),
        }),
      }),
    );
  });

  it('bulkUpdateStatus updates only valid transitions and returns updated count', async () => {
    deps.tx.order.findMany.mockResolvedValue([
      { id: 'a', status: 'pending' },
      { id: 'b', status: 'delivered' },
    ]);
    deps.tx.order.updateMany
      .mockResolvedValueOnce({ count: 1 });

    const result = await service.bulkUpdateStatus(['a', 'b'], 'confirmed', ORG_ID);

    expect(result).toEqual({ updatedCount: 1 });
    expect(deps.tx.order.updateMany).toHaveBeenCalledTimes(1);
    expect(deps.tx.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          action: 'order.bulk_status_updated',
          updatedCount: 1,
        }),
      }),
    );
  });

  it('bulkUpdateStatus rejects oversized id arrays at boundary', async () => {
    const ids = Array.from({ length: 501 }, (_, idx) => `o-${idx}`);

    await expect(service.bulkUpdateStatus(ids, 'confirmed', ORG_ID)).rejects.toThrow(
      BadRequestException,
    );
    await expect(service.bulkUpdateStatus(ids, 'confirmed', ORG_ID)).rejects.toThrow(
      'ids length must be <= 500',
    );
  });

  it('getOrdersForExport fetches related entities with maxRows bound', async () => {
    deps.prisma.order.findMany.mockResolvedValue([makeOrder()]);

    const result = await service.getOrdersForExport(
      {
        status: 'pending',
        dateRange: {
          from: new Date('2026-01-01T00:00:00.000Z'),
          to: new Date('2026-01-31T23:59:59.999Z'),
        },
      },
      ORG_ID,
    );

    expect(result).toHaveLength(1);
    expect(deps.prisma.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        include: {
          lineItems: true,
          customer: true,
          payments: true,
        },
        take: 10000,
      }),
    );
  });

  it('propagates audit log failures from transaction rollback path', async () => {
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

  it('invalidates malformed cache entries and falls back to db', async () => {
    deps.redis.get
      .mockResolvedValueOnce('1')
      .mockResolvedValueOnce('{bad-json}')
      .mockResolvedValueOnce('1');
    deps.prisma.order.findMany.mockResolvedValue([makeOrder()]);

    const result = await service.findAll({}, ORG_ID);

    expect(result).toHaveLength(1);
    expect(deps.redis.del).toHaveBeenCalledWith(expect.stringContaining(':list:'));
  });
});
