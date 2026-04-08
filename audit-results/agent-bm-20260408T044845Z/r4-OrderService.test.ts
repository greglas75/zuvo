// FILE: OrderService.test.ts
import { NotFoundException } from '@nestjs/common';
import { OrderService } from './r2-OrderService';

// ── Test data constants ────────────────────────────────────────────────────────

const ORG_ID = 'org-test-001';
const ORDER_ID = 'order-abc-123';
const CUSTOMER_ID = 'customer-xyz-456';
const PRODUCT_ID = 'product-def-789';
const UNIT_PRICE = 1999; // cents
const CACHE_TTL = 300;

const BASE_ORDER = {
  id: ORDER_ID,
  customerId: CUSTOMER_ID,
  currency: 'USD',
  organizationId: ORG_ID,
  status: 'pending',
  createdAt: new Date('2026-01-15T10:00:00Z'),
  lineItems: [{ quantity: 2, unitPrice: UNIT_PRICE, productId: PRODUCT_ID }],
};

const CREATE_DTO = {
  customerId: CUSTOMER_ID,
  lineItems: [{ productId: PRODUCT_ID, quantity: 2, unitPrice: UNIT_PRICE }],
  currency: 'USD',
};

// ── Mock factories ─────────────────────────────────────────────────────────────

function makePrismaMock() {
  const tx = {
    order: {
      findFirst: jest.fn(),
      findMany: jest.fn(),
      count: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
      delete: jest.fn(),
      groupBy: jest.fn(),
    },
    orderLineItem: { deleteMany: jest.fn() },
    auditLog: { create: jest.fn().mockResolvedValue(undefined) },
    product: { findUnique: jest.fn() },
  };

  // Default: callback-based transaction uses _tx; array-based uses Promise.all over real mocks
  const instance = {
    $transaction: jest.fn().mockImplementation((fnOrArr: unknown) => {
      if (typeof fnOrArr === 'function') return (fnOrArr as (tx: typeof tx) => Promise<unknown>)(tx);
      return Promise.all(fnOrArr as Promise<unknown>[]);
    }),
    order: {
      findFirst: jest.fn(),
      findMany: jest.fn(),
      count: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
      delete: jest.fn(),
      groupBy: jest.fn(),
    },
    orderLineItem: { deleteMany: jest.fn() },
    auditLog: { create: jest.fn().mockResolvedValue(undefined) },
    product: { findUnique: jest.fn() },
    _tx: tx,
  };

  return instance;
}

function makeRedisMock() {
  const store = new Map<string, string>();
  return {
    get: jest.fn().mockImplementation((k: string) => Promise.resolve(store.get(k) ?? null)),
    set: jest.fn().mockImplementation((k: string, v: string) => {
      store.set(k, v);
      return Promise.resolve();
    }),
    del: jest.fn().mockImplementation((k: string) => {
      store.delete(k);
      return Promise.resolve();
    }),
    _store: store,
  };
}

function makeEmailMock() {
  return { sendShippingNotification: jest.fn().mockResolvedValue(undefined) };
}

