// FILE: OrderService.test.ts
import { NotFoundException } from '@nestjs/common';
import { OrderService } from './r2-OrderService';

// ── Test constants ────────────────────────────────────────────────────────────

const ORG_ID = 'org-test-001';
const ORDER_ID = 'order-abc-123';
const CUSTOMER_ID = 'cust-xyz-789';
const PRODUCT_ID = 'prod-001';

const SAMPLE_LINE_ITEMS = [
  { productId: PRODUCT_ID, quantity: 2, unitPrice: 19.99 },
];

const SAMPLE_CREATE_DTO = {
  customerId: CUSTOMER_ID,
  lineItems: SAMPLE_LINE_ITEMS,
  currency: 'USD',
};

const SAMPLE_ORDER = {
  id: ORDER_ID,
  customerId: CUSTOMER_ID,
  organizationId: ORG_ID,
  status: 'pending',
  currency: 'USD',
  createdAt: new Date('2026-01-15T10:00:00Z'),
  lineItems: SAMPLE_LINE_ITEMS,
};

const CONFIRMED_ORDER = { ...SAMPLE_ORDER, status: 'confirmed' };
const SHIPPED_ORDER = { ...SAMPLE_ORDER, status: 'shipped' };

// ── Mock factories ────────────────────────────────────────────────────────────

function makeMockTx() {
  return {
    order: {
      create: jest.fn().mockResolvedValue({ ...SAMPLE_ORDER, id: ORDER_ID }),
      update: jest.fn().mockResolvedValue(SAMPLE_ORDER),
      updateMany: jest.fn().mockResolvedValue({ count: 1 }),
      findFirst: jest.fn().mockResolvedValue(SAMPLE_ORDER),
      delete: jest.fn().mockResolvedValue(SAMPLE_ORDER),
    },
    orderLineItem: {
      deleteMany: jest.fn().mockResolvedValue({ count: 1 }),
    },
    auditLog: {
      create: jest.fn().mockResolvedValue({}),
    },
  };
}

function makeMocks() {
  const tx = makeMockTx();

  const prisma = {
    order: {
      findMany: jest.fn(),
      findFirst: jest.fn(),
      count: jest.fn(),
    },
    orderLineItem: { deleteMany: jest.fn() },
    auditLog: { create: jest.fn() },
    $transaction: jest.fn().mockImplementation((fn: (tx: any) => Promise<any>) => fn(tx)),
  };

  const redis = {
    get: jest.fn().mockResolvedValue(null),
    set: jest.fn().mockResolvedValue(undefined),
    deletePattern: jest.fn().mockResolvedValue(undefined),
  };

  const email = {
    sendShippingNotification: jest.fn().mockResolvedValue(undefined),
  };

  const payment = {};

  return { prisma, redis, email, payment, tx };
}

// ── OrderService constructor helper ──────────────────────────────────────────

