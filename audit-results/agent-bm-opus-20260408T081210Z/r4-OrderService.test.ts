// FILE: OrderService.test.ts
import { NotFoundException, BadRequestException, ConflictException } from '@nestjs/common';
import { OrderService } from './r2-OrderService';

// --- Test Constants ---

const ORG_ID = 'org-test-123';
const ORDER_ID = 'order-abc-001';
const CUSTOMER_ID = 'cust-xyz-001';
const PRODUCT_ID_A = 'prod-a-001';
const PRODUCT_ID_B = 'prod-b-002';
const CURRENCY_USD = 'USD';
const MAX_EXPORT_ROWS = 10_000;

const MOCK_LINE_ITEMS = [
  { productId: PRODUCT_ID_A, quantity: 2, unitPrice: 25.0 },
  { productId: PRODUCT_ID_B, quantity: 1, unitPrice: 50.0 },
];

const MOCK_ORDER = {
  id: ORDER_ID,
  customerId: CUSTOMER_ID,
  organizationId: ORG_ID,
  status: 'pending',
  currency: CURRENCY_USD,
  totalAmount: 100.0,
  createdAt: new Date('2026-01-15T10:00:00Z'),
  lineItems: [
    { id: 'li-1', productId: PRODUCT_ID_A, quantity: 2, unitPrice: 25.0, subtotal: 50.0 },
    { id: 'li-2', productId: PRODUCT_ID_B, quantity: 1, unitPrice: 50.0, subtotal: 50.0 },
  ],
};

const MOCK_ORDER_WITH_RELATIONS = {
  ...MOCK_ORDER,
  customer: { id: CUSTOMER_ID, name: 'Test Customer' },
  payments: [],
};

// --- Mock Factories ---

function createMockPrisma() {
  const txProxy = {
    order: {
      findFirst: jest.fn(),
      findMany: jest.fn(),
      create: jest.fn(),
      delete: jest.fn(),
      updateMany: jest.fn(),
      count: jest.fn(),
      groupBy: jest.fn(),
      findFirstOrThrow: jest.fn(),
    },
    lineItem: { deleteMany: jest.fn() },
    auditLog: { create: jest.fn() },
  };

  return {
    order: {
      findFirst: jest.fn(),
      findMany: jest.fn(),
      create: jest.fn(),
      delete: jest.fn(),
      updateMany: jest.fn(),
      count: jest.fn(),
      groupBy: jest.fn(),
    },
    $transaction: jest.fn((cb: (tx: typeof txProxy) => Promise<unknown>) => cb(txProxy)),
    _tx: txProxy,
  };
}

function createMockRedis() {
  return {
    get: jest.fn().mockResolvedValue(null),
    set: jest.fn().mockResolvedValue('OK'),
    incr: jest.fn().mockResolvedValue(1),
  };
}

function createMockEmail() {
  return {
    sendShippingNotification: jest.fn().mockResolvedValue(undefined),
  };
}

function createMockPaymentGateway() {
  return {};
}

// --- Test Suite ---

