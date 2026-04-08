// FILE: OrderService.test.ts
import { NotFoundException } from '@nestjs/common';
import { OrderService } from './r2-OrderService';

// ── Test Data Constants ──
const ORG_ID = 'org-test-001';
const ORDER_ID = 'order-001';
const CUSTOMER_ID = 'cust-001';
const PRODUCT_ID_A = 'prod-a';
const PRODUCT_ID_B = 'prod-b';
const CURRENCY_USD = 'USD';
const CURRENCY_EUR = 'EUR';

const MOCK_LINE_ITEMS = [
  { productId: PRODUCT_ID_A, quantity: 2, unitPrice: 10.99 },
  { productId: PRODUCT_ID_B, quantity: 1, unitPrice: 25.50 },
];

const MOCK_ORDER = {
  id: ORDER_ID,
  organizationId: ORG_ID,
  customerId: CUSTOMER_ID,
  status: 'pending',
  currency: CURRENCY_USD,
  totalAmount: 47.48,
  lineItems: [
    { id: 'li-1', productId: PRODUCT_ID_A, quantity: 2, unitPrice: 10.99, total: 21.98 },
    { id: 'li-2', productId: PRODUCT_ID_B, quantity: 1, unitPrice: 25.50, total: 25.50 },
  ],
  customer: { id: CUSTOMER_ID, name: 'Test Customer' },
  payments: [],
  createdAt: new Date('2026-03-15T10:00:00Z'),
};

const VALID_CREATE_DTO = {
  customerId: CUSTOMER_ID,
  lineItems: MOCK_LINE_ITEMS,
  currency: CURRENCY_USD,
};

// ── Mock Services ──
const mockPrismaTransaction = jest.fn();
const mockPrisma = {
  order: {
    findMany: jest.fn(),
    findFirst: jest.fn(),
    create: jest.fn(),
    update: jest.fn(),
    updateMany: jest.fn(),
    delete: jest.fn(),
    groupBy: jest.fn(),
  },
  lineItem: {
    deleteMany: jest.fn(),
  },
  auditLog: {
    create: jest.fn(),
  },
  $transaction: mockPrismaTransaction,
};

const mockRedis = {
  get: jest.fn(),
  set: jest.fn(),
  keys: jest.fn(),
  del: jest.fn(),
  scan: jest.fn(),
};

const mockEmail = {
  sendOrderShippedNotification: jest.fn(),
};

const mockPaymentGateway = {};

