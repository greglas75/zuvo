import { BadRequestException, ConflictException, NotFoundException } from '@nestjs/common';

import { OrderService } from './r2-OrderService';

type OrderStatus =
  | 'pending'
  | 'confirmed'
  | 'processing'
  | 'shipped'
  | 'delivered'
  | 'cancelled';

type MockOrder = {
  id: string;
  organizationId: string;
  customerId: string;
  status: OrderStatus;
  currency: string;
  totalAmount: number;
  createdAt: Date;
};

const ORG_ID = 'org-123';
const ORDER_ID = 'order-123';
const CUSTOMER_ID = 'customer-123';
const CREATED_AT = new Date('2026-03-01T00:00:00.000Z');
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
    { productId: 'prod-1', quantity: 2, unitPrice: 10.25 },
    { productId: 'prod-2', quantity: 1, unitPrice: 100 },
  ],
};

function makeOrders(length: number): MockOrder[] {
  return Array.from({ length }, (_, index) => ({
    ...BASE_ORDER,
    id: `${ORDER_ID}-${index + 1}`,
  }));
}

describe('OrderService (round 4)', () => {
  let prisma: any;
  let tx: any;
  let redisService: any;
  let emailService: any;
  let paymentGateway: any;
  let service: OrderService;

  beforeEach(() => {
    jest.clearAllMocks();

    tx = {
      order: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        create: jest.fn(),
        delete: jest.fn(),
        updateMany: jest.fn(),
      },
      orderLineItem: {
        deleteMany: jest.fn(),
      },
      auditLog: {
        create: jest.fn(),
      },
    };

    prisma = {
      order: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        groupBy: jest.fn(),
      },
      orderLineItem: {
        deleteMany: jest.fn(),
      },
      auditLog: {
        create: jest.fn(),
      },
      $transaction: jest.fn(async (callback: (txClient: any) => Promise<unknown>) => callback(tx)),
    };

    redisService = {
      get: jest.fn(),
      setex: jest.fn(),
      deleteByPrefix: jest.fn(),
      scanDel: jest.fn(),
    };

    emailService = {
      sendOrderShipped: jest.fn().mockResolvedValue(undefined),
    };

    paymentGateway = {
      validateCurrency: jest.fn().mockReturnValue(true),
    };

    service = new OrderService(prisma, redisService, emailService, paymentGateway);
  });

  it('returns cached orders on cache hit and rehydrates createdAt as Date', async () => {
    redisService.get.mockResolvedValueOnce(
      JSON.stringify([{ ...BASE_ORDER, createdAt: BASE_ORDER.createdAt.toISOString() }]),
    );

    const result = await service.findAll({ take: 10, skip: 0 }, ORG_ID);

    expect(result).toHaveLength(1);
    expect(result[0].createdAt).toBeInstanceOf(Date);
    expect(prisma.order.findMany).not.toHaveBeenCalled();
  });

  it('queries DB and writes cache on cache miss for findAll with exact date filter', async () => {
    redisService.get.mockResolvedValueOnce(null);
    prisma.order.findMany.mockResolvedValueOnce([BASE_ORDER]);

    const rangeFrom = new Date('2026-03-01T00:00:00.000Z');
    const rangeTo = new Date('2026-03-31T23:59:59.000Z');
    const filters = {
      status: 'pending' as const,
      customerId: CUSTOMER_ID,
      dateRange: { from: rangeFrom, to: rangeTo },
      take: 25,
      skip: 5,
    };

    const result = await service.findAll(filters, ORG_ID);

    expect(result).toEqual([BASE_ORDER]);
    expect(prisma.order.findMany).toHaveBeenCalledWith({
      where: {
        organizationId: ORG_ID,
        status: 'pending',
        customerId: CUSTOMER_ID,
        createdAt: {
          gte: rangeFrom,
          lte: rangeTo,
        },
      },
      orderBy: { createdAt: 'desc' },
      take: 25,
      skip: 5,
    });
    expect(redisService.setex).toHaveBeenCalledWith(expect.stringContaining(`orders:${ORG_ID}:findAll:`), 120, expect.any(String));
  });

  it('throws NotFoundException with expected message when order is missing', async () => {
    prisma.order.findFirst.mockResolvedValueOnce(null);

    const request = service.findById(ORDER_ID, ORG_ID);

    await expect(request).rejects.toBeInstanceOf(NotFoundException);
    await expect(request).rejects.toThrow(`Order ${ORDER_ID} not found`);
  });

  it('returns order by id when it exists in org', async () => {
    prisma.order.findFirst.mockResolvedValueOnce(BASE_ORDER);

    const result = await service.findById(ORDER_ID, ORG_ID);

    expect(result).toEqual(BASE_ORDER);
    expect(prisma.order.findFirst).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_ID },
    });
  });

  it('creates order inside transaction with expected money math, line items, and audit', async () => {
    tx.order.create.mockResolvedValueOnce({ ...BASE_ORDER, status: 'pending', totalAmount: 120.5 });
    tx.auditLog.create.mockResolvedValueOnce({});

    const result = await service.create(VALID_CREATE_DTO, ORG_ID);

    expect(result.id).toBe(ORDER_ID);
    expect(paymentGateway.validateCurrency).toHaveBeenCalledWith('USD');
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(tx.order.create).toHaveBeenCalledWith({
      data: {
        organizationId: ORG_ID,
        customerId: CUSTOMER_ID,
        status: 'pending',
        currency: 'USD',
        totalAmount: 120.5,
        lineItems: {
          create: [
            { productId: 'prod-1', quantity: 2, unitPrice: 10.25 },
            { productId: 'prod-2', quantity: 1, unitPrice: 100 },
          ],
        },
      },
      include: { lineItems: true },
    });
    expect(tx.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          action: 'order.create',
          organizationId: ORG_ID,
        }),
      }),
    );
    expect(redisService.deleteByPrefix).toHaveBeenCalledWith(`orders:${ORG_ID}:`);
  });

  it('propagates inner transaction failure in create and does not invalidate cache', async () => {
    tx.order.create.mockRejectedValueOnce(new Error('inner create failure'));

    await expect(service.create(VALID_CREATE_DTO, ORG_ID)).rejects.toThrow('inner create failure');
    expect(redisService.deleteByPrefix).not.toHaveBeenCalled();
  });

  it('deletes order and line items atomically with tx client and invalidates cache', async () => {
    tx.order.findFirst.mockResolvedValueOnce(BASE_ORDER);
    tx.orderLineItem.deleteMany.mockResolvedValueOnce({ count: 2 });
    tx.order.delete.mockResolvedValueOnce(BASE_ORDER);
    tx.auditLog.create.mockResolvedValueOnce({});

    await service.deleteOrder(ORDER_ID, ORG_ID);

    expect(tx.order.findFirst).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_ID },
    });
    expect(tx.orderLineItem.deleteMany).toHaveBeenCalledWith({
      where: { orderId: ORDER_ID, organizationId: ORG_ID },
    });
    expect(tx.order.delete).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_ID },
    });
    expect(tx.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ action: 'order.delete' }),
      }),
    );
    expect(redisService.deleteByPrefix).toHaveBeenCalledWith(`orders:${ORG_ID}:`);
  });

  it('updates status through valid transition, sends shipment email, and invalidates cache', async () => {
    prisma.order.findFirst.mockResolvedValueOnce({ ...BASE_ORDER, status: 'processing' });
    tx.order.updateMany.mockResolvedValueOnce({ count: 1 });
    tx.order.findFirst.mockResolvedValueOnce({ ...BASE_ORDER, status: 'shipped' });
    tx.auditLog.create.mockResolvedValueOnce({});

    const result = await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

    expect(result.status).toBe('shipped');
    expect(tx.order.updateMany).toHaveBeenCalledWith({
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
    expect(redisService.deleteByPrefix).toHaveBeenCalledWith(`orders:${ORG_ID}:`);
  });

  it('does not throw when shipment email fails and still resolves with updated order', async () => {
    prisma.order.findFirst.mockResolvedValueOnce({ ...BASE_ORDER, status: 'processing' });
    tx.order.updateMany.mockResolvedValueOnce({ count: 1 });
    tx.order.findFirst.mockResolvedValueOnce({ ...BASE_ORDER, status: 'shipped' });
    tx.auditLog.create.mockResolvedValueOnce({});
    emailService.sendOrderShipped.mockRejectedValueOnce(new Error('SMTP unavailable'));

    await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).resolves.toEqual({
      ...BASE_ORDER,
      status: 'shipped',
    });
  });

  it('throws BadRequestException for invalid status transition from pending to delivered', async () => {
    prisma.order.findFirst.mockResolvedValueOnce({ ...BASE_ORDER, status: 'pending' });

    const request = service.updateStatus(ORDER_ID, 'delivered', ORG_ID);

    await expect(request).rejects.toBeInstanceOf(BadRequestException);
    await expect(request).rejects.toThrow('Invalid transition from pending to delivered');
  });

  it('throws ConflictException when atomic status update affects zero rows', async () => {
    prisma.order.findFirst.mockResolvedValueOnce({ ...BASE_ORDER, status: 'processing' });
    tx.order.updateMany.mockResolvedValueOnce({ count: 0 });

    const request = service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

    await expect(request).rejects.toBeInstanceOf(ConflictException);
    await expect(request).rejects.toThrow('Order status changed by another request');
  });

  it('aggregates monthly revenue with exact UTC boundaries and cancelled exclusion', async () => {
    prisma.order.groupBy.mockResolvedValueOnce([
      { currency: 'USD', _sum: { totalAmount: 1250.25 } },
      { currency: 'EUR', _sum: { totalAmount: 99.99 } },
    ]);

    const month = new Date('2026-03-15T00:00:00.000Z');
    const result = await service.calculateMonthlyRevenue(month, ORG_ID);

    expect(result).toEqual([
      { currency: 'USD', total: 1250.25 },
      { currency: 'EUR', total: 99.99 },
    ]);
    expect(prisma.order.groupBy).toHaveBeenCalledWith({
      by: ['currency'],
      where: {
        organizationId: ORG_ID,
        createdAt: {
          gte: new Date('2026-03-01T00:00:00.000Z'),
          lt: new Date('2026-04-01T00:00:00.000Z'),
        },
        status: { not: 'cancelled' },
      },
      _sum: { totalAmount: true },
    });
  });

  it('updates only valid source states in bulkUpdateStatus and invalidates cache', async () => {
    tx.order.updateMany.mockResolvedValueOnce({ count: 2 });
    tx.auditLog.create.mockResolvedValueOnce({});

    const result = await service.bulkUpdateStatus(['a-1', 'a-2', 'a-3'], 'shipped', ORG_ID);

    expect(result).toBe(2);
    expect(tx.order.updateMany).toHaveBeenCalledWith({
      where: {
        organizationId: ORG_ID,
        id: { in: ['a-1', 'a-2', 'a-3'] },
        status: { in: ['processing'] },
      },
      data: { status: 'shipped' },
    });
    expect(redisService.deleteByPrefix).toHaveBeenCalledWith(`orders:${ORG_ID}:`);
  });

  it('returns export payload at maxRows boundary with relational includes', async () => {
    const maxRows = makeOrders(10_000);
    prisma.order.findMany.mockResolvedValueOnce(maxRows);

    const result = await service.getOrdersForExport({}, ORG_ID);

    expect(result).toHaveLength(10_000);
    expect(prisma.order.findMany).toHaveBeenCalledWith({
      where: { organizationId: ORG_ID },
      include: {
        lineItems: true,
        customer: true,
        payments: true,
      },
      orderBy: { createdAt: 'asc' },
      take: 10_001,
    });
  });

  it('throws BadRequestException when export rows exceed maxRows', async () => {
    prisma.order.findMany.mockResolvedValueOnce(makeOrders(10_001));

    const request = service.getOrdersForExport({}, ORG_ID);

    await expect(request).rejects.toBeInstanceOf(BadRequestException);
    await expect(request).rejects.toThrow('Export row limit exceeded (10000)');
  });
});
