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

describe('OrderService (round 3)', () => {
  let prisma: any;
  let redisService: any;
  let emailService: any;
  let paymentGateway: any;
  let service: OrderService;

  beforeEach(() => {
    jest.clearAllMocks();

    prisma = {
      order: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        create: jest.fn(),
        delete: jest.fn(),
        update: jest.fn(),
        updateMany: jest.fn(),
        groupBy: jest.fn(),
      },
      orderLineItem: {
        deleteMany: jest.fn(),
      },
      auditLog: {
        create: jest.fn(),
      },
      $transaction: jest.fn(async (callback: (tx: any) => Promise<unknown>) => callback(prisma)),
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

  it('queries DB and writes cache on cache miss for findAll', async () => {
    redisService.get.mockResolvedValueOnce(null);
    prisma.order.findMany.mockResolvedValueOnce([BASE_ORDER]);

    const filters = {
      status: 'pending' as const,
      customerId: CUSTOMER_ID,
      dateRange: { from: new Date('2026-03-01T00:00:00.000Z'), to: new Date('2026-03-31T23:59:59.000Z') },
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
        }),
        take: 25,
        skip: 5,
      }),
    );
    expect(redisService.setex).toHaveBeenCalledWith(expect.stringContaining(`orders:${ORG_ID}:findAll:`), 120, expect.any(String));
  });

  it('throws NotFoundException when order not found in org', async () => {
    prisma.order.findFirst.mockResolvedValueOnce(null);

    await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(NotFoundException);
    await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(`Order ${ORDER_ID} not found`);
  });

  it('returns order by id when it exists in org', async () => {
    prisma.order.findFirst.mockResolvedValueOnce(BASE_ORDER);

    const result = await service.findById(ORDER_ID, ORG_ID);

    expect(result).toEqual(BASE_ORDER);
    expect(prisma.order.findFirst).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_ID },
    });
  });

  it('creates order with line items in a transaction and audits mutation', async () => {
    prisma.order.create.mockResolvedValueOnce({ ...BASE_ORDER, status: 'pending', totalAmount: 120.5 });
    prisma.auditLog.create.mockResolvedValueOnce({});

    const result = await service.create(VALID_CREATE_DTO, ORG_ID);

    expect(result.id).toBe(ORDER_ID);
    expect(paymentGateway.validateCurrency).toHaveBeenCalledWith('USD');
    expect(prisma.order.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          organizationId: ORG_ID,
          customerId: CUSTOMER_ID,
          currency: 'USD',
        }),
      }),
    );
    expect(prisma.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          action: 'order.create',
          organizationId: ORG_ID,
        }),
      }),
    );
    expect(redisService.deleteByPrefix).toHaveBeenCalledWith(`orders:${ORG_ID}:`);
  });

  it('propagates transaction rollback error in create and does not invalidate cache', async () => {
    prisma.$transaction.mockRejectedValueOnce(new Error('transaction rollback'));

    await expect(service.create(VALID_CREATE_DTO, ORG_ID)).rejects.toThrow('transaction rollback');
    expect(redisService.deleteByPrefix).not.toHaveBeenCalled();
  });

  it('deletes order and line items atomically and writes audit log', async () => {
    prisma.order.findFirst.mockResolvedValueOnce(BASE_ORDER);
    prisma.orderLineItem.deleteMany.mockResolvedValueOnce({ count: 2 });
    prisma.order.delete.mockResolvedValueOnce(BASE_ORDER);
    prisma.auditLog.create.mockResolvedValueOnce({});

    await service.deleteOrder(ORDER_ID, ORG_ID);

    expect(prisma.order.findFirst).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_ID },
    });
    expect(prisma.orderLineItem.deleteMany).toHaveBeenCalledWith({
      where: { orderId: ORDER_ID, organizationId: ORG_ID },
    });
    expect(prisma.order.delete).toHaveBeenCalledWith({
      where: { id: ORDER_ID, organizationId: ORG_ID },
    });
    expect(prisma.auditLog.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ action: 'order.delete' }),
      }),
    );
  });

  it('updates status through valid transition and sends shipment email with expected payload', async () => {
    const processingOrder = { ...BASE_ORDER, status: 'processing' as const };
    const shippedOrder = { ...BASE_ORDER, status: 'shipped' as const };
    prisma.order.findFirst
      .mockResolvedValueOnce(processingOrder)
      .mockResolvedValueOnce(shippedOrder);
    prisma.order.updateMany.mockResolvedValueOnce({ count: 1 });
    prisma.auditLog.create.mockResolvedValueOnce({});

    const result = await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

    expect(result.status).toBe('shipped');
    expect(prisma.order.updateMany).toHaveBeenCalledWith({
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
  });

  it('does not throw when shipped email notification fails', async () => {
    const processingOrder = { ...BASE_ORDER, status: 'processing' as const };
    const shippedOrder = { ...BASE_ORDER, status: 'shipped' as const };
    prisma.order.findFirst
      .mockResolvedValueOnce(processingOrder)
      .mockResolvedValueOnce(shippedOrder);
    prisma.order.updateMany.mockResolvedValueOnce({ count: 1 });
    prisma.auditLog.create.mockResolvedValueOnce({});
    emailService.sendOrderShipped.mockRejectedValueOnce(new Error('SMTP unavailable'));

    await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).resolves.toEqual(shippedOrder);
  });

  it('throws BadRequestException on invalid status transition', async () => {
    prisma.order.findFirst.mockResolvedValueOnce({ ...BASE_ORDER, status: 'pending' });

    await expect(service.updateStatus(ORDER_ID, 'delivered', ORG_ID)).rejects.toThrow(BadRequestException);
    await expect(service.updateStatus(ORDER_ID, 'delivered', ORG_ID)).rejects.toThrow(
      'Invalid transition from pending to delivered',
    );
  });

  it('throws ConflictException when atomic status update affected no rows', async () => {
    prisma.order.findFirst.mockResolvedValueOnce({ ...BASE_ORDER, status: 'processing' });
    prisma.order.updateMany.mockResolvedValueOnce({ count: 0 });

    await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).rejects.toThrow(ConflictException);
    await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).rejects.toThrow(
      'Order status changed by another request',
    );
  });

  it('aggregates monthly revenue by currency', async () => {
    prisma.order.groupBy.mockResolvedValueOnce([
      { currency: 'USD', _sum: { totalAmount: 1250.25 } },
      { currency: 'EUR', _sum: { totalAmount: 99.99 } },
    ]);

    const result = await service.calculateMonthlyRevenue(new Date('2026-03-15T00:00:00.000Z'), ORG_ID);

    expect(result).toEqual([
      { currency: 'USD', total: 1250.25 },
      { currency: 'EUR', total: 99.99 },
    ]);
    expect(prisma.order.groupBy).toHaveBeenCalledWith(
      expect.objectContaining({
        by: ['currency'],
        where: expect.objectContaining({ organizationId: ORG_ID }),
      }),
    );
  });

  it('updates only valid source states in bulkUpdateStatus and skips invalid transitions', async () => {
    prisma.order.updateMany.mockResolvedValueOnce({ count: 2 });
    prisma.auditLog.create.mockResolvedValueOnce({});

    const result = await service.bulkUpdateStatus(['a-1', 'a-2', 'a-3'], 'shipped', ORG_ID);

    expect(result).toBe(2);
    expect(prisma.order.updateMany).toHaveBeenCalledWith({
      where: {
        organizationId: ORG_ID,
        id: { in: ['a-1', 'a-2', 'a-3'] },
        status: { in: ['processing'] },
      },
      data: { status: 'shipped' },
    });
  });

  it('returns export payload at maxRows boundary and includes relational data', async () => {
    const maxRows = makeOrders(10_000);
    prisma.order.findMany.mockResolvedValueOnce(maxRows);

    const result = await service.getOrdersForExport({}, ORG_ID);

    expect(result).toHaveLength(10_000);
    expect(prisma.order.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
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

    await expect(service.getOrdersForExport({}, ORG_ID)).rejects.toThrow(BadRequestException);
    await expect(service.getOrdersForExport({}, ORG_ID)).rejects.toThrow('Export row limit exceeded (10000)');
  });
});