describe('OrderService', () => {
  let service: OrderService;

  beforeEach(() => {
    jest.clearAllMocks();
    service = new OrderService(
      mockPrisma as any,
      mockRedis as any,
      mockEmail as any,
      mockPaymentGateway as any,
    );
    // Default: SCAN returns no keys to delete
    mockRedis.scan.mockResolvedValue(['0', []]);
  });

  // ── findAll ──
  describe('findAll', () => {
    it('returns orders from database when cache is empty', async () => {
      const expectedOrders = [MOCK_ORDER];
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findMany.mockResolvedValue(expectedOrders);
      mockRedis.set.mockResolvedValue('OK');

      const result = await service.findAll({}, ORG_ID);

      expect(result).toEqual(expectedOrders);
      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { organizationId: ORG_ID },
          take: 50,
          skip: 0,
        }),
      );
      expect(mockRedis.set).toHaveBeenCalledWith(
        expect.stringContaining(`orders:${ORG_ID}`),
        JSON.stringify(expectedOrders),
        300,
      );
    });

    it('returns orders from cache on cache hit', async () => {
      const cachedOrders = [{ ...MOCK_ORDER, createdAt: '2026-03-15T10:00:00.000Z' }];
      mockRedis.get.mockResolvedValue(JSON.stringify(cachedOrders));

      const result = await service.findAll({}, ORG_ID);

      expect(result).toHaveLength(1);
      // Verify dateReviver restores Date objects from cached strings
      expect(result[0].createdAt).toBeInstanceOf(Date);
      expect(mockPrisma.order.findMany).not.toHaveBeenCalled();
    });

    it('applies status, dateRange, and customerId filters', async () => {
      mockRedis.get.mockResolvedValue(null);
      mockPrisma.order.findMany.mockResolvedValue([]);
      mockRedis.set.mockResolvedValue('OK');

      const from = new Date('2026-01-01');
      const to = new Date('2026-03-31');

      await service.findAll(
        { status: 'shipped', dateRange: { from, to }, customerId: CUSTOMER_ID, take: 10, skip: 5 },
        ORG_ID,
      );

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: {
            organizationId: ORG_ID,
            status: 'shipped',
            createdAt: { gte: from, lte: to },
            customerId: CUSTOMER_ID,
          },
          take: 10,
          skip: 5,
        }),
      );
    });
  });

  // ── findById ──
  describe('findById', () => {
    it('returns order when found in org', async () => {
      mockPrisma.order.findFirst.mockResolvedValue(MOCK_ORDER);

      const result = await service.findById(ORDER_ID, ORG_ID);

      expect(result).toEqual(MOCK_ORDER);
      expect(mockPrisma.order.findFirst).toHaveBeenCalledWith({
        where: { id: ORDER_ID, organizationId: ORG_ID },
        include: { lineItems: true, customer: true, payments: true },
      });
    });

    it('throws NotFoundException when order not found in org', async () => {
      mockPrisma.order.findFirst.mockResolvedValue(null);

      await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(NotFoundException);
      await expect(service.findById(ORDER_ID, ORG_ID)).rejects.toThrow(`Order ${ORDER_ID} not found`);
    });
  });

  // ── create ──
  describe('create', () => {
    it('creates order with line items in a transaction', async () => {
      const createdOrder = { ...MOCK_ORDER, id: 'new-order-001' };
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.create.mockResolvedValue(createdOrder);
      mockPrisma.auditLog.create.mockResolvedValue({});

      const result = await service.create(VALID_CREATE_DTO, ORG_ID);

      expect(result).toEqual(createdOrder);
      expect(mockPrismaTransaction).toHaveBeenCalled();
      expect(mockPrisma.order.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            organizationId: ORG_ID,
            customerId: CUSTOMER_ID,
            currency: CURRENCY_USD,
            status: 'pending',
          }),
        }),
      );
      expect(mockPrisma.auditLog.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({ action: 'ORDER_CREATED' }),
        }),
      );
    });

    it('rounds monetary values to prevent floating point drift', async () => {
      const dtoWithPrecisionIssue = {
        customerId: CUSTOMER_ID,
        lineItems: [{ productId: PRODUCT_ID_A, quantity: 3, unitPrice: 0.1 }],
        currency: CURRENCY_USD,
      };

      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.create.mockResolvedValue(MOCK_ORDER);
      mockPrisma.auditLog.create.mockResolvedValue({});

      await service.create(dtoWithPrecisionIssue, ORG_ID);

      expect(mockPrisma.order.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            totalAmount: 0.3, // rounded, not 0.30000000000000004
          }),
        }),
      );
    });

    it('throws error when customerId is missing', async () => {
      const invalidDto = { ...VALID_CREATE_DTO, customerId: '' };
      await expect(service.create(invalidDto, ORG_ID)).rejects.toThrow('customerId is required');
    });

    it('throws error when lineItems is empty', async () => {
      const invalidDto = { ...VALID_CREATE_DTO, lineItems: [] };
      await expect(service.create(invalidDto, ORG_ID)).rejects.toThrow('At least one line item is required');
    });

    it('throws error when line item quantity is not positive', async () => {
      const invalidDto = {
        ...VALID_CREATE_DTO,
        lineItems: [{ productId: PRODUCT_ID_A, quantity: 0, unitPrice: 10 }],
      };
      await expect(service.create(invalidDto, ORG_ID)).rejects.toThrow('Line item quantity must be positive');
    });

    it('throws error when line item unitPrice is negative', async () => {
      const invalidDto = {
        ...VALID_CREATE_DTO,
        lineItems: [{ productId: PRODUCT_ID_A, quantity: 1, unitPrice: -5 }],
      };
      await expect(service.create(invalidDto, ORG_ID)).rejects.toThrow('Line item unitPrice must not be negative');
    });

    it('invalidates cache after creation', async () => {
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.create.mockResolvedValue(MOCK_ORDER);
      mockPrisma.auditLog.create.mockResolvedValue({});

      await service.create(VALID_CREATE_DTO, ORG_ID);

      expect(mockRedis.scan).toHaveBeenCalled();
    });
  });

  // ── deleteOrder ──
  describe('deleteOrder', () => {
    it('deletes order and line items atomically in transaction', async () => {
      mockPrisma.order.findFirst.mockResolvedValue(MOCK_ORDER);
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.lineItem.deleteMany.mockResolvedValue({ count: 2 });
      mockPrisma.order.delete.mockResolvedValue(MOCK_ORDER);
      mockPrisma.auditLog.create.mockResolvedValue({});

      await service.deleteOrder(ORDER_ID, ORG_ID);

      expect(mockPrismaTransaction).toHaveBeenCalled();
      expect(mockPrisma.lineItem.deleteMany).toHaveBeenCalledWith({ where: { orderId: ORDER_ID } });
      expect(mockPrisma.order.delete).toHaveBeenCalledWith({ where: { id: ORDER_ID } });
      expect(mockPrisma.auditLog.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({ action: 'ORDER_DELETED' }),
        }),
      );
    });

    it('throws NotFoundException when order does not exist', async () => {
      mockPrisma.order.findFirst.mockResolvedValue(null);
      await expect(service.deleteOrder(ORDER_ID, ORG_ID)).rejects.toThrow(NotFoundException);
    });
  });

  // ── updateStatus ──
  describe('updateStatus', () => {
    it('transitions pending to confirmed in a transaction with optimistic locking', async () => {
      const pendingOrder = { ...MOCK_ORDER, status: 'pending' };
      const confirmedOrder = { ...MOCK_ORDER, status: 'confirmed' };
      mockPrisma.order.findFirst
        .mockResolvedValueOnce(pendingOrder) // findById
        .mockResolvedValueOnce(confirmedOrder); // re-fetch in transaction
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.auditLog.create.mockResolvedValue({});

      const result = await service.updateStatus(ORDER_ID, 'confirmed', ORG_ID);

      expect(result).toEqual(confirmedOrder);
      expect(mockPrisma.order.updateMany).toHaveBeenCalledWith({
        where: { id: ORDER_ID, status: 'pending' },
        data: { status: 'confirmed' },
      });
    });

    it('throws error for invalid state transition (pending to shipped)', async () => {
      mockPrisma.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'pending' });

      await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).rejects.toThrow(
        "Invalid status transition from 'pending' to 'shipped'",
      );
    });

    it('throws error for invalid transition from delivered', async () => {
      mockPrisma.order.findFirst.mockResolvedValue({ ...MOCK_ORDER, status: 'delivered' });

      await expect(service.updateStatus(ORDER_ID, 'cancelled', ORG_ID)).rejects.toThrow(
        "Invalid status transition from 'delivered' to 'cancelled'",
      );
    });

    it('allows cancellation from any non-delivered state', async () => {
      for (const status of ['pending', 'confirmed', 'processing'] as const) {
        jest.clearAllMocks();
        const order = { ...MOCK_ORDER, status };
        mockPrisma.order.findFirst
          .mockResolvedValueOnce(order)
          .mockResolvedValueOnce({ ...order, status: 'cancelled' });
        mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
        mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
        mockPrisma.auditLog.create.mockResolvedValue({});
        mockRedis.scan.mockResolvedValue(['0', []]);

        await expect(service.updateStatus(ORDER_ID, 'cancelled', ORG_ID)).resolves.toBeDefined();
      }
    });

    it('sends email notification on shipped status with error handling', async () => {
      const processingOrder = { ...MOCK_ORDER, status: 'processing' };
      mockPrisma.order.findFirst
        .mockResolvedValueOnce(processingOrder)
        .mockResolvedValueOnce({ ...processingOrder, status: 'shipped' });
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.auditLog.create.mockResolvedValue({});
      mockEmail.sendOrderShippedNotification.mockResolvedValue(undefined);

      await service.updateStatus(ORDER_ID, 'shipped', ORG_ID);

      expect(mockEmail.sendOrderShippedNotification).toHaveBeenCalledWith(ORDER_ID, CUSTOMER_ID);
    });

    it('does not throw when email notification fails on shipped status', async () => {
      const processingOrder = { ...MOCK_ORDER, status: 'processing' };
      mockPrisma.order.findFirst
        .mockResolvedValueOnce(processingOrder)
        .mockResolvedValueOnce({ ...processingOrder, status: 'shipped' });
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.auditLog.create.mockResolvedValue({});
      mockEmail.sendOrderShippedNotification.mockRejectedValue(new Error('SMTP down'));

      // Should not throw despite email failure
      await expect(service.updateStatus(ORDER_ID, 'shipped', ORG_ID)).resolves.toBeDefined();
    });

    it('throws on concurrent modification (optimistic lock failure)', async () => {
      const pendingOrder = { ...MOCK_ORDER, status: 'pending' };
      mockPrisma.order.findFirst.mockResolvedValue(pendingOrder);
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.updateMany.mockResolvedValue({ count: 0 }); // another request changed status

      await expect(service.updateStatus(ORDER_ID, 'confirmed', ORG_ID)).rejects.toThrow(
        'Concurrent modification',
      );
    });
  });

  // ── calculateMonthlyRevenue ──
  describe('calculateMonthlyRevenue', () => {
    it('aggregates revenue by currency for the given month using UTC boundaries', async () => {
      const monthDate = new Date('2026-03-15T00:00:00Z');
      mockPrisma.order.groupBy.mockResolvedValue([
        { currency: CURRENCY_USD, _sum: { totalAmount: 1500.00 } },
        { currency: CURRENCY_EUR, _sum: { totalAmount: 800.50 } },
      ]);

      const result = await service.calculateMonthlyRevenue(monthDate, ORG_ID);

      expect(result).toEqual([
        { currency: CURRENCY_USD, total: 1500.00 },
        { currency: CURRENCY_EUR, total: 800.50 },
      ]);

      const callArgs = mockPrisma.order.groupBy.mock.calls[0][0];
      const startDate = callArgs.where.createdAt.gte;
      const endDate = callArgs.where.createdAt.lte;
      // Verify UTC boundaries
      expect(startDate.toISOString()).toBe('2026-03-01T00:00:00.000Z');
      expect(endDate.getUTCMonth()).toBe(2); // March
      expect(endDate.getUTCDate()).toBe(31);
    });

    it('returns zero total when no orders match', async () => {
      mockPrisma.order.groupBy.mockResolvedValue([
        { currency: CURRENCY_USD, _sum: { totalAmount: null } },
      ]);

      const result = await service.calculateMonthlyRevenue(new Date('2026-01-01'), ORG_ID);

      expect(result).toEqual([{ currency: CURRENCY_USD, total: 0 }]);
    });
  });

  // ── bulkUpdateStatus ──
  describe('bulkUpdateStatus', () => {
    it('updates valid orders and returns count', async () => {
      const orderIds = ['order-1', 'order-2', 'order-3'];
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.findFirst
        .mockResolvedValueOnce({ id: 'order-1', status: 'pending', organizationId: ORG_ID })
        .mockResolvedValueOnce({ id: 'order-2', status: 'pending', organizationId: ORG_ID })
        .mockResolvedValueOnce({ id: 'order-3', status: 'pending', organizationId: ORG_ID });
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.auditLog.create.mockResolvedValue({});

      const result = await service.bulkUpdateStatus(orderIds, 'confirmed', ORG_ID);

      expect(result).toBe(3);
    });

    it('skips orders with invalid transitions silently', async () => {
      const orderIds = ['order-valid', 'order-invalid'];
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.findFirst
        .mockResolvedValueOnce({ id: 'order-valid', status: 'pending', organizationId: ORG_ID })
        .mockResolvedValueOnce({ id: 'order-invalid', status: 'delivered', organizationId: ORG_ID }); // delivered → confirmed is invalid
      mockPrisma.order.updateMany.mockResolvedValue({ count: 1 });
      mockPrisma.auditLog.create.mockResolvedValue({});

      const result = await service.bulkUpdateStatus(orderIds, 'confirmed', ORG_ID);

      expect(result).toBe(1); // only the valid one
    });

    it('skips non-existent orders', async () => {
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.findFirst.mockResolvedValue(null);

      const result = await service.bulkUpdateStatus(['nonexistent'], 'confirmed', ORG_ID);

      expect(result).toBe(0);
    });

    it('does not invalidate cache when no updates occur', async () => {
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.order.findFirst.mockResolvedValue(null);

      await service.bulkUpdateStatus(['nonexistent'], 'confirmed', ORG_ID);

      expect(mockRedis.scan).not.toHaveBeenCalled();
    });
  });

  // ── getOrdersForExport ──
  describe('getOrdersForExport', () => {
    it('returns full order data with related entities', async () => {
      mockPrisma.order.findMany.mockResolvedValue([MOCK_ORDER]);

      const result = await service.getOrdersForExport({}, ORG_ID);

      expect(result).toEqual([MOCK_ORDER]);
      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { organizationId: ORG_ID },
          take: 10000,
          include: { lineItems: true, customer: true, payments: true },
        }),
      );
    });

    it('applies export filters for status and date range', async () => {
      const from = new Date('2026-01-01');
      const to = new Date('2026-03-31');
      mockPrisma.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({ status: 'delivered', dateRange: { from, to } }, ORG_ID);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: {
            organizationId: ORG_ID,
            status: 'delivered',
            createdAt: { gte: from, lte: to },
          },
        }),
      );
    });

    it('enforces maxRows boundary of 10000', async () => {
      mockPrisma.order.findMany.mockResolvedValue([]);

      await service.getOrdersForExport({}, ORG_ID);

      expect(mockPrisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({ take: 10000 }),
      );
    });
  });

  // ── invalidateCache (via mutations) ──
  describe('cache invalidation', () => {
    it('uses SCAN instead of KEYS to find and delete cache entries', async () => {
      const cacheKeys = [`orders:${ORG_ID}:{}`, `orders:${ORG_ID}:{"status":"pending"}`];
      mockRedis.scan
        .mockResolvedValueOnce(['42', [cacheKeys[0]]])
        .mockResolvedValueOnce(['0', [cacheKeys[1]]]);
      mockRedis.del.mockResolvedValue(2);

      mockPrisma.order.findFirst.mockResolvedValue(MOCK_ORDER);
      mockPrismaTransaction.mockImplementation(async (cb: Function) => cb(mockPrisma));
      mockPrisma.lineItem.deleteMany.mockResolvedValue({ count: 0 });
      mockPrisma.order.delete.mockResolvedValue(MOCK_ORDER);
      mockPrisma.auditLog.create.mockResolvedValue({});

      await service.deleteOrder(ORDER_ID, ORG_ID);

      expect(mockRedis.scan).toHaveBeenCalledWith('0', 'MATCH', `orders:${ORG_ID}:*`, 'COUNT', 100);
      expect(mockRedis.del).toHaveBeenCalledWith(...cacheKeys);
    });
  });
});