function makeService(mocks: ReturnType<typeof makeMocks>) {
  return new (OrderService as any)(
    mocks.prisma,
    mocks.redis,
    mocks.email,
    mocks.payment,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('OrderService', () => {
  let mocks: ReturnType<typeof makeMocks>;
  let service: any;

  beforeEach(() => {
    jest.clearAllMocks();
    mocks = makeMocks();
    service = makeService(mocks);
  });

  // ── findAll ────────────────────────────────────────────────────────────

  describe('findAll', () => {
    it('returns cached result without querying DB on cache hit', async () => {
      const cached = JSON.stringify({ orders: [SAMPLE_ORDER], total: 1 });
      mocks.redis.get.mockResolvedValue(cached);

      const result = await service.findAll({}, ORG_ID);

      expect(result).toEqual({ orders: [SAMPLE_ORDER], total: 1 });
      expect(mocks.prisma.order.findMany).not.toHaveBeenCalled();
    });

    it('queries DB, caches, and returns result on cache miss', async () => {
      mocks.prisma.order.findMany.mockResolvedValue([SAMPLE_ORDER]);
      mocks.prisma.order.count.mockResolvedValue(1);

      const result = await service.findAll({}, ORG_ID);

      expect(result).toEqual({ orders: [SAMPLE_ORDER], total: 1 });
      expect(mocks.redis.set).toHaveBeenCalledWith(
        expect.stringContaining(`orders:${ORG_ID}:`),
        expect.any(String),
        60,
      );
    });

    it('scopes query to organizationId', async () => {
      mocks.prisma.order.findMany.mockResolvedValue([]);
      mocks.prisma.order.count.mockResolvedValue(0);

      await service.findAll({}, ORG_ID);

      expect(mocks.prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ organizationId: ORG_ID }),
        }),
      );
    });

    it('applies status filter to DB query', async () => {
      mocks.prisma.order.findMany.mockResolvedValue([]);
      mocks.prisma.order.count.mockResolvedValue(0);

      await service.findAll({ status: 'pending' }, ORG_ID);

      expect(mocks.prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ status: 'pending' }),
        }),
      );
    });

    it('applies dateRange filter to DB query', async () => {
      const from = new Date('2026-01-01');
      const to = new Date('2026-01-31');
      mocks.prisma.order.findMany.mockResolvedValue([]);
      mocks.prisma.order.count.mockResolvedValue(0);

      await service.findAll({ dateRange: { from, to } }, ORG_ID);

      expect(mocks.prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            createdAt: { gte: from, lte: to },
          }),
        }),
      );
    });

    it('applies take/skip pagination to DB query', async () => {
      mocks.prisma.order.findMany.mockResolvedValue([]);
      mocks.prisma.order.count.mockResolvedValue(0);

      await service.findAll({ take: 10, skip: 20 }, ORG_ID);

      expect(mocks.prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({ take: 10, skip: 20 }),
      );
    });
  });

  // ── findById ───────────────────────────────────────────────────────────

  describe('findById', () => {
    it('returns order when found in the correct org', async () => {
      mocks.prisma.order.findFirst.mockResolvedValue(SAMPLE_ORDER);

      const result = await service.findById(ORDER_ID, ORG_ID);

      expect(result).toEqual(SAMPLE_ORDER);
      expect(mocks.prisma.order.findFirst).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: ORDER_ID, organizationId: ORG_ID },
        }),
      );
    });

    it('throws NotFoundException when order is not found', async () => {
      mocks.prisma.order.findFirst.mockResolvedValue(null);

      await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(
        NotFoundException,
      );
      await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(
        `Order ${ORDER_ID} not found`,
      );
    });

    it('throws NotFoundException when order belongs to a different org', async () => {
      mocks.prisma.order.findFirst.mockResolvedValue(null); // Prisma returns null for wrong org

      await expect(service.findById(ORDER_ID, 'other-org')).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  // ── create ─────────────────────────────────────────────────────────────

  describe('create', () => {
    it('creates order and line items in a single transaction', async () => {
      const result = await service.create(SAMPLE_CREATE_DTO, ORG_ID);

      expect(mocks.prisma.$transaction).toHaveBeenCalled();
      expect(mocks.tx.order.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            customerId: CUSTOMER_ID,
            currency: 'USD',
            organizationId: ORG_ID,
            status: 'pending',
          }),
        }),
      );
    });

    it('emits audit log inside the transaction on creation', async () => {
      await service.create(SAMPLE_CREATE_DTO, ORG_ID);

      expect(mocks.tx.auditLog.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            action: 'ORDER_CREATED',
            organizationId: ORG_ID,
          }),
        }),
      );
    });

    it('invalidates org cache after successful creation', async () => {
      await service.create(SAMPLE_CREATE_DTO, ORG_ID);

      expect(mocks.redis.deletePattern).toHaveBeenCalledWith(`orders:${ORG_ID}:*`);
    });

    it('throws when customerId is missing', async () => {
      await expect(
        service.create({ ...SAMPLE_CREATE_DTO, customerId: '' }, ORG_ID),
      ).rejects.toThrow('customerId is required');
    });

    it('throws when lineItems array is empty', async () => {
      await expect(
        service.create({ ...SAMPLE_CREATE_DTO, lineItems: [] }, ORG_ID),
      ).rejects.toThrow('at least one line item is required');
    });

    it('throws when currency is missing', async () => {
      await expect(
        service.create({ ...SAMPLE_CREATE_DTO, currency: '' }, ORG_ID),
      ).rejects.toThrow('currency is required');
    });

    it('still returns the created order if cache invalidation fails', async () => {
      mocks.redis.deletePattern.mockRejectedValue(new Error('Redis down'));

      const result = await service.create(SAMPLE_CREATE_DTO, ORG_ID);

      // Should NOT throw — mutation succeeded
      expect(result).toBeDefined();
    });
  });

  // ── deleteOrder ────────────────────────────────────────────────────────

  describe('deleteOrder', () => {
    it('deletes order and line items atomically in a transaction', async () => {
      mocks.prisma.order.findFirst.mockResolvedValue(SAMPLE_ORDER);

      await service.deleteOrder(ORDER_ID, ORG_ID);

      expect(mocks.prisma.$transaction).toHaveBeenCalled();
      expect(mocks.tx.orderLineItem.deleteMany).toHaveBeenCalledWith(
        expect.objectContaining({ where: { orderId: ORDER_ID } }),
      );
      expect(mocks.tx.order.delete).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ id: ORDER_ID, organizationId: ORG_ID }),
        }),
      );
    });

    it('emits audit log with previous status inside the transaction', async () => {
      mocks.prisma.order.findFirst.mockResolvedValue(SAMPLE_ORDER);

      await service.deleteOrder(ORDER_ID, ORG_ID);

      expect(mocks.tx.auditLog.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            action: 'ORDER_DELETED',
            entityId: ORDER_ID,
            metadata: expect.objectContaining({ previousStatus: 'pending' }),
          }),
        }),
      );
    });

    it('invalidates org cache after deletion', async () => {
      mocks.prisma.order.findFirst.mockResolvedValue(SAMPLE_ORDER);

      await service.deleteOrder(ORDER_ID, ORG_ID);

      expect(mocks.redis.deletePattern).toHaveBeenCalledWith(`orders:${ORG_ID}:*`);
    });

    it('throws NotFoundException when order does not exist', async () => {
      mocks.prisma.order.findFirst.mockResolvedValue(null);

      await expect(service.deleteOrder(ORDER_ID, ORG_ID)).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  // ── updateStatus ───────────────────────────────────────────────────────

  describe('updateStatus', () => {
    it('transitions order through valid state: pending → confirmed', async () => {
      mocks.prisma.order.findFirst.mockResolvedValueOnce(SAMPLE_ORDER);
      mocks.tx.updateMany = jest.fn().mockResolvedValue({ count: 1 });
      mocks.tx.order.updateMany.mockResolvedValue({ count: 1 });
      mocks.tx.order.findFirst.mockResolvedValue(CONFIRMED_ORDER);

      const result = await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(result).toEqual(CONFIRMED_ORDER);
    });

    it('emits audit log with from/to status on transition', async () => {
      mocks.prisma.order.findFirst.mockResolvedValueOnce(SAMPLE_ORDER);
      mocks.tx.order.updateMany.mockResolvedValue({ count: 1 });
      mocks.tx.order.findFirst.mockResolvedValue(CONFIRMED_ORDER);

      await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(mocks.tx.auditLog.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            action: 'ORDER_STATUS_UPDATED',
            metadata: { from: 'pending', to: 'confirmed' },
          }),
        }),
      );
    });

    it('throws when status transition is invalid: pending → delivered', async () => {
      mocks.prisma.order.findFirst.mockResolvedValue(SAMPLE_ORDER);

      await expect(
        service.updateStatus(ORDER_ID, 'delivered', ORG_ID),
      ).rejects.toThrow('Invalid status transition: pending → delivered');
    });

    it('throws when status transition is invalid: delivered → cancelled', async () => {
      mocks.prisma.order.findFirst.mockResolvedValue({
        ...SAMPLE_ORDER,
        status: 'delivered',
      });

      await expect(
        service.updateStatus(ORDER_ID, 'cancelled', ORG_ID),
      ).rejects.toThrow('Invalid status transition: delivered → cancelled');
    });

    it('sends email notification when status transitions to shipped', async () => {
      const processingOrder = { ...SAMPLE_ORDER, status: 'processing' };
      mocks.prisma.order.findFirst.mockResolvedValueOnce(processingOrder);
      mocks.tx.order.updateMany.mockResolvedValue({ count: 1 });
      mocks.tx.order.findFirst.mockResolvedValue(SHIPPED_ORDER);

      await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

      expect(mocks.email.sendShippingNotification).toHaveBeenCalledWith(
        CUSTOMER_ID,
        ORDER_ID,
      );
    });

    it('does NOT send email when status is not shipped', async () => {
      mocks.prisma.order.findFirst.mockResolvedValueOnce(SAMPLE_ORDER);
      mocks.tx.order.updateMany.mockResolvedValue({ count: 1 });
      mocks.tx.order.findFirst.mockResolvedValue(CONFIRMED_ORDER);

      await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(mocks.email.sendShippingNotification).not.toHaveBeenCalled();
    });

    it('completes status update even when shipping email notification fails', async () => {
      const processingOrder = { ...SAMPLE_ORDER, status: 'processing' };
      mocks.prisma.order.findFirst.mockResolvedValueOnce(processingOrder);
      mocks.tx.order.updateMany.mockResolvedValue({ count: 1 });
      mocks.tx.order.findFirst.mockResolvedValue(SHIPPED_ORDER);
      mocks.email.sendShippingNotification.mockRejectedValue(
        new Error('SMTP connection refused'),
      );

      // Should NOT throw — email failure is caught internally
      const result = await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

      expect(result).toEqual(SHIPPED_ORDER);
    });

    it('throws conflict error when concurrent update changes status first (TOCTOU fix)', async () => {
      mocks.prisma.order.findFirst.mockResolvedValue(SAMPLE_ORDER);
      // Simulate concurrent update already changed status — 0 rows updated
      mocks.tx.order.updateMany.mockResolvedValue({ count: 0 });

      await expect(
        service.updateStatus(ORDER_ID, 'confirmed', ORG_ID),
      ).rejects.toThrow('Concurrent update conflict');
    });

    it('does not throw when cache invalidation fails after successful update', async () => {
      mocks.prisma.order.findFirst.mockResolvedValueOnce(SAMPLE_ORDER);
      mocks.tx.order.updateMany.mockResolvedValue({ count: 1 });
      mocks.tx.order.findFirst.mockResolvedValue(CONFIRMED_ORDER);
      mocks.redis.deletePattern.mockRejectedValue(new Error('Redis unavailable'));

      // Should NOT throw — cache failure is non-fatal
      const result = await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(result).toEqual(CONFIRMED_ORDER);
    });
  });

  // ── calculateMonthlyRevenue ────────────────────────────────────────────

  describe('calculateMonthlyRevenue', () => {
    it('returns revenue grouped by currency for the given month', async () => {
      const orders = [
        {
          currency: 'USD',
          lineItems: [
            { quantity: 2, unitPrice: 50.0 },
            { quantity: 1, unitPrice: 30.0 },
          ],
        },
        {
          currency: 'EUR',
          lineItems: [{ quantity: 3, unitPrice: 20.0 }],
        },
        {
          currency: 'USD',
          lineItems: [{ quantity: 1, unitPrice: 100.0 }],
        },
      ];
      mocks.prisma.order.findMany.mockResolvedValue(orders);

      const result = await service.calculateMonthlyRevenue(
        new Date('2026-01-01'),
        ORG_ID,
      );

      expect(result).toEqual(
        expect.arrayContaining([
          { currency: 'USD', total: 230 },
          { currency: 'EUR', total: 60 },
        ]),
      );
    });

    it('returns empty array when no orders exist for the month', async () => {
      mocks.prisma.order.findMany.mockResolvedValue([]);

      const result = await service.calculateMonthlyRevenue(
        new Date('2026-01-01'),
        ORG_ID,
      );

      expect(result).toEqual([]);
    });

    it('rounds floating-point totals to 2 decimal places', async () => {
      // 3 × 19.99 = 59.970000000000006 in floating point
      const orders = [
        { currency: 'USD', lineItems: [{ quantity: 3, unitPrice: 19.99 }] },
      ];
      mocks.prisma.order.findMany.mockResolvedValue(orders);

      const result = await service.calculateMonthlyRevenue(
        new Date('2026-01-01'),
        ORG_ID,
      );

      expect(result[0].total).toBe(59.97);
    });

    it('queries only shipped and delivered orders for the given org', async () => {
      mocks.prisma.order.findMany.mockResolvedValue([]);

      await service.calculateMonthlyRevenue(new Date('2026-01-01'), ORG_ID);

      expect(mocks.prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            organizationId: ORG_ID,
            status: { in: ['shipped', 'delivered'] },
          }),
        }),
      );
    });
  });

  // ── bulkUpdateStatus ───────────────────────────────────────────────────

  describe('bulkUpdateStatus', () => {
    it('returns count of successfully updated orders', async () => {
      const ids = ['order-1', 'order-2', 'order-3'];
      mocks.prisma.order.findFirst.mockResolvedValue(SAMPLE_ORDER);
      mocks.tx.order.updateMany.mockResolvedValue({ count: 1 });
      mocks.tx.order.findFirst.mockResolvedValue(CONFIRMED_ORDER);

      const count = await service.bulkUpdateStatus(ids, 'confirmed', ORG_ID);

      expect(count).toBe(3);
    });

    it('skips invalid transitions silently and returns only success count', async () => {
      const validOrder = SAMPLE_ORDER; // pending → confirmed is valid
      const invalidOrder = { ...SAMPLE_ORDER, status: 'delivered' }; // delivered → confirmed is invalid

      mocks.prisma.order.findFirst
        .mockResolvedValueOnce(validOrder)
        .mockResolvedValueOnce(invalidOrder)
        .mockResolvedValueOnce(validOrder);
      mocks.tx.order.updateMany.mockResolvedValue({ count: 1 });
      mocks.tx.order.findFirst.mockResolvedValue(CONFIRMED_ORDER);

      const count = await service.bulkUpdateStatus(
        ['order-1', 'order-2', 'order-3'],
        'confirmed',
        ORG_ID,
      );

      // order-2 has invalid transition, so only 2 succeed
      expect(count).toBe(2);
    });

    it('returns 0 when all transitions are invalid', async () => {
      const deliveredOrder = { ...SAMPLE_ORDER, status: 'delivered' };
      mocks.prisma.order.findFirst.mockResolvedValue(deliveredOrder);

      const count = await service.bulkUpdateStatus(
        ['order-1', 'order-2'],
        'confirmed',
        ORG_ID,
      );

      expect(count).toBe(0);
    });

    it('returns 0 for empty ids array', async () => {
      const count = await service.bulkUpdateStatus([], 'confirmed', ORG_ID);
      expect(count).toBe(0);
    });
  });

  // ── getOrdersForExport ─────────────────────────────────────────────────

  describe('getOrdersForExport', () => {
    it('returns orders with lineItems, customer, and payments', async () => {
      const exportData = [
        {
          ...SAMPLE_ORDER,
          customer: { id: CUSTOMER_ID, name: 'Test User' },
          payments: [{ id: 'pay-001', amount: 100 }],
        },
      ];
      mocks.prisma.order.findMany.mockResolvedValue(exportData);

      const result = await service.getOrdersForExport({}, ORG_ID);

      expect(result).toEqual(exportData);
      expect(mocks.prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          include: {
            lineItems: true,
            customer: true,
            payments: true,
          },
        }),
      );
    });

    it('bounds result to maxRows = 10000', async () => {
      mocks.prisma.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({}, ORG_ID);

      expect(mocks.prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({ take: 10_000 }),
      );
    });

    it('scopes export query to organizationId', async () => {
      mocks.prisma.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({}, ORG_ID);

      expect(mocks.prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ organizationId: ORG_ID }),
        }),
      );
    });

    it('applies status filter when provided', async () => {
      mocks.prisma.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({ status: 'shipped' }, ORG_ID);

      expect(mocks.prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ status: 'shipped' }),
        }),
      );
    });
  });
});
