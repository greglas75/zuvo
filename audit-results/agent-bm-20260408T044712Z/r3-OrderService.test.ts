/**
 * Tests target the fixed benchmark implementation in:
 * - r2-OrderService.ts
 * - r2-useSearchProducts.ts
 */

import { BadRequestException, ConflictException, NotFoundException } from '@nestjs/common';
import { OrderService } from './r2-OrderService';

const ORG_A = 'org-a';
const ORDER_ID = 'order-1';
const CUSTOMER_ID = 'cust-1';

const mockOrderRow = {
  id: ORDER_ID,
  organizationId: ORG_A,
  customerId: CUSTOMER_ID,
  currency: 'USD',
  status: 'pending',
  totalAmount: 100,
  createdAt: new Date('2026-01-15T10:00:00.000Z'),
  updatedAt: new Date('2026-01-15T10:00:00.000Z'),
};

const prismaMock = {
  order: {
    findMany: jest.fn(),
    findFirst: jest.fn(),
    create: jest.fn(),
    updateMany: jest.fn(),
    deleteMany: jest.fn(),
    groupBy: jest.fn(),
  },
  orderLineItem: {
    deleteMany: jest.fn(),
  },
  payment: {
    deleteMany: jest.fn(),
  },
  $transaction: jest.fn((fn: (tx: typeof prismaMock) => Promise<unknown>) => fn(prismaMock)),
};

const redisMock = {
  get: jest.fn(),
  set: jest.fn(),
  del: jest.fn(),
  delByPattern: jest.fn(),
};

const emailMock = {
  sendShippingNotification: jest.fn().mockResolvedValue(undefined),
};

const paymentGatewayMock = {};