function makePaymentMock() {
  return {};
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Flush micro-task queue for fire-and-forget side effects */
const flushPromises = () => new Promise((r) => setTimeout(r, 0));

// ── Tests ─────────────────────────────────────────────────────────────────────

describe('OrderService', () => {
  let service: OrderService;
  let prisma: ReturnType<typeof makePrismaMock>;
  let redis: ReturnType<typeof makeRedisMock>;
  let emailService: ReturnType<typeof makeEmailMock>;

  beforeEach(() => {
    jest.clearAllMocks();
    prisma = makePrismaMock();
    redis = makeRedisMock();
    emailService = makeEmailMock();
    service = new OrderService(
      prisma as never,
      redis as never,
      emailService as never,
      makePaymentMock() as never,
    );
  });

  // ── findAll ─────────────────────────────────────────────────────────────────

  describe('findAll', () => {
    it('returns paginated orders from database on cache miss', async () => {
      // Use the real mock implementation — do NOT override $transaction to keep query args visible
      prisma.order.findMany.mockResolvedValue([BASE_ORDER]);
      prisma.order.count.mockResolvedValue(1);

      const result = await service.findAll({ take: 10, skip: 0 }, ORG_ID);

      expect(result.orders).toEqual([BASE_ORDER]);
      expect(result.total).toBe(1);
    });

    it('passes organizationId in WHERE clause to scope query to correct org', async () => {
      // This test prevents multi-tenancy data leaks.
      // If organizationId is removed from findAll's where clause, this fails.
      prisma.order.findMany.mockResolvedValue([BASE_ORDER]);
      prisma.order.count.mockResolvedValue(1);

      await service.findAll({ take: 10, skip: 0 }, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ organizationId: ORG_ID }),
          take: 10,
          skip: 0,
        }),
      );
    });

    it('caches DB result with correct TTL on cache miss', async () => {
      prisma.order.findMany.mockResolvedValue([BASE_ORDER]);
      prisma.order.count.mockResolvedValue(1);

      await service.findAll({ take: 10, skip: 0 }, ORG_ID);

      expect(redis.set).toHaveBeenCalledWith(
        expect.stringContaining(`orders:${ORG_ID}:`),
        expect.stringContaining(ORDER_ID),
        CACHE_TTL,
      );
    });

    it('returns cached result on cache hit and skips DB', async () => {
      const cached = JSON.stringify({ orders: [BASE_ORDER], total: 1 });
      redis._store.set('cache-ver:org-test-001', '0');
      redis._store.set(
        'orders:org-test-001:v0:list:{"take":10,"skip":0}',
        cached,
      );
      redis.get.mockImplementation((k: string) =>
        Promise.resolve(redis._store.get(k) ?? null),
      );

      const result = await service.findAll({ take: 10, skip: 0 }, ORG_ID);

      expect(prisma.order.findMany).not.toHaveBeenCalled();
      expect(result.total).toBe(1);
    });

    it('revives Date strings from cache into Date objects', async () => {
      const serialized = JSON.stringify({
        orders: [{ ...BASE_ORDER, createdAt: '2026-01-15T10:00:00.000Z' }],
        total: 1,
      });
      redis._store.set('cache-ver:org-test-001', '0');
      redis._store.set('orders:org-test-001:v0:list:{"take":20,"skip":0}', serialized);
      redis.get.mockImplementation((k: string) =>
        Promise.resolve(redis._store.get(k) ?? null),
      );

      const result = await service.findAll({}, ORG_ID);

      expect(result.orders[0].createdAt).toBeInstanceOf(Date);
    });

    it('applies status filter when provided', async () => {
      prisma.order.findMany.mockResolvedValue([]);
      prisma.order.count.mockResolvedValue(0);

      await service.findAll({ status: 'shipped' }, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ status: 'shipped', organizationId: ORG_ID }),
        }),
      );
    });
  });

  // ── findById ────────────────────────────────────────────────────────────────

  describe('findById', () => {
    it('returns order when found in correct org', async () => {
      prisma.order.findFirst.mockResolvedValue(BASE_ORDER);

      const result = await service.findById(ORDER_ID, ORG_ID);

      expect(result).toEqual(BASE_ORDER);
      expect(prisma.order.findFirst).toHaveBeenCalledWith(
        expect.objectContaining({ where: { id: ORDER_ID, organizationId: ORG_ID } }),
      );
    });

    it('throws NotFoundException when order not found', async () => {
      prisma.order.findFirst.mockResolvedValue(null);

      await expect(service.findById('missing-id', ORG_ID)).rejects.toThrow(
        NotFoundException,
      );
      await expect(service.findById('missing-id', ORG_ID)).rejects.toThrow(
        'Order missing-id not found',
      );
    });

    it('throws NotFoundException when order belongs to different org', async () => {
      prisma.order.findFirst.mockResolvedValue(null); // where includes organizationId

      await expect(service.findById(ORDER_ID, 'other-org')).rejects.toThrow(
        NotFoundException,
      );
    });

    it('caches DB result with correct key format and TTL', async () => {
      prisma.order.findFirst.mockResolvedValue(BASE_ORDER);

      await service.findById(ORDER_ID, ORG_ID);

      expect(redis.set).toHaveBeenCalledWith(
        expect.stringContaining(`order:${ORDER_ID}`),
        JSON.stringify(BASE_ORDER),
        CACHE_TTL,
      );
    });

    it('returns cached order on hit without hitting DB', async () => {
      redis._store.set('cache-ver:org-test-001', '0');
      redis._store.set(
        `orders:org-test-001:v0:order:${ORDER_ID}`,
        JSON.stringify(BASE_ORDER),
      );
      redis.get.mockImplementation((k: string) =>
        Promise.resolve(redis._store.get(k) ?? null),
      );

      const result = await service.findById(ORDER_ID, ORG_ID);

      expect(prisma.order.findFirst).not.toHaveBeenCalled();
      expect(result.id).toBe(ORDER_ID);
    });
  });

  // ── create ──────────────────────────────────────────────────────────────────

  describe('create', () => {
    beforeEach(() => {
      prisma._tx.product.findUnique.mockResolvedValue({
        id: PRODUCT_ID,
        unitPrice: UNIT_PRICE,
      });
      prisma._tx.order.create.mockResolvedValue(BASE_ORDER);
    });

    it('creates order with line items inside a transaction', async () => {
      const result = await service.create(CREATE_DTO, ORG_ID);

      expect(prisma.$transaction).toHaveBeenCalled();
      expect(prisma._tx.order.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            customerId: CUSTOMER_ID,
            currency: 'USD',
            organizationId: ORG_ID,
            status: 'pending',
          }),
        }),
      );
      expect(result.id).toBe(ORDER_ID);
    });

    it('rejects order when unit price differs from database price', async () => {
      prisma._tx.product.findUnique.mockResolvedValue({
        id: PRODUCT_ID,
        unitPrice: 5000, // different from DTO
      });

      await expect(
        service.create(
          { ...CREATE_DTO, lineItems: [{ productId: PRODUCT_ID, quantity: 1, unitPrice: UNIT_PRICE }] },
          ORG_ID,
        ),
      ).rejects.toThrow(`Price mismatch for product ${PRODUCT_ID}`);
    });

    it('rejects order when product is not found in database', async () => {
      prisma._tx.product.findUnique.mockResolvedValue(null);

      await expect(service.create(CREATE_DTO, ORG_ID)).rejects.toThrow(
        `Product ${PRODUCT_ID} not found`,
      );
    });

    it('throws when customerId is missing', async () => {
      await expect(
        service.create({ ...CREATE_DTO, customerId: '' }, ORG_ID),
      ).rejects.toThrow('customerId is required');
    });

    it('throws when currency is missing', async () => {
      await expect(
        service.create({ ...CREATE_DTO, currency: '' }, ORG_ID),
      ).rejects.toThrow('currency is required');
    });

    it('throws when lineItems is empty', async () => {
      await expect(
        service.create({ ...CREATE_DTO, lineItems: [] }, ORG_ID),
      ).rejects.toThrow('lineItems cannot be empty');
    });

    it('throws when a lineItem quantity is non-positive', async () => {
      await expect(
        service.create(
          {
            ...CREATE_DTO,
            lineItems: [{ productId: PRODUCT_ID, quantity: 0, unitPrice: UNIT_PRICE }],
          },
          ORG_ID,
        ),
      ).rejects.toThrow('lineItem quantity must be positive');
    });

    it('throws when a lineItem unitPrice is negative', async () => {
      await expect(
        service.create(
          {
            ...CREATE_DTO,
            lineItems: [{ productId: PRODUCT_ID, quantity: 1, unitPrice: -1 }],
          },
          ORG_ID,
        ),
      ).rejects.toThrow('lineItem unitPrice must be non-negative');
    });

    it('fires-and-forgets cache invalidation after successful create', async () => {
      await service.create(CREATE_DTO, ORG_ID);
      await flushPromises();

      expect(redis.set).toHaveBeenCalledWith(
        `cache-ver:${ORG_ID}`,
        expect.any(String),
        86400,
      );
    });
  });

  // ── deleteOrder ──────────────────────────────────────────────────────────────

  describe('deleteOrder', () => {
    beforeEach(() => {
      prisma.$transaction.mockImplementation(
        async (fn: (tx: typeof prisma._tx) => Promise<unknown>) => fn(prisma._tx),
      );
    });

    it('deletes order and line items atomically in a transaction', async () => {
      prisma._tx.order.findFirst.mockResolvedValue(BASE_ORDER);
      prisma._tx.orderLineItem.deleteMany.mockResolvedValue({ count: 1 });
      prisma._tx.order.delete.mockResolvedValue(BASE_ORDER);

      await service.deleteOrder(ORDER_ID, ORG_ID);

      expect(prisma._tx.orderLineItem.deleteMany).toHaveBeenCalledWith(
        expect.objectContaining({ where: { orderId: ORDER_ID } }),
      );
      expect(prisma._tx.order.delete).toHaveBeenCalledWith(
        expect.objectContaining({ where: { id: ORDER_ID } }),
      );
    });

    it('throws NotFoundException when order not found during delete', async () => {
      prisma._tx.order.findFirst.mockResolvedValue(null);

      await expect(service.deleteOrder('ghost-id', ORG_ID)).rejects.toThrow(
        NotFoundException,
      );
      await expect(service.deleteOrder('ghost-id', ORG_ID)).rejects.toThrow(
        'Order ghost-id not found',
      );
    });

    it('fires-and-forgets cache invalidation after successful delete', async () => {
      prisma._tx.order.findFirst.mockResolvedValue(BASE_ORDER);
      prisma._tx.orderLineItem.deleteMany.mockResolvedValue({ count: 1 });
      prisma._tx.order.delete.mockResolvedValue(BASE_ORDER);

      await service.deleteOrder(ORDER_ID, ORG_ID);
      await flushPromises();

      expect(redis.set).toHaveBeenCalledWith(`cache-ver:${ORG_ID}`, expect.any(String), 86400);
    });
  });

  // ── updateStatus ─────────────────────────────────────────────────────────────

  describe('updateStatus', () => {
    it('transitions from pending to confirmed with optimistic lock', async () => {
      const confirmedOrder = { ...BASE_ORDER, status: 'confirmed' };
      prisma.order.findFirst
        .mockResolvedValueOnce(BASE_ORDER)
        .mockResolvedValueOnce(confirmedOrder);
      prisma.order.updateMany.mockResolvedValue({ count: 1 });

      const result = await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      // Verify optimistic lock: updateMany WHERE includes current status
      expect(prisma.order.updateMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ id: ORDER_ID, status: 'pending' }),
          data: { status: 'confirmed' },
        }),
      );
      expect(result.status).toBe('confirmed');
    });

    it('throws on invalid state transition', async () => {
      prisma.order.findFirst.mockResolvedValue(BASE_ORDER); // pending

      await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).rejects.toThrow(
        'Invalid transition: pending → shipped',
      );
    });

    it('throws when concurrent update wins (optimistic lock returns count=0)', async () => {
      prisma.order.findFirst.mockResolvedValue(BASE_ORDER);
      prisma.order.updateMany.mockResolvedValue({ count: 0 });

      await expect(service.updateStatus(ORDER_ID, 'confirmed', ORG_ID)).rejects.toThrow(
        'status was concurrently modified',
      );
    });

    it('sends email notification on shipped status', async () => {
      const shippingOrder = { ...BASE_ORDER, status: 'processing' };
      const shippedOrder = { ...BASE_ORDER, status: 'shipped' };
      prisma.order.findFirst
        .mockResolvedValueOnce(shippingOrder)
        .mockResolvedValueOnce(shippedOrder);
      prisma.order.updateMany.mockResolvedValue({ count: 1 });

      await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);
      await flushPromises();

      expect(emailService.sendShippingNotification).toHaveBeenCalledWith(
        CUSTOMER_ID,
        ORDER_ID,
      );
    });

    it('does not propagate email failure on shipped status', async () => {
      const shippingOrder = { ...BASE_ORDER, status: 'processing' };
      const shippedOrder = { ...BASE_ORDER, status: 'shipped' };
      prisma.order.findFirst
        .mockResolvedValueOnce(shippingOrder)
        .mockResolvedValueOnce(shippedOrder);
      prisma.order.updateMany.mockResolvedValue({ count: 1 });
      emailService.sendShippingNotification.mockRejectedValue(new Error('SMTP down'));

      await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).resolves.not.toThrow();
    });

    it('allows cancellation from any non-delivered state', async () => {
      for (const status of ['pending', 'confirmed', 'processing', 'shipped'] as const) {
        prisma.order.findFirst
          .mockResolvedValueOnce({ ...BASE_ORDER, status })
          .mockResolvedValueOnce({ ...BASE_ORDER, status: 'cancelled' });
        prisma.order.updateMany.mockResolvedValue({ count: 1 });

        await expect(service.updateStatus(ORDER_ID, 'cancelled', ORG_ID)).resolves.not.toThrow();
      }
    });

    it('prevents cancellation from delivered state', async () => {
      prisma.order.findFirst.mockResolvedValue({ ...BASE_ORDER, status: 'delivered' });

      await expect(service.updateStatus(ORDER_ID, 'cancelled', ORG_ID)).rejects.toThrow(
        'Invalid transition: delivered → cancelled',
      );
    });

    it('throws NotFoundException when order not found', async () => {
      prisma.order.findFirst.mockResolvedValue(null);

      await expect(service.updateStatus(ORDER_ID, 'confirmed', ORG_ID)).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  // ── calculateMonthlyRevenue ──────────────────────────────────────────────────

  describe('calculateMonthlyRevenue', () => {
    it('aggregates revenue per currency for the given month', async () => {
      prisma.order.groupBy.mockResolvedValue([
        { currency: 'USD', _sum: { revenue: 50000 } },
        { currency: 'EUR', _sum: { revenue: 30000 } },
      ]);

      const result = await service.calculateMonthlyRevenue(
        new Date('2026-01-01T00:00:00Z'),
        ORG_ID,
      );

      expect(result).toEqual([
        { currency: 'USD', total: 50000 },
        { currency: 'EUR', total: 30000 },
      ]);
    });

    it('excludes cancelled orders from revenue aggregation', async () => {
      // This test verifies the status filter in the WHERE clause.
      // Removing `status: { not: 'cancelled' }` in production would break this.
      prisma.order.groupBy.mockResolvedValue([]);

      await service.calculateMonthlyRevenue(new Date('2026-01-01T00:00:00Z'), ORG_ID);

      expect(prisma.order.groupBy).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            status: { not: 'cancelled' },
          }),
        }),
      );
    });

    it('uses UTC boundaries to avoid timezone-dependent month shifts', async () => {
      prisma.order.groupBy.mockResolvedValue([]);

      await service.calculateMonthlyRevenue(new Date('2026-01-01T00:00:00Z'), ORG_ID);

      expect(prisma.order.groupBy).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            createdAt: {
              gte: new Date('2026-01-01T00:00:00.000Z'),
              lte: new Date('2026-01-31T23:59:59.999Z'),
            },
          }),
        }),
      );
    });

    it('scopes revenue to the correct org', async () => {
      prisma.order.groupBy.mockResolvedValue([]);

      await service.calculateMonthlyRevenue(new Date('2026-01-01T00:00:00Z'), ORG_ID);

      expect(prisma.order.groupBy).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ organizationId: ORG_ID }),
        }),
      );
    });

    it('returns empty array when no orders found', async () => {
      prisma.order.groupBy.mockResolvedValue([]);

      const result = await service.calculateMonthlyRevenue(
        new Date('2026-01-01T00:00:00Z'),
        ORG_ID,
      );

      expect(result).toEqual([]);
    });

    it('returns 0 total when _sum.revenue is null', async () => {
      prisma.order.groupBy.mockResolvedValue([
        { currency: 'USD', _sum: { revenue: null } },
      ]);

      const result = await service.calculateMonthlyRevenue(
        new Date('2026-01-01T00:00:00Z'),
        ORG_ID,
      );

      expect(result[0].total).toBe(0);
    });
  });

  // ── bulkUpdateStatus ─────────────────────────────────────────────────────────

  describe('bulkUpdateStatus', () => {
    const PENDING_ORDERS = [
      { ...BASE_ORDER, id: 'o1', status: 'pending' },
      { ...BASE_ORDER, id: 'o2', status: 'pending' },
    ];
    const MIXED_ORDERS = [
      { ...BASE_ORDER, id: 'o1', status: 'pending' },
      { ...BASE_ORDER, id: 'o2', status: 'delivered' }, // invalid transition
    ];

    it('returns count of actually updated orders (from updateMany result)', async () => {
      prisma.order.findMany.mockResolvedValue(PENDING_ORDERS);
      prisma.order.updateMany.mockResolvedValue({ count: 2 });

      const count = await service.bulkUpdateStatus(['o1', 'o2'], 'confirmed', ORG_ID);

      expect(count).toBe(2);
    });

    it('skips orders with invalid transitions silently', async () => {
      prisma.order.findMany.mockResolvedValue(MIXED_ORDERS);
      prisma.order.updateMany.mockResolvedValue({ count: 1 });

      await service.bulkUpdateStatus(['o1', 'o2'], 'confirmed', ORG_ID);

      // Only o1 (pending→confirmed) eligible; o2 (delivered→confirmed) excluded
      expect(prisma.order.updateMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ id: { in: ['o1'] } }),
        }),
      );
    });

    it('returns 0 and skips DB when all orders have invalid transitions', async () => {
      prisma.order.findMany.mockResolvedValue([
        { ...BASE_ORDER, id: 'o1', status: 'delivered' },
      ]);

      const count = await service.bulkUpdateStatus(['o1'], 'confirmed', ORG_ID);

      expect(count).toBe(0);
      expect(prisma.order.updateMany).not.toHaveBeenCalled();
    });

    it('returns 0 for empty ids array without querying DB', async () => {
      const count = await service.bulkUpdateStatus([], 'confirmed', ORG_ID);

      expect(count).toBe(0);
      expect(prisma.order.findMany).not.toHaveBeenCalled();
    });

    it('sends batched emails on bulk ship without overwhelming email service', async () => {
      const manyOrders = Array.from({ length: 60 }, (_, i) => ({
        ...BASE_ORDER,
        id: `o${i}`,
        status: 'processing',
      }));
      prisma.order.findMany.mockResolvedValue(manyOrders);
      prisma.order.updateMany.mockResolvedValue({ count: 60 });

      await service.bulkUpdateStatus(manyOrders.map((o) => o.id), 'shipped', ORG_ID);
      await flushPromises();
      await flushPromises(); // second flush for the nested async IIFE

      expect(emailService.sendShippingNotification).toHaveBeenCalledTimes(60);
    });

    it('guards updateMany with current statuses to prevent TOCTOU overwrites', async () => {
      prisma.order.findMany.mockResolvedValue(PENDING_ORDERS);
      prisma.order.updateMany.mockResolvedValue({ count: 2 });

      await service.bulkUpdateStatus(['o1', 'o2'], 'confirmed', ORG_ID);

      // WHERE must include status constraint to guard against concurrent updates
      expect(prisma.order.updateMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            status: expect.anything(), // status guard is present
          }),
        }),
      );
    });
  });

  // ── getOrdersForExport ────────────────────────────────────────────────────────

  describe('getOrdersForExport', () => {
    it('returns full order data including line items, customer, and payments', async () => {
      prisma.order.findMany.mockResolvedValue([BASE_ORDER]);

      const result = await service.getOrdersForExport({}, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          include: expect.objectContaining({
            lineItems: true,
            customer: true,
            payments: true,
          }),
        }),
      );
      expect(result).toEqual([BASE_ORDER]);
    });

    it('enforces maxRows hard limit of 10000', async () => {
      prisma.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({}, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({ take: 10_000 }),
      );
    });

    it('scopes export to the correct org', async () => {
      prisma.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({}, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ organizationId: ORG_ID }),
        }),
      );
    });

    it('applies status filter when provided', async () => {
      prisma.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({ status: 'shipped' }, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ status: 'shipped', organizationId: ORG_ID }),
        }),
      );
    });

    it('applies dateRange filter when provided', async () => {
      prisma.order.findMany.mockResolvedValue([]);
      const from = new Date('2026-01-01');
      const to = new Date('2026-01-31');

      await service.getOrdersForExport({ dateRange: { from, to } }, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            createdAt: { gte: from, lte: to },
          }),
        }),
      );
    });
  });
});