describe('OrderService', () => {
  let service: OrderService;
  let prisma: ReturnType<typeof createMockPrisma>;
  let redis: ReturnType<typeof createMockRedis>;
  let email: ReturnType<typeof createMockEmail>;
  let paymentGateway: ReturnType<typeof createMockPaymentGateway>;

  beforeEach(() => {
    jest.clearAllMocks();
    prisma = createMockPrisma();
    redis = createMockRedis();
    email = createMockEmail();
    paymentGateway = createMockPaymentGateway();
    service = new OrderService(
      prisma as any,
      redis as any,
      email as any,
      paymentGateway as any,
    );
  });

  // === findAll ===

  describe('findAll', () => {
    it('returns paginated orders from database on cache miss', async () => {
      prisma.order.findMany.mockResolvedValue([MOCK_ORDER]);
      prisma.order.count.mockResolvedValue(1);

      const result = await service.findAll({}, ORG_ID);

      expect(result).toEqual({ items: [MOCK_ORDER], total: 1, take: 20, skip: 0 });
      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { organizationId: ORG_ID },
          take: 20,
          skip: 0,
        }),
      );
    });

    it('returns full cached result on cache hit preserving all fields', async () => {
      const cachedResult = { items: [MOCK_ORDER], total: 1, take: 20, skip: 0 };
      redis.get.mockResolvedValueOnce('0'); // version
      redis.get.mockResolvedValueOnce(JSON.stringify(cachedResult)); // cached data

      const result = await service.findAll({}, ORG_ID);

      // Assert full object integrity, not just item count
      expect(result).toEqual(expect.objectContaining({
        total: 1,
        take: 20,
        skip: 0,
      }));
      expect(result.items).toHaveLength(1);
      expect(prisma.order.findMany).not.toHaveBeenCalled();
    });

    it('applies status and customerId filters', async () => {
      prisma.order.findMany.mockResolvedValue([]);
      prisma.order.count.mockResolvedValue(0);

      await service.findAll({ status: 'pending', customerId: CUSTOMER_ID }, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: {
            organizationId: ORG_ID,
            status: 'pending',
            customerId: CUSTOMER_ID,
          },
        }),
      );
    });

    it('clamps take to valid range (1-100, default 20)', async () => {
      prisma.order.findMany.mockResolvedValue([]);
      prisma.order.count.mockResolvedValue(0);

      await service.findAll({ take: 500 }, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({ take: 100 }),
      );
    });

    it('throws BadRequestException with message for empty orgId', async () => {
      const error = await service.findAll({}, '').catch((e) => e);
      expect(error).toBeInstanceOf(BadRequestException);
      expect(error.message).toBe('organizationId is required');
    });

    it('falls back to DB on malformed cache data', async () => {
      redis.get.mockResolvedValueOnce('0'); // version
      redis.get.mockResolvedValueOnce('not-valid-json{{{'); // malformed
      prisma.order.findMany.mockResolvedValue([MOCK_ORDER]);
      prisma.order.count.mockResolvedValue(1);

      const result = await service.findAll({}, ORG_ID);

      expect(result.items).toEqual([MOCK_ORDER]);
    });

    it('queries DB when cache version changes (version mismatch)', async () => {
      // First call — cache version 0, set cache
      redis.get.mockResolvedValueOnce('0'); // version for first call
      redis.get.mockResolvedValueOnce(null); // no cached data at v0
      prisma.order.findMany.mockResolvedValue([MOCK_ORDER]);
      prisma.order.count.mockResolvedValue(1);

      await service.findAll({}, ORG_ID);
      expect(prisma.order.findMany).toHaveBeenCalledTimes(1);

      jest.clearAllMocks();

      // Second call — cache version now 1 (after mutation), old v0 key won't match
      redis.get.mockResolvedValueOnce('1'); // new version
      redis.get.mockResolvedValueOnce(null); // no cache at v1 key
      prisma.order.findMany.mockResolvedValue([MOCK_ORDER]);
      prisma.order.count.mockResolvedValue(1);

      await service.findAll({}, ORG_ID);
      expect(prisma.order.findMany).toHaveBeenCalledTimes(1);
    });
  });

  // === findById ===

  describe('findById', () => {
    it('returns order with relations on cache miss', async () => {
      prisma.order.findFirst.mockResolvedValue(MOCK_ORDER_WITH_RELATIONS);

      const result = await service.findById(ORDER_ID, ORG_ID);

      expect(result).toEqual(MOCK_ORDER_WITH_RELATIONS);
      expect(prisma.order.findFirst).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: ORDER_ID, organizationId: ORG_ID },
        }),
      );
    });

    it('throws NotFoundException with specific message when order not found', async () => {
      prisma.order.findFirst.mockResolvedValue(null);

      const error = await service.findById(ORDER_ID, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(NotFoundException);
      expect(error.message).toBe(`Order ${ORDER_ID} not found in organization ${ORG_ID}`);
    });

    it('uses cache key containing both ORDER_ID and ORG_ID', async () => {
      const orderData = { ...MOCK_ORDER_WITH_RELATIONS };
      redis.get.mockResolvedValueOnce('0'); // version
      redis.get.mockResolvedValueOnce(JSON.stringify(orderData)); // cached

      await service.findById(ORDER_ID, ORG_ID);

      // Verify cache key includes both identifiers
      const cacheGetCalls = redis.get.mock.calls;
      const dataKey = cacheGetCalls[1][0];
      expect(dataKey).toContain(ORDER_ID);
      expect(dataKey).toContain(ORG_ID);
    });
  });

  // === create ===

  describe('create', () => {
    const VALID_DTO = {
      customerId: CUSTOMER_ID,
      lineItems: MOCK_LINE_ITEMS,
      currency: CURRENCY_USD,
    };

    it('creates order with line items in a transaction', async () => {
      prisma._tx.order.create.mockResolvedValue(MOCK_ORDER);
      prisma._tx.auditLog.create.mockResolvedValue({});

      const result = await service.create(VALID_DTO, ORG_ID);

      expect(result).toEqual(MOCK_ORDER);
      expect(prisma._tx.order.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            customerId: CUSTOMER_ID,
            organizationId: ORG_ID,
            status: 'pending',
            currency: CURRENCY_USD,
            totalAmount: 100.0,
          }),
        }),
      );
      expect(prisma._tx.auditLog.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({ action: 'ORDER_CREATED' }),
        }),
      );
    });

    it('invalidates cache via Redis INCR after creation', async () => {
      prisma._tx.order.create.mockResolvedValue(MOCK_ORDER);
      prisma._tx.auditLog.create.mockResolvedValue({});

      await service.create(VALID_DTO, ORG_ID);

      expect(redis.incr).toHaveBeenCalledWith(expect.stringContaining(ORG_ID));
    });

    it('throws BadRequestException for empty customerId', async () => {
      const error = await service.create({ ...VALID_DTO, customerId: '' }, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(BadRequestException);
      expect(error.message).toBe('customerId is required');
    });

    it('throws BadRequestException for empty lineItems', async () => {
      const error = await service.create({ ...VALID_DTO, lineItems: [] }, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(BadRequestException);
      expect(error.message).toBe('At least one line item is required');
    });

    it('throws BadRequestException for non-positive quantity', async () => {
      const dto = {
        ...VALID_DTO,
        lineItems: [{ productId: PRODUCT_ID_A, quantity: 0, unitPrice: 10 }],
      };
      const error = await service.create(dto, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(BadRequestException);
      expect(error.message).toContain('positive finite integer');
    });

    it('throws BadRequestException for NaN quantity', async () => {
      const dto = {
        ...VALID_DTO,
        lineItems: [{ productId: PRODUCT_ID_A, quantity: NaN, unitPrice: 10 }],
      };
      const error = await service.create(dto, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(BadRequestException);
    });

    it('throws BadRequestException for negative unitPrice', async () => {
      const dto = {
        ...VALID_DTO,
        lineItems: [{ productId: PRODUCT_ID_A, quantity: 1, unitPrice: -5 }],
      };
      const error = await service.create(dto, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(BadRequestException);
      expect(error.message).toContain('non-negative finite number');
    });

    it('throws BadRequestException for invalid currency length', async () => {
      const error = await service.create({ ...VALID_DTO, currency: 'US' }, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(BadRequestException);
      expect(error.message).toContain('3-letter code');
    });

    it('throws BadRequestException for Infinity unitPrice', async () => {
      const dto = {
        ...VALID_DTO,
        lineItems: [{ productId: PRODUCT_ID_A, quantity: 1, unitPrice: Infinity }],
      };
      const error = await service.create(dto, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(BadRequestException);
    });
  });

  // === deleteOrder ===

  describe('deleteOrder', () => {
    it('deletes order and line items atomically in a transaction', async () => {
      prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'pending' });
      prisma._tx.lineItem.deleteMany.mockResolvedValue({ count: 2 });
      prisma._tx.order.delete.mockResolvedValue(MOCK_ORDER);
      prisma._tx.auditLog.create.mockResolvedValue({});

      await service.deleteOrder(ORDER_ID, ORG_ID);

      expect(prisma._tx.lineItem.deleteMany).toHaveBeenCalledWith({
        where: { orderId: ORDER_ID },
      });
      expect(prisma._tx.order.delete).toHaveBeenCalledWith({
        where: { id: ORDER_ID },
      });
      expect(prisma._tx.auditLog.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({ action: 'ORDER_DELETED' }),
        }),
      );
      expect(redis.incr).toHaveBeenCalled();
    });

    it('throws NotFoundException with message when order not found', async () => {
      prisma._tx.order.findFirst.mockResolvedValue(null);

      const error = await service.deleteOrder(ORDER_ID, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(NotFoundException);
      expect(error.message).toContain(`Order ${ORDER_ID} not found`);
    });

    it('throws ConflictException when deleting shipped order', async () => {
      prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'shipped' });

      const error = await service.deleteOrder(ORDER_ID, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(ConflictException);
      expect(error.message).toBe("Cannot delete order in 'shipped' status");
    });

    it('throws ConflictException when deleting delivered order', async () => {
      prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'delivered' });

      const error = await service.deleteOrder(ORDER_ID, ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(ConflictException);
      expect(error.message).toBe("Cannot delete order in 'delivered' status");
    });

    it('allows deletion of pending, confirmed, processing, and cancelled orders', async () => {
      for (const status of ['pending', 'confirmed', 'processing', 'cancelled'] as const) {
        jest.clearAllMocks();

        prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status });
        prisma._tx.lineItem.deleteMany.mockResolvedValue({ count: 0 });
        prisma._tx.order.delete.mockResolvedValue({});
        prisma._tx.auditLog.create.mockResolvedValue({});

        await expect(service.deleteOrder(ORDER_ID, ORG_ID)).resolves.not.toThrow();
      }
    });
  });

  // === updateStatus ===

  describe('updateStatus', () => {
    it('transitions from pending to confirmed with TOCTOU protection', async () => {
      const pendingOrder = { ...MOCK_ORDER, status: 'pending' };
      const updatedOrder = { ...MOCK_ORDER_WITH_RELATIONS, status: 'confirmed' };

      prisma._tx.order.findFirst.mockResolvedValue(pendingOrder);
      prisma._tx.order.updateMany.mockResolvedValue({ count: 1 });
      prisma._tx.auditLog.create.mockResolvedValue({});
      prisma._tx.order.findFirstOrThrow.mockResolvedValue(updatedOrder);

      const result = await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(result.status).toBe('confirmed');
      expect(prisma._tx.order.updateMany).toHaveBeenCalledWith({
        where: { id: ORDER_ID, organizationId: ORG_ID, status: 'pending' },
        data: { status: 'confirmed' },
      });
    });

    it('re-fetches order within transaction to return fresh data with relations', async () => {
      prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'pending' });
      prisma._tx.order.updateMany.mockResolvedValue({ count: 1 });
      prisma._tx.auditLog.create.mockResolvedValue({});
      prisma._tx.order.findFirstOrThrow.mockResolvedValue(MOCK_ORDER_WITH_RELATIONS);

      const result = await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(prisma._tx.order.findFirstOrThrow).toHaveBeenCalledWith(
        expect.objectContaining({
          include: expect.objectContaining({
            lineItems: true,
            customer: true,
            payments: true,
          }),
        }),
      );
      expect(result.customer).toBeDefined();
    });

    it('throws ConflictException with message for invalid state transition', async () => {
      prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'pending' });

      const error = await service.updateStatus(ORDER_ID, 'delivered', ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(ConflictException);
      expect(error.message).toBe("Cannot transition order from 'pending' to 'delivered'");
    });

    it('throws ConflictException on concurrent status change (TOCTOU)', async () => {
      prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'pending' });
      prisma._tx.order.updateMany.mockResolvedValue({ count: 0 }); // concurrent change

      const error = await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(ConflictException);
      expect(error.message).toContain('status changed concurrently');
    });

    it('throws NotFoundException when order not found', async () => {
      prisma._tx.order.findFirst.mockResolvedValue(null);

      const error = await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(NotFoundException);
    });

    it('sends email notification on shipped status with correct arguments', async () => {
      const processingOrder = { ...MOCK_ORDER, status: 'processing' };
      const shippedOrder = { ...MOCK_ORDER_WITH_RELATIONS, status: 'shipped' };

      prisma._tx.order.findFirst.mockResolvedValue(processingOrder);
      prisma._tx.order.updateMany.mockResolvedValue({ count: 1 });
      prisma._tx.auditLog.create.mockResolvedValue({});
      prisma._tx.order.findFirstOrThrow.mockResolvedValue(shippedOrder);

      await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

      expect(email.sendShippingNotification).toHaveBeenCalledWith(
        CUSTOMER_ID,
        ORDER_ID,
      );
    });

    it('does not throw when email notification fails, returns order normally', async () => {
      const processingOrder = { ...MOCK_ORDER, status: 'processing' };
      const shippedOrder = { ...MOCK_ORDER_WITH_RELATIONS, status: 'shipped' };

      prisma._tx.order.findFirst.mockResolvedValue(processingOrder);
      prisma._tx.order.updateMany.mockResolvedValue({ count: 1 });
      prisma._tx.auditLog.create.mockResolvedValue({});
      prisma._tx.order.findFirstOrThrow.mockResolvedValue(shippedOrder);
      email.sendShippingNotification.mockRejectedValue(new Error('SMTP timeout'));

      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();
      const result = await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

      expect(result.status).toBe('shipped');
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining('Failed to send shipping email'),
        expect.objectContaining({ orderId: ORDER_ID }),
      );
      consoleSpy.mockRestore();
    });

    it('does not send email on non-shipped transitions', async () => {
      prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'pending' });
      prisma._tx.order.updateMany.mockResolvedValue({ count: 1 });
      prisma._tx.auditLog.create.mockResolvedValue({});
      prisma._tx.order.findFirstOrThrow.mockResolvedValue({
        ...MOCK_ORDER_WITH_RELATIONS,
        status: 'confirmed',
      });

      await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(email.sendShippingNotification).not.toHaveBeenCalled();
    });

    it('allows cancellation from any non-delivered state', async () => {
      for (const fromStatus of ['pending', 'confirmed', 'processing', 'shipped'] as const) {
        jest.clearAllMocks();

        prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: fromStatus });
        prisma._tx.order.updateMany.mockResolvedValue({ count: 1 });
        prisma._tx.auditLog.create.mockResolvedValue({});
        prisma._tx.order.findFirstOrThrow.mockResolvedValue({
          ...MOCK_ORDER_WITH_RELATIONS,
          status: 'cancelled',
        });

        const result = await service.updateStatus(ORDER_ID, 'cancelled', ORG_ID);
        expect(result.status).toBe('cancelled');
      }
    });

    it('prevents transition from delivered state', async () => {
      prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'delivered' });

      const error = await service.updateStatus(ORDER_ID, 'cancelled', ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(ConflictException);
    });

    it('writes audit log with from/to metadata', async () => {
      prisma._tx.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'pending' });
      prisma._tx.order.updateMany.mockResolvedValue({ count: 1 });
      prisma._tx.auditLog.create.mockResolvedValue({});
      prisma._tx.order.findFirstOrThrow.mockResolvedValue({
        ...MOCK_ORDER_WITH_RELATIONS,
        status: 'confirmed',
      });

      await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(prisma._tx.auditLog.create).toHaveBeenCalledWith({
        data: expect.objectContaining({
          action: 'ORDER_STATUS_CHANGED',
          metadata: { from: 'pending', to: 'confirmed' },
        }),
      });
    });
  });

  // === calculateMonthlyRevenue ===

  describe('calculateMonthlyRevenue', () => {
    it('aggregates revenue by currency using correct UTC boundaries', async () => {
      prisma.order.groupBy.mockResolvedValue([
        { currency: 'USD', _sum: { totalAmount: 5000 } },
        { currency: 'EUR', _sum: { totalAmount: 3000 } },
      ]);

      const month = new Date(Date.UTC(2026, 0, 15)); // January 2026
      const result = await service.calculateMonthlyRevenue(month, ORG_ID);

      expect(result).toEqual([
        { currency: 'USD', total: 5000 },
        { currency: 'EUR', total: 3000 },
      ]);

      // Assert exact UTC boundaries
      const expectedStart = new Date(Date.UTC(2026, 0, 1));
      const expectedEnd = new Date(Date.UTC(2026, 1, 0, 23, 59, 59, 999));

      expect(prisma.order.groupBy).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            organizationId: ORG_ID,
            status: { not: 'cancelled' },
            createdAt: { gte: expectedStart, lte: expectedEnd },
          }),
        }),
      );
    });

    it('returns empty array when no orders in month', async () => {
      prisma.order.groupBy.mockResolvedValue([]);

      const month = new Date(Date.UTC(2026, 5, 1));
      const result = await service.calculateMonthlyRevenue(month, ORG_ID);

      expect(result).toEqual([]);
    });

    it('handles null totalAmount sum as zero', async () => {
      prisma.order.groupBy.mockResolvedValue([
        { currency: 'USD', _sum: { totalAmount: null } },
      ]);

      const month = new Date(Date.UTC(2026, 0, 1));
      const result = await service.calculateMonthlyRevenue(month, ORG_ID);

      expect(result).toEqual([{ currency: 'USD', total: 0 }]);
    });
  });

  // === bulkUpdateStatus ===

  describe('bulkUpdateStatus', () => {
    it('updates multiple orders and returns count', async () => {
      const orderIds = ['order-1', 'order-2', 'order-3'];
      prisma._tx.order.findFirst
        .mockResolvedValueOnce({ id: 'order-1', status: 'pending', organizationId: ORG_ID })
        .mockResolvedValueOnce({ id: 'order-2', status: 'pending', organizationId: ORG_ID })
        .mockResolvedValueOnce({ id: 'order-3', status: 'confirmed', organizationId: ORG_ID });
      prisma._tx.order.updateMany.mockResolvedValue({ count: 1 });
      prisma._tx.auditLog.create.mockResolvedValue({});

      const result = await service.bulkUpdateStatus(orderIds, 'confirmed', ORG_ID);

      // order-1 and order-2 pending→confirmed (valid), order-3 confirmed→confirmed (invalid, skipped)
      expect(result.updatedCount).toBe(2);
      expect(prisma._tx.auditLog.create).toHaveBeenCalledTimes(2);
    });

    it('skips orders with invalid transitions silently', async () => {
      prisma._tx.order.findFirst.mockResolvedValue({
        id: ORDER_ID,
        status: 'delivered',
        organizationId: ORG_ID,
      });

      const result = await service.bulkUpdateStatus([ORDER_ID], 'cancelled', ORG_ID);

      expect(result.updatedCount).toBe(0);
      expect(prisma._tx.order.updateMany).not.toHaveBeenCalled();
    });

    it('returns zero count for empty ids array', async () => {
      const result = await service.bulkUpdateStatus([], 'confirmed', ORG_ID);
      expect(result.updatedCount).toBe(0);
    });

    it('throws BadRequestException when ids exceed MAX_BULK_IDS with count in message', async () => {
      const tooManyIds = Array.from({ length: 101 }, (_, i) => `order-${i}`);

      const error = await service.bulkUpdateStatus(tooManyIds, 'confirmed', ORG_ID).catch((e) => e);
      expect(error).toBeInstanceOf(BadRequestException);
      expect(error.message).toContain('Maximum 100 orders per bulk update');
      expect(error.message).toContain('101');
    });

    it('skips orders not found in org', async () => {
      prisma._tx.order.findFirst.mockResolvedValue(null);

      const result = await service.bulkUpdateStatus([ORDER_ID], 'confirmed', ORG_ID);

      expect(result.updatedCount).toBe(0);
    });

    it('handles mixed valid/invalid transitions returning partial count', async () => {
      prisma._tx.order.findFirst
        .mockResolvedValueOnce({ id: 'o1', status: 'pending', organizationId: ORG_ID })
        .mockResolvedValueOnce({ id: 'o2', status: 'delivered', organizationId: ORG_ID }) // can't transition
        .mockResolvedValueOnce(null); // not found

      prisma._tx.order.updateMany.mockResolvedValue({ count: 1 });
      prisma._tx.auditLog.create.mockResolvedValue({});

      const result = await service.bulkUpdateStatus(['o1', 'o2', 'o3'], 'confirmed', ORG_ID);

      expect(result.updatedCount).toBe(1);
      expect(prisma._tx.order.updateMany).toHaveBeenCalledTimes(1);
    });
  });

  // === getOrdersForExport ===

  describe('getOrdersForExport', () => {
    it('returns orders with truncated=false when under limit', async () => {
      prisma.order.findMany.mockResolvedValue([MOCK_ORDER]);
      prisma.order.count.mockResolvedValue(1);

      const result = await service.getOrdersForExport({}, ORG_ID);

      expect(result.items).toEqual([MOCK_ORDER]);
      expect(result.total).toBe(1);
      expect(result.truncated).toBe(false);
    });

    it('sets truncated=true when total exceeds MAX_EXPORT_ROWS', async () => {
      const totalAboveLimit = MAX_EXPORT_ROWS + 1;
      prisma.order.findMany.mockResolvedValue(Array(MAX_EXPORT_ROWS).fill(MOCK_ORDER));
      prisma.order.count.mockResolvedValue(totalAboveLimit);

      const result = await service.getOrdersForExport({}, ORG_ID);

      expect(result.truncated).toBe(true);
      expect(result.total).toBe(totalAboveLimit);
    });

    it('sets truncated=false at exact MAX_EXPORT_ROWS boundary', async () => {
      prisma.order.findMany.mockResolvedValue(Array(MAX_EXPORT_ROWS).fill(MOCK_ORDER));
      prisma.order.count.mockResolvedValue(MAX_EXPORT_ROWS);

      const result = await service.getOrdersForExport({}, ORG_ID);

      expect(result.truncated).toBe(false);
      expect(result.total).toBe(MAX_EXPORT_ROWS);
    });

    it('applies status and dateRange filters', async () => {
      prisma.order.findMany.mockResolvedValue([]);
      prisma.order.count.mockResolvedValue(0);
      const from = new Date('2026-01-01');
      const to = new Date('2026-01-31');

      await service.getOrdersForExport({ status: 'shipped', dateRange: { from, to } }, ORG_ID);

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({
            organizationId: ORG_ID,
            status: 'shipped',
            createdAt: { gte: from, lte: to },
          }),
        }),
      );
    });
  });

  // === Cache behavior ===

  describe('cache', () => {
    it('deserializes Date fields from cached JSON', async () => {
      const orderWithDate = { ...MOCK_ORDER, createdAt: '2026-01-15T10:00:00.000Z' };
      redis.get.mockResolvedValueOnce('0'); // version
      redis.get.mockResolvedValueOnce(JSON.stringify(orderWithDate));

      const result = await service.findById(ORDER_ID, ORG_ID);

      expect(result.createdAt).toBeInstanceOf(Date);
      expect((result.createdAt as Date).toISOString()).toBe('2026-01-15T10:00:00.000Z');
    });

    it('does not crash when Redis set fails', async () => {
      redis.set.mockRejectedValue(new Error('Redis connection refused'));
      prisma.order.findMany.mockResolvedValue([MOCK_ORDER]);
      prisma.order.count.mockResolvedValue(1);
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();

      const result = await service.findAll({}, ORG_ID);

      expect(result.items).toEqual([MOCK_ORDER]);
      expect(consoleSpy).toHaveBeenCalledWith(
        expect.stringContaining('Cache set failed'),
        expect.any(String),
      );
      consoleSpy.mockRestore();
    });

    it('increments Redis version on cache invalidation, keyed by orgId', async () => {
      prisma._tx.order.create.mockResolvedValue(MOCK_ORDER);
      prisma._tx.auditLog.create.mockResolvedValue({});

      await service.create(
        { customerId: CUSTOMER_ID, lineItems: MOCK_LINE_ITEMS, currency: CURRENCY_USD },
        ORG_ID,
      );

      expect(redis.incr).toHaveBeenCalledTimes(1);
      const incrKey = redis.incr.mock.calls[0][0];
      expect(incrKey).toContain(ORG_ID);
    });

    it('continues operation when Redis INCR fails on invalidation', async () => {
      redis.incr.mockRejectedValue(new Error('Redis connection lost'));
      prisma._tx.order.create.mockResolvedValue(MOCK_ORDER);
      prisma._tx.auditLog.create.mockResolvedValue({});
      const consoleSpy = jest.spyOn(console, 'error').mockImplementation();

      const result = await service.create(
        { customerId: CUSTOMER_ID, lineItems: MOCK_LINE_ITEMS, currency: CURRENCY_USD },
        ORG_ID,
      );

      expect(result).toEqual(MOCK_ORDER);
      consoleSpy.mockRestore();
    });
  });
});