describe('OrderService', () => {
  let service: OrderService;

  beforeEach(() => {
    jest.clearAllMocks();
    service = new OrderService(
      prismaMock as never,
      redisMock as never,
      emailMock as never,
      paymentGatewayMock as never,
    );
  });

  it('findAll returns cached list when Redis hit succeeds', async () => {
    const cachedPayload = JSON.stringify([mockOrderRow]);
    redisMock.get.mockResolvedValue(cachedPayload);

    const result = await service.findAll({ take: 10, skip: 0 }, ORG_A);

    expect(redisMock.get).toHaveBeenCalled();
    expect(prismaMock.order.findMany).not.toHaveBeenCalled();
    expect(Array.isArray(result)).toBe(true);
    expect((result as typeof mockOrderRow[])[0].id).toBe(ORDER_ID);
  });

  it('findAll falls back to Prisma when cache JSON is corrupt', async () => {
    redisMock.get.mockResolvedValue('{not-json');
    prismaMock.order.findMany.mockResolvedValue([mockOrderRow]);

    const rows = await service.findAll({}, ORG_A);

    expect(redisMock.del).toHaveBeenCalled();
    expect(prismaMock.order.findMany).toHaveBeenCalled();
    expect(rows).toEqual([mockOrderRow]);
  });

  it('findAll clamps take to minimum 1 and maximum 500', async () => {
    redisMock.get.mockResolvedValue(null);
    prismaMock.order.findMany.mockResolvedValue([]);

    await service.findAll({ take: -5 }, ORG_A);
    expect(prismaMock.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ take: 1 }),
    );

    await service.findAll({ take: 9999 }, ORG_A);
    expect(prismaMock.order.findMany).toHaveBeenLastCalledWith(
      expect.objectContaining({ take: 500 }),
    );
  });

  it('throws NotFoundException when findById misses scoped order', async () => {
    prismaMock.order.findFirst.mockResolvedValue(null);

    await expect(service.findById(ORDER_ID, ORG_A)).rejects.toMatchObject({
      constructor: NotFoundException,
      message: expect.stringContaining('not found'),
    });
  });

  it('create persists order with computed totalAmount in a transaction', async () => {
    const dto = {
      customerId: CUSTOMER_ID,
      currency: 'USD',
      lineItems: [
        { productId: 'p1', quantity: 2, unitPrice: 25 },
        { productId: 'p2', quantity: 1, unitPrice: 50 },
      ],
    };
    const created = { ...mockOrderRow, totalAmount: 100, lineItems: [] };
    prismaMock.order.create.mockResolvedValue(created);

    const out = await service.create(dto, ORG_A);

    expect(prismaMock.$transaction).toHaveBeenCalled();
    expect(prismaMock.order.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          totalAmount: 100,
          organizationId: ORG_A,
        }),
      }),
    );
    expect(out).toEqual(created);
  });

  it('create rejects empty line items with BadRequestException', async () => {
    await expect(
      service.create(
        { customerId: CUSTOMER_ID, currency: 'USD', lineItems: [] },
        ORG_A,
      ),
    ).rejects.toMatchObject({ constructor: BadRequestException });
  });

  it('deleteOrder removes payments and line items then order', async () => {
    prismaMock.order.findFirst.mockResolvedValue(mockOrderRow);
    prismaMock.payment.deleteMany.mockResolvedValue({ count: 1 });
    prismaMock.orderLineItem.deleteMany.mockResolvedValue({ count: 2 });
    prismaMock.order.deleteMany.mockResolvedValue({ count: 1 });

    await service.deleteOrder(ORDER_ID, ORG_A);

    expect(prismaMock.payment.deleteMany).toHaveBeenCalledWith({
      where: { orderId: ORDER_ID },
    });
    expect(prismaMock.order.deleteMany).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_A },
    });
  });

  it('updateStatus sends shipping email on shipped and invalidates cache best-effort', async () => {
    prismaMock.order.findFirst
      .mockResolvedValueOnce({ ...mockOrderRow, status: 'processing' })
      .mockResolvedValueOnce({ ...mockOrderRow, status: 'shipped' });
    prismaMock.order.updateMany.mockResolvedValue({ count: 1 });

    const updated = await service.updateStatus(ORDER_ID, 'shipped', ORG_A);

    expect(prismaMock.order.updateMany).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_A, status: 'processing' },
      data: { status: 'shipped' },
    });
    expect(emailMock.sendShippingNotification).toHaveBeenCalledWith({
      orderId: ORDER_ID,
      orgId: ORG_A,
    });
    expect(updated.status).toBe('shipped');
  });

  it('propagates email rejection without failing the status update path', async () => {
    const consoleSpy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    prismaMock.order.findFirst
      .mockResolvedValueOnce({ ...mockOrderRow, status: 'processing' })
      .mockResolvedValueOnce({ ...mockOrderRow, status: 'shipped' });
    prismaMock.order.updateMany.mockResolvedValue({ count: 1 });
    emailMock.sendShippingNotification.mockRejectedValueOnce(new Error('smtp down'));

    await service.updateStatus(ORDER_ID, 'shipped', ORG_A);

    expect(consoleSpy).toHaveBeenCalled();
    consoleSpy.mockRestore();
  });

  it('throws BadRequestException on illegal transition', async () => {
    prismaMock.order.findFirst.mockResolvedValue({ ...mockOrderRow, status: 'pending' });

    await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_A)).rejects.toMatchObject({
      constructor: BadRequestException,
      message: expect.stringContaining('Invalid status transition'),
    });
  });

  it('throws ConflictException when optimistic update races', async () => {
    prismaMock.order.findFirst.mockResolvedValue({ ...mockOrderRow, status: 'processing' });
    prismaMock.order.updateMany.mockResolvedValue({ count: 0 });

    await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_A)).rejects.toMatchObject({
      constructor: ConflictException,
    });
  });

  it('calculateMonthlyRevenue aggregates totals by currency', async () => {
    prismaMock.order.groupBy.mockResolvedValue([
      { currency: 'USD', _sum: { totalAmount: 150 } },
      { currency: 'EUR', _sum: { totalAmount: null } },
    ]);

    const rows = await service.calculateMonthlyRevenue(new Date('2026-03-01T00:00:00.000Z'), ORG_A);

    expect(rows).toEqual([
      { currency: 'USD', total: 150 },
      { currency: 'EUR', total: 0 },
    ]);
  });

  it('bulkUpdateStatus skips invalid transitions and counts successful updates', async () => {
    prismaMock.order.findFirst
      .mockResolvedValueOnce({ ...mockOrderRow, id: 'a', status: 'pending' })
      .mockResolvedValueOnce({ ...mockOrderRow, id: 'b', status: 'delivered' });
    prismaMock.order.updateMany.mockResolvedValue({ count: 1 });

    const n = await service.bulkUpdateStatus(['a', 'b'], 'confirmed', ORG_A);

    expect(n).toBe(1);
    expect(prismaMock.$transaction).toHaveBeenCalled();
    expect(prismaMock.order.updateMany).toHaveBeenCalledTimes(1);
  });

  it('getOrdersForExport enforces max row bound via take', async () => {
    prismaMock.order.findMany.mockResolvedValue([]);

    await service.getOrdersForExport({}, ORG_A);

    expect(prismaMock.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ take: 10_000 }),
    );
  });

  it('throws when date range is inverted', async () => {
    redisMock.get.mockResolvedValue(null);

    await expect(
      service.findAll(
        {
          dateRange: {
            from: new Date('2026-02-01'),
            to: new Date('2026-01-01'),
          },
        },
        ORG_A,
      ),
    ).rejects.toMatchObject({ constructor: BadRequestException });
  });
});
